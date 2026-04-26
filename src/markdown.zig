//! Inline markdown tokeniser. Per-line input → sequence of styled
//! `Span`s the TUI hands to vaxis as cell segments.
//!
//! Backed by the vendored cmark-gfm C library — full CommonMark
//! parsing including the corner cases (`**bold *with italic* end**`,
//! snake_case underscore guards, escaped markers, etc.). We feed each
//! TUI line to cmark independently and walk its AST. Multi-line
//! constructs (fenced code blocks, nested lists) aren't reached
//! through this entry point — they'd require feeding the whole
//! assistant buffer to cmark, which is a bigger TUI integration.
//!
//! Public surface is unchanged from the previous hand-rolled parser:
//! callers just see `Span` and `tokenize`.

const std = @import("std");

const c = @cImport({
    @cInclude("cmark-gfm.h");
});

pub const Span = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
};

pub const Error = error{CmarkParseFailed} || std.mem.Allocator.Error;

/// Produce a span list for `line`. All `Span.text` slices are owned
/// by `arena` (we copy out of cmark's owned strings since the AST is
/// freed before we return).
pub fn tokenize(arena: std.mem.Allocator, line: []const u8) Error![]Span {
    var spans: std.ArrayList(Span) = .empty;

    const root = c.cmark_parse_document(
        line.ptr,
        line.len,
        c.CMARK_OPT_DEFAULT,
    ) orelse return Error.CmarkParseFailed;
    defer c.cmark_node_free(root);

    const iter = c.cmark_iter_new(root) orelse return Error.CmarkParseFailed;
    defer c.cmark_iter_free(iter);

    var state: WalkState = .{ .arena = arena, .out = &spans };

    while (true) {
        const ev = c.cmark_iter_next(iter);
        if (ev == c.CMARK_EVENT_DONE) break;
        try state.visit(ev, c.cmark_iter_get_node(iter));
    }

    return spans.toOwnedSlice(arena);
}

const WalkState = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(Span),
    bold_depth: u8 = 0,
    italic_depth: u8 = 0,
    /// Set when we're inside a HEADING node — every TEXT under it
    /// renders bold. Cleared on EXIT HEADING.
    in_heading: bool = false,

    fn currentBold(self: WalkState) bool {
        return self.bold_depth > 0 or self.in_heading;
    }

    fn currentItalic(self: WalkState) bool {
        return self.italic_depth > 0;
    }

    fn pushSpan(self: *WalkState, text_z: [*c]const u8, code: bool) !void {
        const text = std.mem.span(text_z);
        if (text.len == 0) return;
        const owned = try self.arena.dupe(u8, text);
        try self.out.append(self.arena, .{
            .text = owned,
            .bold = self.currentBold(),
            .italic = self.currentItalic() and !code,
            .code = code,
        });
    }

    fn visit(self: *WalkState, ev: c.cmark_event_type, node: ?*c.cmark_node) !void {
        const n = node orelse return;
        const t = c.cmark_node_get_type(n);
        switch (t) {
            c.CMARK_NODE_STRONG => {
                if (ev == c.CMARK_EVENT_ENTER) self.bold_depth += 1;
                if (ev == c.CMARK_EVENT_EXIT and self.bold_depth > 0) self.bold_depth -= 1;
            },
            c.CMARK_NODE_EMPH => {
                if (ev == c.CMARK_EVENT_ENTER) self.italic_depth += 1;
                if (ev == c.CMARK_EVENT_EXIT and self.italic_depth > 0) self.italic_depth -= 1;
            },
            c.CMARK_NODE_HEADING => {
                if (ev == c.CMARK_EVENT_ENTER) self.in_heading = true;
                if (ev == c.CMARK_EVENT_EXIT) self.in_heading = false;
            },
            c.CMARK_NODE_ITEM => {
                // Each list item gets a "• " marker prepended on
                // entry. For nested items cmark fires this for each
                // inner ITEM as well.
                if (ev == c.CMARK_EVENT_ENTER) {
                    try self.out.append(self.arena, .{
                        .text = "• ",
                        .bold = self.currentBold(),
                    });
                }
            },
            c.CMARK_NODE_TEXT => {
                if (ev == c.CMARK_EVENT_ENTER) {
                    if (c.cmark_node_get_literal(n)) |lit| try self.pushSpan(lit, false);
                }
            },
            c.CMARK_NODE_CODE => {
                if (ev == c.CMARK_EVENT_ENTER) {
                    if (c.cmark_node_get_literal(n)) |lit| try self.pushSpan(lit, true);
                }
            },
            c.CMARK_NODE_SOFTBREAK, c.CMARK_NODE_LINEBREAK => {
                // Per-line input shouldn't see these, but guard
                // anyway: render as a single space.
                if (ev == c.CMARK_EVENT_ENTER) {
                    try self.out.append(self.arena, .{
                        .text = " ",
                        .bold = self.currentBold(),
                    });
                }
            },
            c.CMARK_NODE_LINK, c.CMARK_NODE_IMAGE => {
                // For now we render link text inline with italic so
                // users can see the anchor; the URL is dropped. A
                // future commit can add a separate underlined style
                // or print `text (url)`.
                if (ev == c.CMARK_EVENT_ENTER) self.italic_depth += 1;
                if (ev == c.CMARK_EVENT_EXIT and self.italic_depth > 0) self.italic_depth -= 1;
            },
            else => {},
        }
    }
};

// ───────── tests ─────────

const testing = std.testing;

test "tokenize: plain text → single plain span" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "hello world");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("hello world", spans[0].text);
    try testing.expect(!spans[0].bold);
}

test "tokenize: bold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "yo **emphasis** ok");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("yo ", spans[0].text);
    try testing.expectEqualStrings("emphasis", spans[1].text);
    try testing.expect(spans[1].bold);
    try testing.expectEqualStrings(" ok", spans[2].text);
}

test "tokenize: italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "yo *gentle* ok");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("gentle", spans[1].text);
    try testing.expect(spans[1].italic);
}

test "tokenize: code span" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "use `arena.dupe(u8, x)` to copy");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("arena.dupe(u8, x)", spans[1].text);
    try testing.expect(spans[1].code);
}

test "tokenize: header sets line_bold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "## Setup");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("Setup", spans[0].text);
    try testing.expect(spans[0].bold);
}

test "tokenize: bullet substitutes •" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "- first item");
    try testing.expectEqualStrings("• ", spans[0].text);
    try testing.expectEqualStrings("first item", spans[1].text);
}

test "tokenize: snake_case is not italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "set my_var to 1");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expect(!spans[0].italic);
}

test "tokenize: unmatched marker is literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "**not closed");
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("**not closed", spans[0].text);
}

test "tokenize: code is opaque (no nested formatting)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "see `**not bold**` literally");
    try testing.expectEqualStrings("**not bold**", spans[1].text);
    try testing.expect(spans[1].code);
    try testing.expect(!spans[1].bold);
}

test "tokenize: bold can wrap italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "**bold *with italic* end**");
    var has_bold_italic = false;
    for (spans) |s| {
        if (s.bold and s.italic) has_bold_italic = true;
    }
    try testing.expect(has_bold_italic);
}

test "tokenize: link emits italic text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "see [the docs](https://example.com)");
    var has_link_text = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "the docs") and s.italic) has_link_text = true;
    }
    try testing.expect(has_link_text);
}
