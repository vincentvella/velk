//! Adapter that exposes an OpenAI-compatible chat endpoint behind the
//! provider-agnostic Provider interface.
//!
//! Translation notes vs Anthropic:
//! - System prompts move from a top-level field into a leading
//!   `{"role":"system"}` message.
//! - Assistant messages combine text + tool_calls into one object
//!   (text in `content`, calls in `tool_calls`); we flatten our
//!   normalized blocks accordingly.
//! - Tool results become separate `{"role":"tool", tool_call_id, content}`
//!   messages, so a single normalized user message containing N
//!   tool_result blocks expands into N OpenAI messages.
//! - Tool-call arguments stream as JSON-string fragments, addressed by
//!   integer index. We accumulate per-index and emit a complete
//!   ToolUse on `finish_reason: tool_calls`.

const std = @import("std");
const provider_mod = @import("../provider.zig");
const types = @import("types.zig");
const sse = @import("../anthropic/sse.zig");
const client_mod = @import("client.zig");

pub const Adapter = struct {
    arena: std.mem.Allocator,
    client: *client_mod.Client,

    pub fn init(arena: std.mem.Allocator, client: *client_mod.Client) Adapter {
        return .{ .arena = arena, .client = client };
    }

    pub fn provider(self: *Adapter) provider_mod.Provider {
        return .{
            .ctx = self,
            .streamFn = streamFn,
            .lastErrorBodyFn = lastErrorBodyFn,
        };
    }

    fn cast(ctx: ?*anyopaque) *Adapter {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn lastErrorBodyFn(ctx: ?*anyopaque) ?[]const u8 {
        const self = cast(ctx);
        return self.client.last_error_body;
    }

    fn streamFn(ctx: ?*anyopaque, req: provider_mod.Request, sink: provider_mod.Stream) anyerror!void {
        const self = cast(ctx);
        const oai_req = try toOpenAI(self.arena, req);

        var state: StreamState = .{ .arena = self.arena, .sink = sink };
        try self.client.streamChat(oai_req, &state, StreamState.onEvent);

        if (state.err) |e| return e;
        // Emit any tool_uses that finished accumulating but never got a
        // finish_reason event (rare, but defensive).
        try state.flushPendingToolCalls();
        const reason = state.stop_reason orelse "end_turn";
        try sink.onStop(sink.ctx, normalizeStopReason(reason));
    }
};

fn normalizeStopReason(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "stop")) return "end_turn";
    if (std.mem.eql(u8, s, "tool_calls")) return "tool_use";
    if (std.mem.eql(u8, s, "length")) return "max_tokens";
    return s;
}

fn toOpenAI(arena: std.mem.Allocator, req: provider_mod.Request) !types.ChatRequest {
    var messages: std.ArrayList(types.Message) = .empty;

    if (req.system) |sys| {
        try messages.append(arena, .{ .role = "system", .content = sys });
    }

    for (req.messages) |m| try translateMessage(arena, &messages, m);

    const tool_defs: ?[]const types.ToolDef = if (req.tools.len == 0) null else blk: {
        const defs = try arena.alloc(types.ToolDef, req.tools.len);
        for (req.tools, 0..) |t, i| defs[i] = .{
            .function = .{
                .name = t.name,
                .description = t.description,
                .parameters = t.input_schema,
            },
        };
        break :blk defs;
    };

    return .{
        .model = req.model,
        .max_completion_tokens = req.max_tokens,
        .messages = messages.items,
        .tools = tool_defs,
    };
}

