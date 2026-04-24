//! OpenAI Chat Completions API request/response shapes. Used both for
//! the openai.com endpoint and OpenAI-compatible gateways (OpenRouter,
//! LiteLLM, Ollama, vLLM).

const std = @import("std");

pub const ToolCallFunction = struct {
    name: []const u8,
    /// Stringified JSON arguments.
    arguments: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: ToolCallFunction,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    name: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const ToolDef = struct {
    type: []const u8 = "function",
    function: ToolFunction,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    /// Renamed from `max_tokens` in newer OpenAI models (gpt-4o, gpt-5,
    /// o1/o3 reasoning series). The old name is rejected by reasoning
    /// models, while `max_completion_tokens` is accepted by everything
    /// post-2024-09, so we just use the new one universally.
    max_completion_tokens: ?u32 = null,
    tools: ?[]const ToolDef = null,
    stream: ?bool = null,
};

// ── Streaming chunk shapes ──

pub const FunctionDelta = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

pub const ToolCallDelta = struct {
    index: u32,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?FunctionDelta = null,
};

pub const Delta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallDelta = null,
};

pub const Choice = struct {
    index: u32 = 0,
    delta: Delta,
    finish_reason: ?[]const u8 = null,
};

pub const ChatChunk = struct {
    choices: []const Choice,
};

pub const ApiError = struct {
    @"error": Detail,

    pub const Detail = struct {
        message: []const u8,
        type: ?[]const u8 = null,
        code: ?[]const u8 = null,
    };
};

const testing = std.testing;

test "ChatRequest serializes minimal text turn" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req: ChatRequest = .{
        .model = "gpt-4o",
        .messages = &.{.{ .role = "user", .content = "hi" }},
        .max_completion_tokens = 100,
        .stream = true,
    };
    const json = try std.json.Stringify.valueAlloc(a, req, .{ .emit_null_optional_fields = false });
    try testing.expectEqualStrings(
        \\{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":100,"stream":true}
    , json);
}

test "ChatChunk parses content delta" {
    const body =
        \\{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}
    ;
    const parsed = try std.json.parseFromSlice(ChatChunk, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.choices.len);
    try testing.expectEqualStrings("Hi", parsed.value.choices[0].delta.content.?);
}

test "ChatChunk parses tool_call delta" {
    const body =
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"echo","arguments":"{\""}}]}}]}
    ;
    const parsed = try std.json.parseFromSlice(ChatChunk, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const tc = parsed.value.choices[0].delta.tool_calls.?[0];
    try testing.expectEqualStrings("call_1", tc.id.?);
    try testing.expectEqualStrings("echo", tc.function.?.name.?);
    try testing.expectEqualStrings("{\"", tc.function.?.arguments.?);
}
