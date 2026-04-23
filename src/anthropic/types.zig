const std = @import("std");

pub const default_anthropic_version = "2023-06-01";

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const MessagesRequest = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const Message,
    system: ?[]const u8 = null,
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
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

// ───────── tests ─────────

const testing = std.testing;

test "MessagesRequest: minimal serialization" {
    const req: MessagesRequest = .{
        .model = "claude-opus-4-7",
        .max_tokens = 1024,
        .messages = &.{.{ .role = "user", .content = "hello" }},
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"model":"claude-opus-4-7","max_tokens":1024,"messages":[{"role":"user","content":"hello"}]}
    , json);
}

test "MessagesRequest: includes system when present" {
    const req: MessagesRequest = .{
        .model = "x",
        .max_tokens = 10,
        .messages = &.{.{ .role = "user", .content = "hi" }},
        .system = "be terse",
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"model":"x","max_tokens":10,"messages":[{"role":"user","content":"hi"}],"system":"be terse"}
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
