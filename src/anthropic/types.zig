const std = @import("std");

pub const default_anthropic_version = "2023-06-01";

/// Discriminated content block. Same shape used both for sending (in
/// Message.content) and receiving (in MessagesResponse.content). Fields
/// not relevant to a given `type` are left null and omitted from JSON
/// (we serialize with `emit_null_optional_fields = false`).
pub const ContentBlock = struct {
    type: []const u8,

    // type = "text"
    text: ?[]const u8 = null,

    // type = "tool_use"
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,

    // type = "tool_result"
    tool_use_id: ?[]const u8 = null,
    /// For tool_result: the textual output the tool produced.
    /// Anthropic also accepts an array of content blocks here, but a string
    /// covers every case we care about today.
    content: ?[]const u8 = null,
    is_error: ?bool = null,
};

pub const Message = struct {
    role: []const u8,
    content: []const ContentBlock,
};

/// Tool definition sent in MessagesRequest.tools. `input_schema` must be a
/// pre-built JSON object describing the tool's argument shape.
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
};

pub const MessagesRequest = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const Message,
    system: ?[]const u8 = null,
    tools: ?[]const ToolDef = null,
    /// Set to true for SSE streaming responses. Encoded only when non-null
    /// (request serialization uses `emit_null_optional_fields = false`).
    stream: ?bool = null,
};

/// Decoded `data:` payload of a `content_block_delta` SSE event.
pub const ContentBlockDelta = struct {
    type: []const u8,
    index: u32,
    delta: Delta,

    pub const Delta = struct {
        type: []const u8,
        /// Present for delta.type == "text_delta".
        text: ?[]const u8 = null,
        /// Present for delta.type == "input_json_delta" — partial JSON
        /// fragment for the corresponding tool_use block's `input`.
        partial_json: ?[]const u8 = null,
    };
};

/// Decoded `data:` payload of a `content_block_start` SSE event.
pub const ContentBlockStart = struct {
    type: []const u8,
    index: u32,
    content_block: ContentBlock,
};

/// Decoded `data:` payload of a `content_block_stop` SSE event.
pub const ContentBlockStop = struct {
    type: []const u8,
    index: u32,
};

/// Decoded `data:` payload of a `message_delta` SSE event (carries final
/// stop_reason and usage update).
pub const MessageDelta = struct {
    type: []const u8,
    delta: Delta,
    usage: ?DeltaUsage = null,

    pub const Delta = struct {
        stop_reason: ?[]const u8 = null,
        stop_sequence: ?[]const u8 = null,
    };

    /// `message_delta` events only update output_tokens (the final
    /// count); the other fields aren't sent again, so default them.
    pub const DeltaUsage = struct {
        output_tokens: u32 = 0,
    };
};

/// Decoded `data:` payload of a streaming `error` event.
pub const StreamError = struct {
    type: []const u8,
    @"error": ApiError.Detail,
};

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_creation_input_tokens: u32 = 0,
    cache_read_input_tokens: u32 = 0,
};

/// Decoded `data:` payload of a `message_start` SSE event. Carries the
/// full message envelope including the initial usage (input_tokens +
/// any cache hits).
pub const MessageStart = struct {
    type: []const u8,
    message: MessageEnvelope,

    pub const MessageEnvelope = struct {
        id: []const u8,
        type: []const u8,
        role: []const u8,
        model: []const u8,
        usage: Usage,
    };
};

pub const MessagesResponse = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8,
    model: []const u8,
    content: []const ContentBlock,
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
    usage: Usage,
};

pub const ApiError = struct {
    type: []const u8,
    @"error": Detail,

    pub const Detail = struct {
        type: []const u8,
        message: []const u8,
    };
};

/// Build a Message containing a single text block. Allocates the block
/// array in `arena` because returning `&.{...}` would point into the
/// caller's about-to-be-freed stack frame.
pub fn textMessage(arena: std.mem.Allocator, role: []const u8, text: []const u8) !Message {
    const blocks = try arena.alloc(ContentBlock, 1);
    blocks[0] = .{ .type = "text", .text = text };
    return .{ .role = role, .content = blocks };
}

// ───────── tests ─────────

const testing = std.testing;

