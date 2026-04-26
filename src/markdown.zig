//! Inline markdown tokeniser. Converts a single line of text into a
//! sequence of styled `Span`s the TUI can hand to vaxis as cell
//! segments. Scope is deliberately limited:
//!
//!   **bold**       → bold
//!   *italic*       → italic (also `_italic_`)
//!   `code`         → code (rendered with a dim/contrast bg by the TUI)
//!   # / ## / ###   → header (whole line bold)
//!   - bullet       → leading `• ` substitution + same-line inline parse
//!
//! Per-line only — multi-line code fences (```...```) are NOT handled
//! so they render as literal backticks. That keeps the parser simple
//! and matches the wrap-then-render TUI pipeline.
//!
//! Unmatched markers (`**bold no close`) fall back to literal text so
//! we never lose characters.

const std = @import("std");

pub const Span = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
};

/// Produce a span list for `line`. Spans live in the supplied arena
/// (the `text` slices may be slices of `line` OR fresh arena
/// allocations when we need to substitute, e.g. bullets).
pub fn tokenize(arena: std.mem.Allocator, line: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;

    // Header: leading `#`, `##`, `###` followed by a space → whole line
    // bold. Strip the marker.
    var rest = line;
    var line_bold = false;
    if (rest.len >= 2 and rest[0] == '#') {
        var i: usize = 0;
        while (i < rest.len and i < 6 and rest[i] == '#') i += 1;
        if (i < rest.len and rest[i] == ' ') {
            line_bold = true;
            rest = rest[i + 1 ..];
        }
    }

    // Bullet: leading `- ` → render as "• " (note the U+2022). The
    // substitution span lives on its own; rest of the line parses as
    // normal inline.
    if (rest.len >= 2 and rest[0] == '-' and rest[1] == ' ') {
        try spans.append(arena, .{ .text = "• ", .bold = line_bold });
        rest = rest[2..];
    }

    try parseInline(arena, &spans, rest, line_bold);
    return spans.toOwnedSlice(arena);
}

/// Walk `text` left-to-right. Emit a plain span up to the next marker,
/// then the styled span, then continue. If a marker has no closer,
/// emit it literally.
fn parseInline(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Span),
    text: []const u8,
    line_bold: bool,
) !void {
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < text.len) {
        const c = text[i];

        // Code span: backtick-delimited. Highest precedence — contents
        // are NOT re-parsed.
        if (c == '`') {
            if (findClose(text, i + 1, "`")) |close_idx| {
                try flushPlain(arena, out, text[plain_start..i], line_bold);
                try out.append(arena, .{
                    .text = text[i + 1 .. close_idx],
                    .code = true,
                    .bold = line_bold,
                });
                i = close_idx + 1;
                plain_start = i;
                continue;
            }
        }

        // Bold: `**...**`
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (findClose(text, i + 2, "**")) |close_idx| {
                try flushPlain(arena, out, text[plain_start..i], line_bold);
                // Recurse to allow italic/code inside bold.
                try parseInline(arena, out, text[i + 2 .. close_idx], true);
                // Mark every span we just appended as bold (recursion
                // started with line_bold; inner already-bold remains
                // bold — we just need to ensure bold transfers across).
                // Implementation: parseInline received `line_bold=true`
                // so all child spans are already bold.
                i = close_idx + 2;
                plain_start = i;
                continue;
            }
        }

        // Italic: `*...*` (single asterisk) or `_..._`. We require the
        // marker NOT be touching whitespace internally so legit prose
        // like "5 * 4" doesn't trip — real markdown does this.
        if ((c == '*' or c == '_') and !(c == '*' and i + 1 < text.len and text[i + 1] == '*')) {
            const m = c;
            // Skip if this `_` is inside a word (e.g. snake_case).
            if (m == '_' and i > 0 and isWord(text[i - 1])) {
                i += 1;
                continue;
            }
            const close_marker = [_]u8{m};
            if (findCloseSingle(text, i + 1, m)) |close_idx| {
                // Reject empty `**` already handled above; also reject
                // open-marker followed by space (not real italic).
                if (text[i + 1] == ' ') {
                    i += 1;
                    continue;
                }
                _ = close_marker;
                try flushPlain(arena, out, text[plain_start..i], line_bold);
                try out.append(arena, .{
                    .text = text[i + 1 .. close_idx],
                    .italic = true,
                    .bold = line_bold,
                });
                i = close_idx + 1;
                plain_start = i;
                continue;
            }
        }

        i += 1;
    }

    if (plain_start < text.len) {
        try flushPlain(arena, out, text[plain_start..text.len], line_bold);
    }
}

