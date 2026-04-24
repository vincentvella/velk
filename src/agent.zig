//! Tool-use loop, provider-agnostic. Calls `Provider.stream`, forwards
//! text deltas to the user-facing Sink, runs any tool_use blocks the
//! provider emits, builds the next request, and repeats until the
//! provider reports a non-tool stop reason.

const std = @import("std");
const Io = std.Io;
const provider_mod = @import("provider.zig");
const tool = @import("tool.zig");

/// Callbacks the agent fires as a turn unfolds. All slices passed in
/// are only valid for the duration of the call — copy if you need to
/// retain them.
pub const Sink = struct {
    ctx: ?*anyopaque,
    onText: *const fn (?*anyopaque, []const u8) anyerror!void,
    onToolCall: *const fn (?*anyopaque, name: []const u8, input_json: []const u8) anyerror!void,
    onToolResult: *const fn (?*anyopaque, text: []const u8, is_error: bool) anyerror!void,
    /// Called once at the very end of a turn, after the model emits a
    /// non-tool stop reason (or the loop bails). `usage` is the sum of
    /// all iterations within the turn.
    onTurnEnd: *const fn (?*anyopaque, usage: provider_mod.Usage) anyerror!void,
};

pub const Config = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    prompt: []const u8,
    tools: []const tool.Tool = &.{},
    max_iterations: u32 = 10,
    /// Optional starting message history.
    history: []const provider_mod.Message = &.{},
};

pub const Error = error{
    IterationBudgetExceeded,
    StreamingApiError,
    InvalidToolInput,
} || std.mem.Allocator.Error;

pub fn run(
    arena: std.mem.Allocator,
    provider: provider_mod.Provider,
    sink: Sink,
    config: Config,
) ![]const provider_mod.Message {
    var messages: std.ArrayList(provider_mod.Message) = .empty;
    for (config.history) |m| try messages.append(arena, m);
    try messages.append(arena, try provider_mod.textMessage(arena, .user, config.prompt));

    const tool_defs = try buildToolDefs(arena, config.tools);

    var cumulative: provider_mod.Usage = .{};

    var iteration: u32 = 0;
    while (iteration < config.max_iterations) : (iteration += 1) {
        const req: provider_mod.Request = .{
            .model = config.model,
            .max_tokens = config.max_tokens,
            .system = config.system,
            .messages = messages.items,
            .tools = tool_defs,
        };

        var state: TurnState = .{
            .arena = arena,
            .sink = sink,
        };

        provider.stream(req, .{
            .ctx = &state,
            .onText = TurnState.onText,
            .onToolUse = TurnState.onToolUse,
            .onUsage = TurnState.onUsage,
            .onStop = TurnState.onStop,
        }) catch |err| {
            try sink.onTurnEnd(sink.ctx, cumulative);
            return err;
        };

        cumulative.input_tokens +|= state.usage.input_tokens;
        cumulative.output_tokens +|= state.usage.output_tokens;
        cumulative.cache_read_tokens +|= state.usage.cache_read_tokens;
        cumulative.cache_creation_tokens +|= state.usage.cache_creation_tokens;

        const stop = state.stop_reason orelse "end_turn";
        if (!std.mem.eql(u8, stop, "tool_use")) {
            try sink.onTurnEnd(sink.ctx, cumulative);
            return messages.items;
        }

        // Build the assistant message that the model just produced
        // (text + tool_use blocks) and append it to history.
        const assistant_blocks = try buildAssistantBlocks(arena, &state);
        try messages.append(arena, .{ .role = .assistant, .content = assistant_blocks });

        // Run each tool_use, gather tool_results into one user message.
        var results: std.ArrayList(provider_mod.ContentBlock) = .empty;
        for (state.tool_uses.items) |use| {
            const result = try executeOne(arena, config.tools, use, sink);
            try results.append(arena, .{ .tool_result = result });
        }
        try messages.append(arena, .{ .role = .user, .content = results.items });
    }

    try sink.onTurnEnd(sink.ctx, cumulative);
    return Error.IterationBudgetExceeded;
}

fn buildToolDefs(arena: std.mem.Allocator, tools: []const tool.Tool) ![]const provider_mod.ToolDef {
    if (tools.len == 0) return &.{};
    const defs = try arena.alloc(provider_mod.ToolDef, tools.len);
    for (tools, 0..) |t, i| defs[i] = .{
        .name = t.name,
        .description = t.description,
        .input_schema = t.input_schema,
    };
    return defs;
}

fn buildAssistantBlocks(arena: std.mem.Allocator, state: *TurnState) ![]const provider_mod.ContentBlock {
    var out: std.ArrayList(provider_mod.ContentBlock) = .empty;
    if (state.text.items.len > 0) {
        try out.append(arena, .{ .text = try arena.dupe(u8, state.text.items) });
    }
    for (state.tool_uses.items) |use| try out.append(arena, .{ .tool_use = use });
    return out.items;
}

fn executeOne(
    arena: std.mem.Allocator,
    tools: []const tool.Tool,
    use: provider_mod.ToolUse,
    sink: Sink,
) !provider_mod.ToolResult {
    const input_str = try std.json.Stringify.valueAlloc(arena, use.input, .{});
    try sink.onToolCall(sink.ctx, use.name, input_str);

    const reg: tool.Registry = .{ .tools = tools };
    const t = reg.find(use.name) orelse {
        const msg = try std.fmt.allocPrint(arena, "unknown tool: {s}", .{use.name});
        try sink.onToolResult(sink.ctx, msg, true);
        return .{ .tool_use_id = use.id, .content = msg, .is_error = true };
    };

    const out = t.execute(t.context, arena, use.input) catch |e| {
        const msg = try std.fmt.allocPrint(arena, "tool errored: {s}", .{@errorName(e)});
        try sink.onToolResult(sink.ctx, msg, true);
        return .{ .tool_use_id = use.id, .content = msg, .is_error = true };
    };

    try sink.onToolResult(sink.ctx, out.text, out.is_error);
    return .{ .tool_use_id = use.id, .content = out.text, .is_error = out.is_error };
}

const TurnState = struct {
    arena: std.mem.Allocator,
    sink: Sink,
    text: std.ArrayList(u8) = .empty,
    tool_uses: std.ArrayList(provider_mod.ToolUse) = .empty,
    stop_reason: ?[]const u8 = null,
    usage: provider_mod.Usage = .{},

    fn cast(ctx: ?*anyopaque) *TurnState {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = cast(ctx);
        try self.text.appendSlice(self.arena, text);
        try self.sink.onText(self.sink.ctx, text);
    }

    fn onToolUse(ctx: ?*anyopaque, use: provider_mod.ToolUse) anyerror!void {
        const self = cast(ctx);
        // Copy the strings so they outlive the provider's per-event buffer.
        try self.tool_uses.append(self.arena, .{
            .id = try self.arena.dupe(u8, use.id),
            .name = try self.arena.dupe(u8, use.name),
            .input = use.input,
        });
    }

    fn onUsage(ctx: ?*anyopaque, usage: provider_mod.Usage) anyerror!void {
        const self = cast(ctx);
        self.usage = usage;
    }

    fn onStop(ctx: ?*anyopaque, reason: []const u8) anyerror!void {
        const self = cast(ctx);
        self.stop_reason = try self.arena.dupe(u8, reason);
    }
};