test "MessagesRequest: minimal serialization (text content block)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: MessagesRequest = .{
        .model = "claude-opus-4-7",
        .max_tokens = 1024,
        .messages = &.{try textMessage(arena.allocator(), "user", "hello")},
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"model":"claude-opus-4-7","max_tokens":1024,"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}
    , json);
}

test "MessagesRequest: stream=true serializes the field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: MessagesRequest = .{
        .model = "x",
        .max_tokens = 10,
        .messages = &.{try textMessage(arena.allocator(), "user", "hi")},
        .stream = true,
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"model":"x","max_tokens":10,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"stream":true}
    , json);
}

test "MessagesRequest: serializes tool_use and tool_result content blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var input_obj: std.json.ObjectMap = .empty;
    try input_obj.put(a, "path", .{ .string = "README.md" });

    const messages = &[_]Message{
        try textMessage(a, "user", "read README"),
        .{
            .role = "assistant",
            .content = &.{.{
                .type = "tool_use",
                .id = "tu_1",
                .name = "read_file",
                .input = .{ .object = input_obj },
            }},
        },
        .{
            .role = "user",
            .content = &.{.{
                .type = "tool_result",
                .tool_use_id = "tu_1",
                .content = "hello\n",
            }},
        },
    };

    const req: MessagesRequest = .{ .model = "x", .max_tokens = 1, .messages = messages };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"tool_use\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"tu_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read_file\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"input\":{\"path\":\"README.md\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tool_use_id\":\"tu_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":\"hello\\n\"") != null);
}

test "MessagesRequest: includes system when present" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: MessagesRequest = .{
        .model = "x",
        .max_tokens = 10,
        .messages = &.{try textMessage(arena.allocator(), "user", "hi")},
        .system = "be terse",
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"model":"x","max_tokens":10,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"system":"be terse"}
    , json);
}

test "MessagesResponse: parses representative success body" {
    const body =
        \\{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-4-7",
        \\ "content":[{"type":"text","text":"hi"}],
        \\ "stop_reason":"end_turn","stop_sequence":null,
        \\ "usage":{"input_tokens":12,"output_tokens":3,"cache_creation_input_tokens":0}}
    ;
    const parsed = try std.json.parseFromSlice(MessagesResponse, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const r = parsed.value;
    try testing.expectEqualStrings("msg_01", r.id);
    try testing.expectEqualStrings("assistant", r.role);
    try testing.expectEqual(@as(usize, 1), r.content.len);
    try testing.expectEqualStrings("text", r.content[0].type);
    try testing.expectEqualStrings("hi", r.content[0].text.?);
    try testing.expectEqualStrings("end_turn", r.stop_reason.?);
    try testing.expectEqual(@as(u32, 12), r.usage.input_tokens);
    try testing.expectEqual(@as(u32, 3), r.usage.output_tokens);
}

test "ApiError: parses representative error body" {
    const body =
        \\{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens too small"}}
    ;
    const parsed = try std.json.parseFromSlice(ApiError, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("error", parsed.value.type);
    try testing.expectEqualStrings("invalid_request_error", parsed.value.@"error".type);
    try testing.expectEqualStrings("max_tokens too small", parsed.value.@"error".message);
}

test "ContentBlockStart: decodes a tool_use start event" {
    const body =
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"read_file","input":{}}}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlockStart, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.value.index);
    try testing.expectEqualStrings("tool_use", parsed.value.content_block.type);
    try testing.expectEqualStrings("tu_1", parsed.value.content_block.id.?);
    try testing.expectEqualStrings("read_file", parsed.value.content_block.name.?);
}

test "ContentBlockDelta: decodes input_json_delta" {
    const body =
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlockDelta, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("input_json_delta", parsed.value.delta.type);
    try testing.expectEqualStrings("{\"path\":", parsed.value.delta.partial_json.?);
}

test "MessageDelta: decodes stop_reason and usage update" {
    const body =
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}
    ;
    const parsed = try std.json.parseFromSlice(MessageDelta, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("tool_use", parsed.value.delta.stop_reason.?);
    try testing.expectEqual(@as(u32, 42), parsed.value.usage.?.output_tokens);
}
