//! Output styles — preset rendering modes that tack a system-prompt
//! suffix onto the user's base system prompt to nudge the model toward
//! a particular output shape (concise, verbose, JSON, etc.).
//!
//! v1 ships a hardcoded catalog. The active style is held on the TUI
//! and applied whenever the system prompt is rebuilt; toggling at
//! runtime via `/style <name>` mutates `session.config.system` to the
//! styled prompt without disturbing the user's recorded base prompt.

const std = @import("std");

pub const Style = struct {
    name: []const u8,
    description: []const u8,
    /// Suffix appended to the user's base system prompt. Empty for the
    /// "default" style — that's the no-op shape, kept in the catalog
    /// only so `/style default` resolves cleanly.
    suffix: []const u8,
};

pub const catalog = [_]Style{
    .{
        .name = "default",
        .description = "no extra constraints — the user's system prompt is used as-is",
        .suffix = "",
    },
    .{
        .name = "concise",
        .description = "short answers, no preamble, no closing summary",
        .suffix = "Output style: terse. Answer in the fewest words that work. " ++
            "Skip preambles, restated questions, and closing summaries. " ++
            "Use code over prose when possible.",
    },
    .{
        .name = "verbose",
        .description = "explain reasoning step by step, include caveats",
        .suffix = "Output style: verbose. Walk through the reasoning step by step. " ++
            "Surface assumptions, edge cases, and caveats. Include enough " ++
            "context that a reader unfamiliar with the codebase can follow.",
    },
    .{
        .name = "json",
        .description = "respond with a single JSON object — no surrounding prose",
        .suffix = "Output style: JSON. Respond with a single JSON object only. " ++
            "No prose, no Markdown fences. The structure is up to you, but " ++
            "every response must parse as valid JSON.",
    },
    .{
        .name = "explanatory",
        .description = "teach as you go — define jargon, link concepts",
        .suffix = "Output style: explanatory. Treat the user as a curious learner. " ++
            "Define jargon on first use, link related concepts, and prefer " ++
            "examples over abstract description.",
    },
};

/// Look up a style by exact name (case-sensitive). Returns null when
/// no match — callers should surface a list of valid names.
pub fn find(name: []const u8) ?Style {
    for (catalog) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Build the effective system prompt: `base + "\n\n" + suffix`. When
/// the suffix is empty (the `default` style or a no-suffix style) the
/// base is returned verbatim. When `base` is null, the suffix alone
/// becomes the new system prompt. Returns null when both inputs are
/// empty so the caller can clear `session.config.system`.
pub fn apply(arena: std.mem.Allocator, base: ?[]const u8, style: ?Style) !?[]const u8 {
    const suffix: []const u8 = if (style) |s| s.suffix else "";
    if (suffix.len == 0) return base;
    if (base == null or base.?.len == 0) return suffix;
    return try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base.?, suffix });
}

// ───────── tests ─────────

const testing = std.testing;

test "find: default resolves to a real entry with empty suffix" {
    const s = find("default").?;
    try testing.expectEqualStrings("default", s.name);
    try testing.expectEqual(@as(usize, 0), s.suffix.len);
}

test "find: concise has a non-empty suffix" {
    const s = find("concise").?;
    try testing.expect(s.suffix.len > 0);
}

test "find: returns null for unknown" {
    try testing.expect(find("typoed") == null);
}

test "apply: default style returns base unchanged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try apply(arena_state.allocator(), "be terse", find("default"));
    try testing.expectEqualStrings("be terse", out.?);
}

test "apply: concise appends suffix with separator" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try apply(arena_state.allocator(), "be terse", find("concise"));
    try testing.expect(std.mem.startsWith(u8, out.?, "be terse\n\n"));
    try testing.expect(std.mem.indexOf(u8, out.?, "Output style:") != null);
}

test "apply: null base + concise yields suffix alone" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try apply(arena_state.allocator(), null, find("concise"));
    try testing.expect(std.mem.startsWith(u8, out.?, "Output style:"));
}

test "apply: null base + null style yields null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try apply(arena_state.allocator(), null, null);
    try testing.expect(out == null);
}

test "apply: empty base + concise yields suffix alone" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try apply(arena_state.allocator(), "", find("concise"));
    try testing.expect(std.mem.startsWith(u8, out.?, "Output style:"));
}
