//! Approximate token counter. We don't ship Anthropic's BPE tokenizer
//! (proprietary) or vendor tiktoken (multi-megabyte data file), so we
//! lean on a chars-per-token heuristic that's accurate enough to drive
//! "you're nearing the context window" warnings.
//!
//! The constants come from public benchmarking of Claude / GPT
//! tokenizers on mixed English + code corpora. They're conservative —
//! an estimate ~5-15% above the real count is fine because the user
//! gets a slightly earlier warning, not a missed one.
//!
//! Use `/tokens` from the TUI or `cost.cacheMinTokens` in /doctor
//! against this estimate to gauge cache eligibility.

const std = @import("std");
const provider = @import("provider.zig");

/// Average chars-per-token for English prose. Claude's BPE is roughly
/// 3.5-4.0 across the public corpus; we pick 3.5 so estimates skew
/// slightly high.
const chars_per_token_text: f64 = 3.5;

/// Code is denser (more punctuation, more short symbols) — ~2.5-3.0.
/// We use 3.0 as a middle ground for prose-with-code blocks since
/// the model sees both.
const chars_per_token_code: f64 = 3.0;

/// Estimate tokens for a free-form text blob (English or code-ish).
/// Returns rounded-up token count.
pub fn estimate(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const f: f64 = @floatFromInt(text.len);
    const t = @ceil(f / chars_per_token_text);
    return @intFromFloat(t);
}

/// Estimate tokens for a code-heavy blob. Use this when you know the
/// input is dominated by source code; otherwise `estimate` is fine.
pub fn estimateCode(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const f: f64 = @floatFromInt(text.len);
    const t = @ceil(f / chars_per_token_code);
    return @intFromFloat(t);
}

/// Sum across a whole request: system prompt + every content block in
/// every message. Tool input/output are included; tool_use IDs and
/// names are too short to matter at this granularity. Returns rounded-
/// up count, padded for tool/JSON overhead the model server adds for
/// schema attachment.
pub fn estimateRequest(req: provider.Request) u32 {
    var total: u32 = 0;
    if (req.system) |s| total += estimate(s);
    for (req.messages) |m| {
        for (m.content) |c| switch (c) {
            .text => |t| total += estimate(t),
            .tool_use => |u| {
                total += estimate(u.name);
                total += estimateJsonValue(u.input);
            },
            .tool_result => |r| {
                total += estimate(r.content);
                if (r.image) |_| {
                    // Anthropic charges roughly 1568 tokens per ~1MP
                    // image at the default `auto` detail level. The
                    // exact value depends on the image dimensions
                    // and the model's vision pipeline; this is a
                    // reasonable upper-bound default.
                    total += 1600;
                }
            },
        };
    }
    // Each tool definition contributes a JSON schema. Conservatively
    // count 100 tokens per registered tool — we don't have schemas
    // here in their serialized form, but that's a fair median.
    total += @intCast(req.tools.len * 100);
    return total;
}

fn estimateJsonValue(v: std.json.Value) u32 {
    return switch (v) {
        .null => 1,
        .bool => 1,
        .integer, .float, .number_string => 4,
        .string => |s| estimate(s),
        .array => |a| blk: {
            var sum: u32 = 0;
            for (a.items) |item| sum += estimateJsonValue(item);
            break :blk sum;
        },
        .object => |o| blk: {
            var sum: u32 = 0;
            var it = o.iterator();
            while (it.next()) |entry| {
                sum += estimate(entry.key_ptr.*);
                sum += estimateJsonValue(entry.value_ptr.*);
            }
            break :blk sum;
        },
    };
}

const testing = std.testing;

test "estimate: empty input is zero" {
    try testing.expectEqual(@as(u32, 0), estimate(""));
}

test "estimate: rounds up" {
    // 7 chars / 3.5 = 2 tokens exact
    try testing.expectEqual(@as(u32, 2), estimate("seven c"));
    // 8 chars / 3.5 = 2.28 → 3
    try testing.expectEqual(@as(u32, 3), estimate("eight ch"));
}

test "estimate: scales linearly with bytes" {
    const a = estimate("hello world");
    const b = estimate("hello world hello world");
    // Doubling bytes should ~double tokens (within rounding).
    try testing.expect(b >= a * 2 - 1 and b <= a * 2 + 1);
}

test "estimateCode: denser than text" {
    const code = "fn main() { return 0; }";
    try testing.expect(estimateCode(code) > estimate(code));
}

test "estimateRequest: sums across messages" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sys = "you are a tester. " ** 10; // 180 bytes ≈ 52 tokens
    var content = try a.alloc(provider.ContentBlock, 1);
    content[0] = .{ .text = "hi there friend!" }; // 16 bytes ≈ 5 tokens
    const messages = try a.alloc(provider.Message, 1);
    messages[0] = .{ .role = .user, .content = content };

    const req: provider.Request = .{
        .model = "claude-mock",
        .max_tokens = 100,
        .system = sys,
        .messages = messages,
    };
    const t = estimateRequest(req);
    // System ≈ 52 + content ≈ 5 = 57. Allow a small floor / ceiling.
    try testing.expect(t > 50 and t < 70);
}

test "estimateRequest: tool_result with image adds ≈1600 token charge" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const content_with_image = try a.alloc(provider.ContentBlock, 1);
    content_with_image[0] = .{ .tool_result = .{
        .tool_use_id = "tu_1",
        .content = "tiny",
        .image = .{ .media_type = "image/png", .base64_data = "AAAA" },
    } };
    const messages = try a.alloc(provider.Message, 1);
    messages[0] = .{ .role = .user, .content = content_with_image };

    const req: provider.Request = .{
        .model = "claude-mock",
        .max_tokens = 1,
        .messages = messages,
    };
    const t = estimateRequest(req);
    try testing.expect(t >= 1600 and t < 1700);
}

test "estimateRequest: tool definitions contribute ~100 tokens each" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const empty_msg_content = try a.alloc(provider.ContentBlock, 0);
    const messages = try a.alloc(provider.Message, 1);
    messages[0] = .{ .role = .user, .content = empty_msg_content };

    const tools = try a.alloc(provider.ToolDef, 5);
    for (tools, 0..) |*td, i| {
        _ = i;
        td.* = .{ .name = "x", .description = "x", .input_schema = .{ .null = {} } };
    }

    const req: provider.Request = .{
        .model = "claude-mock",
        .max_tokens = 1,
        .messages = messages,
        .tools = tools,
    };
    try testing.expectEqual(@as(u32, 500), estimateRequest(req));
}
