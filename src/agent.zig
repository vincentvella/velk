//! Tool-use loop. Sends a streaming Messages request, accumulates the
//! assistant's response (text + tool_use blocks) live, runs any tool_use
//! blocks the model emitted, appends the assistant message and a
//! tool_result user message, and repeats until `stop_reason` is `end_turn`
//! (or the iteration budget is exhausted).
//!
//! Output is delivered through a `Sink` rather than directly to a writer,
//! so the same loop drives both the plain CLI (sink writes to stdout/
//! stderr) and the TUI (sink updates scrollback state).

const std = @import("std");
const Io = std.Io;
const anthropic = @import("anthropic.zig");
const types = anthropic.types;
const sse = anthropic.sse;
const tool = @import("tool.zig");

/// Callbacks the agent fires as a turn unfolds. All slices passed in are
/// only valid for the duration of the call — copy if you need to retain.
pub const Sink = struct {
    ctx: ?*anyopaque,
    /// Streaming text delta from the assistant.
    onText: *const fn (?*anyopaque, []const u8) anyerror!void,
    /// A tool_use block has been fully assembled and is about to run.
    /// `input_json` is the model's input pretty-printed for display.
    onToolCall: *const fn (?*anyopaque, name: []const u8, input_json: []const u8) anyerror!void,
    /// The previous tool_use produced this result.
    onToolResult: *const fn (?*anyopaque, text: []const u8, is_error: bool) anyerror!void,
    /// Called once per turn after stop_reason has been observed (or when
    /// the loop is exiting due to error/budget). Lets the sink finalize
    /// (e.g. write a trailing newline to stdout).
    onTurnEnd: *const fn (?*anyopaque) anyerror!void,
};

pub const Config = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    /// Initial user prompt for the turn. The agent appends a user message
    /// containing this text and then drives the tool loop.
    prompt: []const u8,
    tools: []const tool.Tool = &.{},
    max_iterations: u32 = 10,
    /// Optional starting message history (e.g. earlier turns from a session).
    /// The agent will copy entries into its own list before appending.
    history: []const types.Message = &.{},
};

pub const Error = error{
    /// Hit `max_iterations` before the model emitted `end_turn`.
    IterationBudgetExceeded,
    /// Streaming `error` event from the API.
    StreamingApiError,
    /// Model emitted a tool_use block whose accumulated input was not
    /// valid JSON.
    InvalidToolInput,
} || std.mem.Allocator.Error;

/// Run one full turn (user prompt → assistant end_turn). Returns the
/// final message list so the caller can persist it as session history.
pub fn run(
    arena: std.mem.Allocator,
    client: *anthropic.Client,
    sink: Sink,
    config: Config,
) ![]const types.Message {
    var messages: std.ArrayList(types.Message) = .empty;
    for (config.history) |m| try messages.append(arena, m);
    try messages.append(arena, try types.textMessage(arena, "user", config.prompt));

    const tool_defs = try buildToolDefs(arena, config.tools);

    var iteration: u32 = 0;
    while (iteration < config.max_iterations) : (iteration += 1) {
        const req: types.MessagesRequest = .{
            .model = config.model,
            .max_tokens = config.max_tokens,
            .system = config.system,
            .messages = messages.items,
            .tools = if (tool_defs.len == 0) null else tool_defs,
        };

        var state: StreamState = .{
            .arena = arena,
            .sink = sink,
            .blocks = .empty,
        };

        client.streamMessage(req, &state, StreamState.onEvent) catch |err| {
            try sink.onTurnEnd(sink.ctx);
            return err;
        };

        if (state.err) |e| {
            try sink.onTurnEnd(sink.ctx);
            return e;
        }

        const stop_reason = state.stop_reason orelse "end_turn";
        if (!std.mem.eql(u8, stop_reason, "tool_use")) {
            try sink.onTurnEnd(sink.ctx);
            return messages.items;
        }

        // Assemble the assistant message from accumulated blocks and append it.
        const assistant_blocks = try assembleAssistantBlocks(arena, state.blocks.items);
        try messages.append(arena, .{ .role = "assistant", .content = assistant_blocks });

        // Run each tool_use block, gather tool_result blocks.
        var results: std.ArrayList(types.ContentBlock) = .empty;
        for (assistant_blocks) |block| {
            if (!std.mem.eql(u8, block.type, "tool_use")) continue;
            const result_block = try executeOne(arena, config.tools, block, sink);
            try results.append(arena, result_block);
        }

        try messages.append(arena, .{ .role = "user", .content = results.items });
    }

    try sink.onTurnEnd(sink.ctx);
    return Error.IterationBudgetExceeded;
}

fn buildToolDefs(arena: std.mem.Allocator, tools: []const tool.Tool) ![]const types.ToolDef {
    if (tools.len == 0) return &.{};
    const defs = try arena.alloc(types.ToolDef, tools.len);
    for (tools, 0..) |t, i| defs[i] = .{
        .name = t.name,
        .description = t.description,
        .input_schema = t.input_schema,
    };
    return defs;
}