fn flushPlain(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Span),
    text: []const u8,
    line_bold: bool,
) !void {
    if (text.len == 0) return;
    try out.append(arena, .{ .text = text, .bold = line_bold });
}

/// Find the next occurrence of `marker` (multi-byte) in `haystack`
/// starting at `from`. Returns absolute index of marker start, or null.
fn findClose(haystack: []const u8, from: usize, marker: []const u8) ?usize {
    if (from >= haystack.len) return null;
    return std.mem.indexOfPos(u8, haystack, from, marker);
}

/// Specialised single-char close-marker finder that rejects matches
/// where the closer is touching word characters from the wrong side
/// (mirroring how italic markers behave around words).
fn findCloseSingle(haystack: []const u8, from: usize, marker: u8) ?usize {
    var i: usize = from;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] != marker) continue;
        // Reject if preceded by whitespace (open and close swapped).
        if (i > 0 and haystack[i - 1] == ' ') continue;
        // For `_`, reject if followed by a word char (snake_case).
        if (marker == '_' and i + 1 < haystack.len and isWord(haystack[i + 1])) continue;
        return i;
    }
    return null;
}

fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ───────── tests ─────────

const testing = std.testing;

fn parseToList(arena: std.mem.Allocator, line: []const u8) ![]Span {
    return tokenize(arena, line);
}

test "tokenize: plain text → single plain span" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "hello world");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("hello world", spans[0].text);
    try testing.expect(!spans[0].bold);
}

test "tokenize: bold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "yo **emphasis** ok");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("yo ", spans[0].text);
    try testing.expectEqualStrings("emphasis", spans[1].text);
    try testing.expect(spans[1].bold);
    try testing.expectEqualStrings(" ok", spans[2].text);
}

test "tokenize: italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "yo *gentle* ok");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("gentle", spans[1].text);
    try testing.expect(spans[1].italic);
}

test "tokenize: code span" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "use `arena.dupe(u8, x)` to copy");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("arena.dupe(u8, x)", spans[1].text);
    try testing.expect(spans[1].code);
}

test "tokenize: header sets line_bold and strips prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "## Setup");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("Setup", spans[0].text);
    try testing.expect(spans[0].bold);
}

test "tokenize: bullet substitutes •" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "- first item");
    try testing.expectEqualStrings("• ", spans[0].text);
    try testing.expectEqualStrings("first item", spans[1].text);
}

test "tokenize: snake_case is not italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "set my_var to 1");
    // No italic span — single plain run.
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expect(!spans[0].italic);
}

test "tokenize: unmatched marker is literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "**not closed");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("**not closed", spans[0].text);
}

test "tokenize: code is opaque (no nested formatting)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "see `**not bold**` literally");
    try testing.expectEqualStrings("**not bold**", spans[1].text);
    try testing.expect(spans[1].code);
    try testing.expect(!spans[1].bold);
}

test "tokenize: bold can wrap italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "**bold *with italic* end**");
    var has_bold_italic = false;
    for (spans) |s| {
        if (s.bold and s.italic) has_bold_italic = true;
    }
    try testing.expect(has_bold_italic);
}

test "tokenize: header + bullet do not stack" {
    // `- ` after a header marker: header strip, then bullet detection.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try parseToList(arena.allocator(), "# - heading");
    try testing.expect(spans[0].bold);
    // The "- " inside a header is treated as a bullet substitution.
    try testing.expectEqualStrings("• ", spans[0].text);
}
