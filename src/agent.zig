//! Tool-use loop, provider-agnostic. Calls `Provider.stream`, forwards
//! text deltas to the user-facing Sink, runs any tool_use blocks the
//! provider emits, builds the next request, and repeats until the
//! provider reports a non-tool stop reason.

const std = @import("std");
const Io = std.Io;
const provider_mod = @import("provider.zig");
const tool = @import("tool.zig");
const hooks = @import("hooks.zig");

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
    /// Optional hook engine. Fired around each tool execution.
    hook_engine: ?*const hooks.Engine = null,
    /// gpa for hook payload allocation. Required when `hook_engine`
    /// is non-null — the engine spawns child processes which need
    /// long-lived buffers separate from the per-turn arena.
    hook_gpa: ?std.mem.Allocator = null,
    /// Io for spawning hook commands. Required when `hook_engine`
    /// is non-null. Also used for the wall-clock budget check when
    /// `max_wall_ms` is set.
    hook_io: ?Io = null,
    /// Optional wall-clock cap (ms) for a single turn. Checked at
    /// the end of each iteration; on breach we abort with
    /// `Error.TurnBudgetExceeded` after `onTurnEnd` fires. 0 = unlimited.
    max_wall_ms: u64 = 0,
    /// Optional cumulative-token cap for a single turn (input +
    /// output across all iterations). Checked after each iteration's
    /// usage is collected. 0 = unlimited.
    max_total_tokens: u64 = 0,
};

pub const Error = error{
    IterationBudgetExceeded,
    /// `Config.max_wall_ms` or `max_total_tokens` was breached
    /// mid-turn. The accumulated history is committed; the turn
    /// returns this error to the caller.
    TurnBudgetExceeded,
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
    const turn_started_at: ?Io.Timestamp = if (config.max_wall_ms > 0 and config.hook_io != null)
        Io.Clock.now(.awake, config.hook_io.?)
    else
        null;

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

        // Budget checks fire AFTER the iteration's usage is folded
        // into `cumulative`. We only abort between iterations — a
        // tool use already in flight gets to finish.
        if (config.max_total_tokens > 0) {
            const total: u64 = @as(u64, cumulative.input_tokens) + @as(u64, cumulative.output_tokens);
            if (total > config.max_total_tokens) {
                try sink.onTurnEnd(sink.ctx, cumulative);
                return Error.TurnBudgetExceeded;
            }
        }
        if (turn_started_at) |t0| {
            const elapsed = t0.untilNow(config.hook_io.?, .awake);
            const elapsed_ms: u64 = @intCast(@max(@as(i96, 0), @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms)));
            if (elapsed_ms > config.max_wall_ms) {
                try sink.onTurnEnd(sink.ctx, cumulative);
                return Error.TurnBudgetExceeded;
            }
        }

        // Build the assistant message that the model just produced
        // (text + tool_use blocks) and append it to history.
        const assistant_blocks = try buildAssistantBlocks(arena, &state);
        try messages.append(arena, .{ .role = .assistant, .content = assistant_blocks });

        // Run each tool_use, gather tool_results into one user message.
        var results: std.ArrayList(provider_mod.ContentBlock) = .empty;
        for (state.tool_uses.items) |use| {
            const result = try executeOne(arena, config, use, sink);
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
    config: Config,
    use: provider_mod.ToolUse,
    sink: Sink,
) !provider_mod.ToolResult {
    const input_str = try std.json.Stringify.valueAlloc(arena, use.input, .{});
    try sink.onToolCall(sink.ctx, use.name, input_str);

    const reg: tool.Registry = .{ .tools = config.tools };
    const t = reg.find(use.name) orelse {
        const msg = try std.fmt.allocPrint(arena, "unknown tool: {s}", .{use.name});
        try sink.onToolResult(sink.ctx, msg, true);
        return .{ .tool_use_id = use.id, .content = msg, .is_error = true };
    };

    // PreToolUse: a hook returning exit-2 short-circuits execution.
    if (config.hook_engine) |engine| {
        if (engine.hooks.len > 0) {
            const gpa = config.hook_gpa orelse arena;
            const io = config.hook_io orelse return Error.InvalidToolInput;
            const outcome = engine.dispatch(gpa, io, .pre_tool_use, .{
                .tool_name = use.name,
                .tool_input = use.input,
            }) catch |e| blk: {
                std.log.warn("hook dispatch failed: {s}", .{@errorName(e)});
                break :blk hooks.Outcome{};
            };
            defer if (outcome.inject) |s| gpa.free(s);
            defer if (outcome.notice) |s| gpa.free(s);
            if (outcome.blocked) |reason| {
                defer gpa.free(reason);
                const msg = try std.fmt.allocPrint(arena, "blocked by PreToolUse hook: {s}", .{reason});
                try sink.onToolResult(sink.ctx, msg, true);
                return .{ .tool_use_id = use.id, .content = msg, .is_error = true };
            }
        }
    }

    const out = t.execute(t.context, arena, use.input) catch |e| {
        const msg = try std.fmt.allocPrint(arena, "tool errored: {s}", .{@errorName(e)});
        try sink.onToolResult(sink.ctx, msg, true);
        return .{ .tool_use_id = use.id, .content = msg, .is_error = true };
    };

    try sink.onToolResult(sink.ctx, out.text, out.is_error);

    // PostToolUse: notification only. Errors are swallowed.
    if (config.hook_engine) |engine| {
        if (engine.hooks.len > 0) {
            const gpa = config.hook_gpa orelse arena;
            if (config.hook_io) |io| {
                if (engine.dispatch(gpa, io, .post_tool_use, .{
                    .tool_name = use.name,
                    .tool_input = use.input,
                    .tool_output = out.text,
                    .tool_error = out.is_error,
                })) |outcome| {
                    if (outcome.inject) |s| gpa.free(s);
                    if (outcome.notice) |s| gpa.free(s);
                    if (outcome.blocked) |s| gpa.free(s);
                } else |e| {
                    std.log.warn("PostToolUse dispatch failed: {s}", .{@errorName(e)});
                }
            }
        }
    }

    // Sanitize: tool output may include non-UTF-8 bytes (e.g. `cat`
    // on a binary file). The Anthropic API requires content strings
    // be valid JSON, which in turn requires valid UTF-8. Invalid
    // sequences cause the server to reject the whole request with
    // an opaque "Input should be a valid dictionary" error. Replace
    // any invalid bytes with U+FFFD so the model sees something
    // representable.
    const safe = try sanitizeUtf8(arena, out.text);
    return .{ .tool_use_id = use.id, .content = safe, .is_error = out.is_error };
}