fn assembleAssistantBlocks(arena: std.mem.Allocator, in_progress: []const InProgressBlock) ![]const types.ContentBlock {
    var out: std.ArrayList(types.ContentBlock) = .empty;
    for (in_progress) |b| {
        if (std.mem.eql(u8, b.type, "text")) {
            try out.append(arena, .{ .type = "text", .text = b.text.items });
        } else if (std.mem.eql(u8, b.type, "tool_use")) {
            const input: std.json.Value = if (b.input_json.items.len == 0)
                .{ .object = .empty }
            else
                std.json.parseFromSliceLeaky(std.json.Value, arena, b.input_json.items, .{}) catch
                    return Error.InvalidToolInput;
            try out.append(arena, .{
                .type = "tool_use",
                .id = b.id,
                .name = b.name,
                .input = input,
            });
        }
        // Unknown block types are dropped (e.g. thinking, server-only).
    }
    return out.items;
}

fn executeOne(
    arena: std.mem.Allocator,
    tools: []const tool.Tool,
    block: types.ContentBlock,
    sink: Sink,
) !types.ContentBlock {
    const id = block.id orelse return Error.InvalidToolInput;
    const name = block.name orelse return Error.InvalidToolInput;

    const input_str = if (block.input) |inp|
        try std.json.Stringify.valueAlloc(arena, inp, .{})
    else
        try arena.dupe(u8, "{}");
    try sink.onToolCall(sink.ctx, name, input_str);

    const reg: tool.Registry = .{ .tools = tools };
    const t = reg.find(name) orelse {
        const msg = try std.fmt.allocPrint(arena, "unknown tool: {s}", .{name});
        try sink.onToolResult(sink.ctx, msg, true);
        return .{
            .type = "tool_result",
            .tool_use_id = id,
            .content = msg,
            .is_error = true,
        };
    };

    const out = t.execute(t.context, arena, block.input orelse .{ .null = {} }) catch |e| {
        const msg = try std.fmt.allocPrint(arena, "tool errored: {s}", .{@errorName(e)});
        try sink.onToolResult(sink.ctx, msg, true);
        return .{
            .type = "tool_result",
            .tool_use_id = id,
            .content = msg,
            .is_error = true,
        };
    };

    try sink.onToolResult(sink.ctx, out.text, out.is_error);
    return .{
        .type = "tool_result",
        .tool_use_id = id,
        .content = out.text,
        .is_error = if (out.is_error) true else null,
    };
}

// ───────── streaming state ─────────

const InProgressBlock = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    text: std.ArrayList(u8) = .empty,
    input_json: std.ArrayList(u8) = .empty,
};

const StreamState = struct {
    arena: std.mem.Allocator,
    sink: Sink,
    blocks: std.ArrayList(InProgressBlock),
    stop_reason: ?[]const u8 = null,
    err: ?anyerror = null,

    fn ensureBlock(self: *StreamState, index: usize) !void {
        while (self.blocks.items.len <= index) {
            try self.blocks.append(self.arena, .{ .type = "" });
        }
    }

    fn onEvent(self: *StreamState, ev: sse.Event) anyerror!void {
        if (std.mem.eql(u8, ev.name, "content_block_start")) {
            const parsed = std.json.parseFromSliceLeaky(
                types.ContentBlockStart,
                self.arena,
                ev.data,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch |e| {
                if (self.err == null) self.err = e;
                return;
            };
            try self.ensureBlock(parsed.index);
            var block = &self.blocks.items[parsed.index];
            block.type = parsed.content_block.type;
            block.id = parsed.content_block.id;
            block.name = parsed.content_block.name;
        } else if (std.mem.eql(u8, ev.name, "content_block_delta")) {
            const parsed = std.json.parseFromSliceLeaky(
                types.ContentBlockDelta,
                self.arena,
                ev.data,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch |e| {
                if (self.err == null) self.err = e;
                return;
            };
            if (parsed.index >= self.blocks.items.len) return;
            var block = &self.blocks.items[parsed.index];
            if (parsed.delta.text) |t| {
                try block.text.appendSlice(self.arena, t);
                try self.sink.onText(self.sink.ctx, t);
            }
            if (parsed.delta.partial_json) |pj| {
                try block.input_json.appendSlice(self.arena, pj);
            }
        } else if (std.mem.eql(u8, ev.name, "message_delta")) {
            const parsed = std.json.parseFromSliceLeaky(
                types.MessageDelta,
                self.arena,
                ev.data,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch return;
            if (parsed.delta.stop_reason) |sr| self.stop_reason = sr;
        } else if (std.mem.eql(u8, ev.name, "error")) {
            const parsed = std.json.parseFromSliceLeaky(
                types.StreamError,
                self.arena,
                ev.data,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch {
                self.err = Error.StreamingApiError;
                return;
            };
            std.debug.print("\nvelk: stream error ({s}): {s}\n", .{
                parsed.@"error".type,
                parsed.@"error".message,
            });
            self.err = Error.StreamingApiError;
        }
        // Other events (message_start, message_stop, content_block_stop, ping)
        // require no action here.
    }
};
