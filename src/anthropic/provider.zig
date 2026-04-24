//! Adapts the existing Anthropic Messages client to the
//! provider-agnostic Provider interface. Translates normalized
//! Request/Message shapes to Anthropic's tagged-block JSON, and
//! reverses the SSE event stream into provider_mod.Stream callbacks
//! (assembling text deltas live and emitting complete tool_use blocks
//! once each content_block_stop arrives).

const std = @import("std");
const provider_mod = @import("../provider.zig");
const types = @import("types.zig");
const sse = @import("sse.zig");
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
        const anth_req = try toAnthropic(self.arena, req);

        var state: StreamState = .{ .arena = self.arena, .sink = sink };
        try self.client.streamMessage(anth_req, &state, StreamState.onEvent);

        if (state.err) |e| return e;
        const reason = state.stop_reason orelse "end_turn";
        try sink.onStop(sink.ctx, reason);
    }
};

fn toAnthropic(arena: std.mem.Allocator, req: provider_mod.Request) !types.MessagesRequest {
    const messages = try arena.alloc(types.Message, req.messages.len);
    for (req.messages, 0..) |m, i| messages[i] = try translateMessage(arena, m);

    const tool_defs: ?[]const types.ToolDef = if (req.tools.len == 0) null else blk: {
        const defs = try arena.alloc(types.ToolDef, req.tools.len);
        for (req.tools, 0..) |t, j| defs[j] = .{
            .name = t.name,
            .description = t.description,
            .input_schema = t.input_schema,
        };
        break :blk defs;
    };

    return .{
        .model = req.model,
        .max_tokens = req.max_tokens,
        .system = req.system,
        .messages = messages,
        .tools = tool_defs,
    };
}

fn translateMessage(arena: std.mem.Allocator, m: provider_mod.Message) !types.Message {
    const blocks = try arena.alloc(types.ContentBlock, m.content.len);
    for (m.content, 0..) |b, i| {
        blocks[i] = switch (b) {
            .text => |t| .{ .type = "text", .text = t },
            .tool_use => |u| .{
                .type = "tool_use",
                .id = u.id,
                .name = u.name,
                .input = u.input,
            },
            .tool_result => |r| .{
                .type = "tool_result",
                .tool_use_id = r.tool_use_id,
                .content = r.content,
                .is_error = if (r.is_error) true else null,
            },
        };
    }
    return .{ .role = roleStr(m.role), .content = blocks };
}

fn roleStr(role: provider_mod.Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .system => "system",
    };
}

/// Per-stream state. We mirror the assistant's content blocks live so
/// we can emit complete `tool_use` events when each content_block_stop
/// arrives.
const InProgressBlock = struct {
    type: []const u8 = "",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input_json: std.ArrayList(u8) = .empty,
    /// Set true once we've forwarded a complete event for this block.
    emitted: bool = false,
};

const StreamState = struct {
    arena: std.mem.Allocator,
    sink: provider_mod.Stream,
    blocks: std.ArrayList(InProgressBlock) = .empty,
    stop_reason: ?[]const u8 = null,
    err: ?anyerror = null,

    fn ensureBlock(self: *StreamState, index: usize) !void {
        while (self.blocks.items.len <= index) {
            try self.blocks.append(self.arena, .{});
        }
    }

    fn emitBlockIfComplete(self: *StreamState, index: usize) !void {
        if (index >= self.blocks.items.len) return;
        var block = &self.blocks.items[index];
        if (block.emitted) return;
        if (!std.mem.eql(u8, block.type, "tool_use")) {
            block.emitted = true;
            return;
        }
        const id = block.id orelse return;
        const name = block.name orelse return;
        const input: std.json.Value = if (block.input_json.items.len == 0)
            .{ .object = .empty }
        else
            std.json.parseFromSliceLeaky(std.json.Value, self.arena, block.input_json.items, .{}) catch
                .{ .object = .empty };
        try self.sink.onToolUse(self.sink.ctx, .{ .id = id, .name = name, .input = input });
        block.emitted = true;
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
            if (parsed.delta.text) |t| try self.sink.onText(self.sink.ctx, t);
            if (parsed.delta.partial_json) |pj| try block.input_json.appendSlice(self.arena, pj);
        } else if (std.mem.eql(u8, ev.name, "content_block_stop")) {
            const parsed = std.json.parseFromSliceLeaky(
                types.ContentBlockStop,
                self.arena,
                ev.data,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch return;
            try self.emitBlockIfComplete(parsed.index);
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
                self.err = error.StreamingApiError;
                return;
            };
            std.debug.print("\nvelk: stream error ({s}): {s}\n", .{
                parsed.@"error".type,
                parsed.@"error".message,
            });
            self.err = error.StreamingApiError;
        }
    }
};
