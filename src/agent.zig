//! Tool-use loop. Sends a streaming Messages request, accumulates the
//! assistant's response (text + tool_use blocks) live, runs any tool_use
//! blocks the model emitted, appends the assistant message and a
//! tool_result user message, and repeats until `stop_reason` is `end_turn`
//! (or the iteration budget is exhausted).
//!
//! Live text deltas are written to `text_out` as they arrive; tool calls
//! and their results are summarized to `progress_out` (stderr by default,
//! keeping stdout = assistant-text only for piping).

const std = @import("std");
const Io = std.Io;
const anthropic = @import("anthropic.zig");
const types = anthropic.types;
const sse = anthropic.sse;
const tool = @import("tool.zig");

pub const Config = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    prompt: []const u8,
    tools: []const tool.Tool = &.{},
    max_iterations: u32 = 10,
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

pub fn run(
    arena: std.mem.Allocator,
    client: *anthropic.Client,
    text_out: *Io.Writer,
    progress_out: *Io.Writer,
    config: Config,
) !void {
    var messages: std.ArrayList(types.Message) = .empty;
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
            .text_out = text_out,
            .blocks = .empty,
            .printed_text = false,
        };

        client.streamMessage(req, &state, StreamState.onEvent) catch |err| {
            if (state.printed_text) try text_out.writeAll("\n");
            try text_out.flush();
            return err;
        };

        if (state.err) |e| {
            if (state.printed_text) try text_out.writeAll("\n");
            try text_out.flush();
            return e;
        }
        if (state.printed_text) {
            try text_out.writeAll("\n");
            try text_out.flush();
        }

        const stop_reason = state.stop_reason orelse "end_turn";
        if (!std.mem.eql(u8, stop_reason, "tool_use")) return;

        // Assemble the assistant message from accumulated blocks and append it.
        const assistant_blocks = try assembleAssistantBlocks(arena, state.blocks.items);
        try messages.append(arena, .{ .role = "assistant", .content = assistant_blocks });

        // Run each tool_use block, gather tool_result blocks.
        var results: std.ArrayList(types.ContentBlock) = .empty;
        for (assistant_blocks) |block| {
            if (!std.mem.eql(u8, block.type, "tool_use")) continue;
            const result_block = try executeOne(arena, config.tools, block, progress_out);
            try results.append(arena, result_block);
        }

        try messages.append(arena, .{ .role = "user", .content = results.items });
    }

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
    progress_out: *Io.Writer,
) !types.ContentBlock {
    const id = block.id orelse return Error.InvalidToolInput;
    const name = block.name orelse return Error.InvalidToolInput;

    try progress_out.print("→ {s}", .{name});
    if (block.input) |inp| {
        var inp_str = try std.json.Stringify.valueAlloc(arena, inp, .{});
        if (inp_str.len > 200) inp_str = inp_str[0..200];
        try progress_out.print("({s})", .{inp_str});
    }
    try progress_out.writeAll("\n");
    try progress_out.flush();

    const reg: tool.Registry = .{ .tools = tools };
    const t = reg.find(name) orelse {
        const msg = try std.fmt.allocPrint(arena, "unknown tool: {s}", .{name});
        try progress_out.print("← (unknown tool)\n", .{});
        try progress_out.flush();
        return .{
            .type = "tool_result",
            .tool_use_id = id,
            .content = msg,
            .is_error = true,
        };
    };

    const out = t.execute(t.context, arena, block.input orelse .{ .null = {} }) catch |e| {
        const msg = try std.fmt.allocPrint(arena, "tool errored: {s}", .{@errorName(e)});
        try progress_out.print("← (error: {s})\n", .{@errorName(e)});
        try progress_out.flush();
        return .{
            .type = "tool_result",
            .tool_use_id = id,
            .content = msg,
            .is_error = true,
        };
    };

    var preview = out.text;
    if (preview.len > 200) preview = preview[0..200];
    try progress_out.print("← {s}{s}\n", .{ preview, if (out.text.len > 200) "…" else "" });
    try progress_out.flush();

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
    text_out: *Io.Writer,
    blocks: std.ArrayList(InProgressBlock),
    printed_text: bool,
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
                try self.text_out.writeAll(t);
                try self.text_out.flush();
                self.printed_text = true;
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