/// Returns `s` if it's already valid UTF-8, otherwise allocates a
/// copy with each invalid byte replaced by U+FFFD (the Unicode
/// replacement character). Truncates to `max_tool_output_bytes`
/// since model context windows aren't free.
const max_tool_output_bytes: usize = 64 * 1024;

fn sanitizeUtf8(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const truncated = if (s.len > max_tool_output_bytes) s[0..max_tool_output_bytes] else s;
    if (std.unicode.utf8ValidateSlice(truncated)) {
        if (truncated.len == s.len) return s;
        return try std.fmt.allocPrint(arena, "{s}\n…[truncated at {d} bytes]", .{ truncated, max_tool_output_bytes });
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < truncated.len) {
        const len = std.unicode.utf8ByteSequenceLength(truncated[i]) catch {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + len > truncated.len) {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        }
        if (!std.unicode.utf8ValidateSlice(truncated[i .. i + len])) {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        }
        try out.appendSlice(arena, truncated[i .. i + len]);
        i += len;
    }
    if (truncated.len < s.len) {
        try out.print(arena, "\n…[truncated at {d} bytes]", .{max_tool_output_bytes});
    }
    return out.items;
}

test "sanitizeUtf8: valid input returns same slice" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try sanitizeUtf8(a, "hello world");
    try std.testing.expectEqualStrings("hello world", out);
}

test "sanitizeUtf8: replaces invalid bytes with U+FFFD" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad: []const u8 = &.{ 'h', 'i', 0xFF, 0xFE, 0x80, 'x' };
    const out = try sanitizeUtf8(a, bad);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{FFFD}") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "hi"));
    try std.testing.expect(std.mem.endsWith(u8, out, "x"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "sanitizeUtf8: PDF header sanitizes cleanly" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // First few bytes of a typical PDF — has invalid-UTF-8 binary
    // payload after the header.
    const pdf: []const u8 = &.{ '%', 'P', 'D', 'F', '-', '1', '.', '3', '\n', '%', 0xC1, 0xC2, 0xC3, 0xC4, '\n' };
    const out = try sanitizeUtf8(a, pdf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.startsWith(u8, out, "%PDF-1.3"));
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
