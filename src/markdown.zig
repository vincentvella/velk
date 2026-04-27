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

/// Top-level segment produced by `parseBlocks`. Splits a full
/// assistant-text buffer into prose runs and fenced code blocks so
/// the TUI can render the latter as a distinct block kind without
/// trying to inline-parse triple-backtick markers.
pub const Segment = union(enum) {
    text: []const u8,
    code: CodeBlock,
};

pub const CodeBlock = struct {
    /// Fence info string (e.g. "zig", "python"). Empty when the
    /// opening fence has no tag.
    language: []const u8,
    /// Verbatim body bytes (without the surrounding ``` lines or
    /// the closing fence's trailing \n).
    body: []const u8,
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

/// Per-list bookkeeping so ordered lists keep their numbers. Pushed on
/// ENTER LIST, popped on EXIT LIST. The TUI only ever sees one line at
/// a time so the stack is shallow in practice; depth 16 is overkill.
const ListCtx = struct {
    ordered: bool,
    counter: i32,
};

const WalkState = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(Span),
    bold_depth: u8 = 0,
    italic_depth: u8 = 0,
    /// Set when we're inside a HEADING node — every TEXT under it
    /// renders bold. Cleared on EXIT HEADING.
    in_heading: bool = false,
    /// Block-quote depth — text inside a quote renders italic and
    /// gets a leading `│ ` marker.
    quote_depth: u8 = 0,
    list_stack: [16]ListCtx = undefined,
    list_depth: u8 = 0,

    fn currentBold(self: WalkState) bool {
        return self.bold_depth > 0 or self.in_heading;
    }

    fn currentItalic(self: WalkState) bool {
        return self.italic_depth > 0 or self.quote_depth > 0;
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

    fn pushLiteral(self: *WalkState, text: []const u8, code: bool) !void {
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
            c.CMARK_NODE_BLOCK_QUOTE => {
                if (ev == c.CMARK_EVENT_ENTER) {
                    try self.out.append(self.arena, .{
                        .text = "│ ",
                        .bold = self.currentBold(),
                    });
                    self.quote_depth += 1;
                }
                if (ev == c.CMARK_EVENT_EXIT and self.quote_depth > 0) self.quote_depth -= 1;
            },
            c.CMARK_NODE_LIST => {
                if (ev == c.CMARK_EVENT_ENTER) {
                    if (self.list_depth < self.list_stack.len) {
                        const lt = c.cmark_node_get_list_type(n);
                        const start = c.cmark_node_get_list_start(n);
                        self.list_stack[self.list_depth] = .{
                            .ordered = lt == c.CMARK_ORDERED_LIST,
                            .counter = if (start == 0) 1 else start,
                        };
                        self.list_depth += 1;
                    }
                }
                if (ev == c.CMARK_EVENT_EXIT and self.list_depth > 0) {
                    self.list_depth -= 1;
                }
            },
            c.CMARK_NODE_ITEM => {
                if (ev == c.CMARK_EVENT_ENTER) {
                    if (self.list_depth > 0) {
                        const top = &self.list_stack[self.list_depth - 1];
                        if (top.ordered) {
                            const marker = try std.fmt.allocPrint(self.arena, "{d}. ", .{top.counter});
                            try self.out.append(self.arena, .{
                                .text = marker,
                                .bold = self.currentBold(),
                            });
                            top.counter += 1;
                        } else {
                            try self.out.append(self.arena, .{
                                .text = "• ",
                                .bold = self.currentBold(),
                            });
                        }
                    } else {
                        // Defensive: ITEM without a parent LIST.
                        try self.out.append(self.arena, .{
                            .text = "• ",
                            .bold = self.currentBold(),
                        });
                    }
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
            c.CMARK_NODE_HTML_INLINE, c.CMARK_NODE_HTML_BLOCK => {
                // Pass HTML through as literal text so users see what
                // the model wrote rather than a silent gap. No
                // styling — the chars themselves carry intent.
                if (ev == c.CMARK_EVENT_ENTER) {
                    if (c.cmark_node_get_literal(n)) |lit| try self.pushSpan(lit, false);
                }
            },
            c.CMARK_NODE_SOFTBREAK, c.CMARK_NODE_LINEBREAK => {
                // Per-line input shouldn't see these, but guard
                // anyway: render as a single space.
                if (ev == c.CMARK_EVENT_ENTER) {
                    try self.pushLiteral(" ", false);
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

/// Walk `source` line-by-line and split it into a sequence of prose
/// `text` runs and fenced `code` blocks. Triple-backtick fences
/// (` ``` ` or ` ```lang `) at the start of a line open / close a
/// block. An unclosed fence at the end of the buffer is emitted as
/// a code block anyway — useful while the assistant is still
/// streaming a fence body.
pub fn parseBlocks(arena: std.mem.Allocator, source: []const u8) ![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    var text_buf: std.ArrayList(u8) = .empty;
    var code_buf: std.ArrayList(u8) = .empty;
    var in_fence = false;
    var fence_lang: []const u8 = "";

    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_fence) {
                // Closing fence: emit accumulated code block, drop
                // the trailing \n we appended after the last body line.
                var body = code_buf.items;
                if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
                try out.append(arena, .{ .code = .{
                    .language = try arena.dupe(u8, fence_lang),
                    .body = try arena.dupe(u8, body),
                } });
                code_buf.clearRetainingCapacity();
                fence_lang = "";
                in_fence = false;
            } else {
                // Opening fence: flush pending text, capture lang.
                try flushTextBuf(arena, &out, &text_buf);
                fence_lang = std.mem.trim(u8, trimmed[3..], " \t\r");
                in_fence = true;
            }
            continue;
        }
        if (in_fence) {
            try code_buf.appendSlice(arena, raw);
            try code_buf.append(arena, '\n');
        } else {
            try text_buf.appendSlice(arena, raw);
            try text_buf.append(arena, '\n');
        }
    }

    // Streaming-friendly: if we ended inside a fence, emit whatever
    // we have so the TUI shows partial code instead of nothing.
    if (in_fence and code_buf.items.len > 0) {
        var body = code_buf.items;
        if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
        try out.append(arena, .{ .code = .{
            .language = try arena.dupe(u8, fence_lang),
            .body = try arena.dupe(u8, body),
        } });
    }
    try flushTextBuf(arena, &out, &text_buf);

    return out.toOwnedSlice(arena);
}

fn flushTextBuf(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Segment),
    buf: *std.ArrayList(u8),
) !void {
    if (buf.items.len == 0) return;
    var t = buf.items;
    if (t.len > 0 and t[t.len - 1] == '\n') t = t[0 .. t.len - 1];
    if (t.len > 0) try out.append(arena, .{ .text = try arena.dupe(u8, t) });
    buf.clearRetainingCapacity();
}

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

test "tokenize: numbered list keeps the number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "1. step one");
    try testing.expectEqualStrings("1. ", spans[0].text);
    try testing.expectEqualStrings("step one", spans[1].text);
}

test "tokenize: numbered list respects start number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // cmark only sees one ITEM in single-line input — verify it
    // honours the explicit start (5. not 1.).
    const spans = try tokenize(arena.allocator(), "5. step five");
    try testing.expectEqualStrings("5. ", spans[0].text);
}

test "tokenize: block quote gets │ marker and italic body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "> a quoted thought");
    try testing.expectEqualStrings("│ ", spans[0].text);
    var has_italic_body = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "a quoted thought") and s.italic) has_italic_body = true;
    }
    try testing.expect(has_italic_body);
}

