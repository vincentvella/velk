//! Provider-agnostic types and interface. Each provider impl
//! (Anthropic, OpenAI, OpenRouter, …) translates these to/from its
//! native API shape, so the agent loop never has to know which
//! backend it's talking to.

const std = @import("std");

pub const Role = enum { user, assistant, system };

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    /// Parsed JSON of the model's tool input.
    input: std.json.Value,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
    /// Optional image attachment. When non-null, the provider emits
    /// the tool_result as an array `[{text: content}, {image: …}]`
    /// so the model can see the image. The bytes are already
    /// base64-encoded by the tool that produced this result.
    image: ?ImageAttachment = null,
};

pub const ImageAttachment = struct {
    /// IANA media type, e.g. "image/png" / "image/jpeg" / "image/gif" /
    /// "image/webp". Both Anthropic and OpenAI accept these.
    media_type: []const u8,
    /// Base64-encoded image bytes. Caller is responsible for the
    /// encoding so we don't allocate twice.
    base64_data: []const u8,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,
};

pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema (object) describing the tool's input.
    input_schema: std.json.Value,
};

pub const Request = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    messages: []const Message,
    tools: []const ToolDef = &.{},
};

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    /// Tokens that hit a prompt cache (counted toward input). Anthropic
    /// reports this when ephemeral cache_control is in use; OpenAI
    /// surfaces it as `prompt_tokens_details.cached_tokens`.
    cache_read_tokens: u32 = 0,
    /// Tokens that wrote to a prompt cache (Anthropic-only today).
    cache_creation_tokens: u32 = 0,
};

/// Stream callbacks invoked by a provider as a turn unfolds. All slices
/// are valid only during the call — copy if you need to retain them.
pub const Stream = struct {
    ctx: ?*anyopaque,
    /// Incremental text delta from the assistant.
    onText: *const fn (?*anyopaque, text: []const u8) anyerror!void,
    /// A tool_use block has been fully assembled by the provider.
    onToolUse: *const fn (?*anyopaque, use: ToolUse) anyerror!void,
    /// Token usage for the request that just completed. May be called
    /// zero or one times per `stream` invocation depending on provider
    /// support; treat absence as "unknown, leave totals unchanged".
    onUsage: *const fn (?*anyopaque, usage: Usage) anyerror!void,
    /// End-of-turn signal with the provider-reported stop reason.
    /// Normalized values: "end_turn", "tool_use", "max_tokens",
    /// "stop_sequence". Unknown values pass through verbatim.
    onStop: *const fn (?*anyopaque, reason: []const u8) anyerror!void,
};

pub const Provider = struct {
    ctx: ?*anyopaque,
    streamFn: *const fn (?*anyopaque, Request, Stream) anyerror!void,
    /// Returns the raw response body that produced the most recent error
    /// (if the provider captured one), so the caller can format a useful
    /// message. May be null.
    lastErrorBodyFn: *const fn (?*anyopaque) ?[]const u8,

    pub fn stream(self: Provider, req: Request, s: Stream) !void {
        return self.streamFn(self.ctx, req, s);
    }

    pub fn lastErrorBody(self: Provider) ?[]const u8 {
        return self.lastErrorBodyFn(self.ctx);
    }
};

/// Convenience: build a Message containing a single text block.
/// Both the block array AND the text bytes are duped into `arena` so
/// the resulting Message is independent of any caller-owned buffer
/// (sessions outlive single turns and the caller's prompt may be
/// freed before the message is replayed on the next turn).
pub fn textMessage(arena: std.mem.Allocator, role: Role, text: []const u8) !Message {
    const blocks = try arena.alloc(ContentBlock, 1);
    blocks[0] = .{ .text = try arena.dupe(u8, text) };
    return .{ .role = role, .content = blocks };
}