/// Append OpenAI message(s) for one normalized message. Most cases
/// produce a single message; a user message containing tool_result
/// blocks produces one OpenAI tool-role message per result.
fn translateMessage(arena: std.mem.Allocator, out: *std.ArrayList(types.Message), m: provider_mod.Message) !void {
    switch (m.role) {
        .system => {
            const text = try concatText(arena, m.content);
            try out.append(arena, .{ .role = "system", .content = text });
        },
        .user => {
            // Split blocks: tool_results become their own tool-role
            // messages; everything else collapses into one user message.
            var pending_text: std.ArrayList(u8) = .empty;
            for (m.content) |b| switch (b) {
                .text => |t| try pending_text.appendSlice(arena, t),
                .tool_result => |r| {
                    if (pending_text.items.len > 0) {
                        try out.append(arena, .{ .role = "user", .content = pending_text.items });
                        pending_text = .empty;
                    }
                    try out.append(arena, .{
                        .role = "tool",
                        .tool_call_id = r.tool_use_id,
                        .content = r.content,
                    });
                },
                .tool_use => {
                    // tool_use shouldn't appear in a user message; ignore.
                },
            };
            if (pending_text.items.len > 0) {
                try out.append(arena, .{ .role = "user", .content = pending_text.items });
            }
        },
        .assistant => {
            // Concatenate text blocks, collect tool_uses into tool_calls.
            var text_buf: std.ArrayList(u8) = .empty;
            var tool_calls: std.ArrayList(types.ToolCall) = .empty;
            for (m.content) |b| switch (b) {
                .text => |t| try text_buf.appendSlice(arena, t),
                .tool_use => |u| {
                    const args = try std.json.Stringify.valueAlloc(arena, u.input, .{});
                    try tool_calls.append(arena, .{
                        .id = u.id,
                        .function = .{ .name = u.name, .arguments = args },
                    });
                },
                .tool_result => {
                    // not valid in assistant; ignore.
                },
            };
            const content_opt: ?[]const u8 = if (text_buf.items.len > 0) text_buf.items else null;
            const calls_opt: ?[]const types.ToolCall = if (tool_calls.items.len > 0) tool_calls.items else null;
            try out.append(arena, .{
                .role = "assistant",
                .content = content_opt,
                .tool_calls = calls_opt,
            });
        },
    }
}

fn concatText(arena: std.mem.Allocator, blocks: []const provider_mod.ContentBlock) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (blocks) |b| switch (b) {
        .text => |t| try buf.appendSlice(arena, t),
        else => {},
    };
    return buf.items;
}

// ── Streaming state ──

const PendingToolCall = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    emitted: bool = false,
};

const StreamState = struct {
    arena: std.mem.Allocator,
    sink: provider_mod.Stream,
    pending: std.ArrayList(PendingToolCall) = .empty,
    stop_reason: ?[]const u8 = null,
    err: ?anyerror = null,

    fn ensure(self: *StreamState, idx: usize) !void {
        while (self.pending.items.len <= idx) try self.pending.append(self.arena, .{});
    }

    fn flushPendingToolCalls(self: *StreamState) !void {
        for (self.pending.items) |*p| {
            if (p.emitted) continue;
            const id = p.id orelse continue;
            const name = p.name orelse continue;
            const input: std.json.Value = if (p.arguments.items.len == 0)
                .{ .object = .empty }
            else
                std.json.parseFromSliceLeaky(std.json.Value, self.arena, p.arguments.items, .{}) catch
                    .{ .object = .empty };
            try self.sink.onToolUse(self.sink.ctx, .{ .id = id, .name = name, .input = input });
            p.emitted = true;
        }
    }

    fn onEvent(self: *StreamState, ev: sse.Event) anyerror!void {
        // OpenAI uses unnamed events; the data field carries the JSON
        // chunk. Sentinel "[DONE]" marks end of stream.
        if (std.mem.eql(u8, ev.data, "[DONE]")) return;

        const parsed = std.json.parseFromSliceLeaky(
            types.ChatChunk,
            self.arena,
            ev.data,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |e| {
            if (self.err == null) self.err = e;
            return;
        };

        for (parsed.choices) |choice| {
            if (choice.delta.content) |c| {
                if (c.len > 0) try self.sink.onText(self.sink.ctx, c);
            }
            if (choice.delta.tool_calls) |tcs| {
                for (tcs) |tc| {
                    try self.ensure(tc.index);
                    var pending = &self.pending.items[tc.index];
                    if (tc.id) |id| pending.id = id;
                    if (tc.function) |f| {
                        if (f.name) |n| pending.name = n;
                        if (f.arguments) |args| try pending.arguments.appendSlice(self.arena, args);
                    }
                }
            }
            if (choice.finish_reason) |reason| {
                self.stop_reason = reason;
                if (std.mem.eql(u8, reason, "tool_calls")) try self.flushPendingToolCalls();
            }
        }
    }
};