test "tokenize: inline HTML passes through as literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "see <em>this</em> raw");
    var found_open = false;
    var found_close = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "<em>")) found_open = true;
        if (std.mem.eql(u8, s.text, "</em>")) found_close = true;
    }
    try testing.expect(found_open);
    try testing.expect(found_close);
}

test "tokenize: backslash escape renders literal marker" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "5 \\* 4 = 20");
    // No italic span — the \* is a literal asterisk.
    for (spans) |s| try testing.expect(!s.italic);
    // Reassemble plain text and confirm the asterisk survived.
    var sum: std.ArrayList(u8) = .empty;
    defer sum.deinit(testing.allocator);
    for (spans) |s| try sum.appendSlice(testing.allocator, s.text);
    try testing.expect(std.mem.indexOf(u8, sum.items, "*") != null);
}

test "tokenize: underscore italic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "yo _gentle_ ok");
    var has_italic = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "gentle") and s.italic) has_italic = true;
    }
    try testing.expect(has_italic);
}

test "tokenize: double-underscore bold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spans = try tokenize(arena.allocator(), "yo __strong__ ok");
    var has_bold = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "strong") and s.bold) has_bold = true;
    }
    try testing.expect(has_bold);
}

test "parseBlocks: prose only is one text segment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const segs = try parseBlocks(arena.allocator(), "hello\nworld");
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("hello\nworld", segs[0].text);
}

test "parseBlocks: empty input is no segments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const segs = try parseBlocks(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), segs.len);
}

test "parseBlocks: fenced code block with language tag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const segs = try parseBlocks(arena.allocator(),
        "Here you go:\n```zig\nconst x = 1;\nconst y = 2;\n```\nThat's it.");
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expectEqualStrings("Here you go:", segs[0].text);
    try testing.expectEqualStrings("zig", segs[1].code.language);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;", segs[1].code.body);
    try testing.expectEqualStrings("That's it.", segs[2].text);
}

test "parseBlocks: fence without language tag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const segs = try parseBlocks(arena.allocator(),
        "```\nplain block\n```");
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("", segs[0].code.language);
    try testing.expectEqualStrings("plain block", segs[0].code.body);
}

test "parseBlocks: unclosed fence still emits as code (streaming-friendly)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const segs = try parseBlocks(arena.allocator(),
        "intro\n```py\npartial body\nstill streaming");
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqualStrings("intro", segs[0].text);
    try testing.expectEqualStrings("py", segs[1].code.language);
    try testing.expectEqualStrings("partial body\nstill streaming", segs[1].code.body);
}

test "parseBlocks: two adjacent fences" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const segs = try parseBlocks(arena.allocator(),
        "```js\nfoo\n```\n```py\nbar\n```");
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqualStrings("js", segs[0].code.language);
    try testing.expectEqualStrings("foo", segs[0].code.body);
    try testing.expectEqualStrings("py", segs[1].code.language);
    try testing.expectEqualStrings("bar", segs[1].code.body);
}
