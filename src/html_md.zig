//! HTML → markdown converter. Pragmatic, not a full HTML5 spec
//! implementation: enough to turn a typical web page's article
//! body into something a language model can read and a human can
//! diff. Strips `<script>`, `<style>`, and HTML comments wholesale.
//!
//! Supported elements:
//!   <h1>..<h6>             → `#` … `######` headings
//!   <p>, <br>              → paragraph / hard break
//!   <a href="X">Y</a>      → `[Y](X)`
//!   <strong>, <b>          → `**…**`
//!   <em>, <i>              → `*…*`
//!   <code>                 → `` `…` ``
//!   <pre><code>…</code></pre>
//!                          → fenced code block (language from
//!                            `class="language-XXX"` if present)
//!   <ul>, <ol>, <li>       → `- item` / `1. item`
//!   <blockquote>           → `> …`
//!   <hr>                   → `---`
//!
//! Everything else is collapsed to its text content.

const std = @import("std");

pub const Options = struct {
    /// Cap on characters of text output. Defaults to ~12k which
    /// is a reasonable token budget for a single web page.
    max_chars: usize = 12 * 1024,
};

pub const Error = error{} || std.mem.Allocator.Error;

const Tag = enum {
    p,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    a,
    strong,
    em,
    code,
    pre,
    ul,
    ol,
    li,
    blockquote,
    br,
    hr,
    script,
    style,
    other,
};

fn tagOf(name: []const u8) Tag {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return .other;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..name.len];
    if (std.mem.eql(u8, lower, "p")) return .p;
    if (std.mem.eql(u8, lower, "h1")) return .h1;
    if (std.mem.eql(u8, lower, "h2")) return .h2;
    if (std.mem.eql(u8, lower, "h3")) return .h3;
    if (std.mem.eql(u8, lower, "h4")) return .h4;
    if (std.mem.eql(u8, lower, "h5")) return .h5;
    if (std.mem.eql(u8, lower, "h6")) return .h6;
    if (std.mem.eql(u8, lower, "a")) return .a;
    if (std.mem.eql(u8, lower, "strong")) return .strong;
    if (std.mem.eql(u8, lower, "b")) return .strong;
    if (std.mem.eql(u8, lower, "em")) return .em;
    if (std.mem.eql(u8, lower, "i")) return .em;
    if (std.mem.eql(u8, lower, "code")) return .code;
    if (std.mem.eql(u8, lower, "pre")) return .pre;
    if (std.mem.eql(u8, lower, "ul")) return .ul;
    if (std.mem.eql(u8, lower, "ol")) return .ol;
    if (std.mem.eql(u8, lower, "li")) return .li;
    if (std.mem.eql(u8, lower, "blockquote")) return .blockquote;
    if (std.mem.eql(u8, lower, "br")) return .br;
    if (std.mem.eql(u8, lower, "hr")) return .hr;
    if (std.mem.eql(u8, lower, "script")) return .script;
    if (std.mem.eql(u8, lower, "style")) return .style;
    return .other;
}

const Frame = struct {
    tag: Tag,
    /// For <a>: collected `href`. For <pre> wrapping code: language
    /// (extracted from a child <code>'s class).
    attr: []const u8 = "",
    /// Output position when this frame opened — used by close to
    /// retroactively wrap (e.g. for <a> we replace child text with
    /// `[text](href)`).
    open_at: usize,
    /// For <ol> tracking — current item number.
    counter: u32 = 0,
};

const Renderer = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    /// True when we're inside <pre> — newlines inside text are kept verbatim.
    in_pre: u8 = 0,
    /// True when we're inside an inline element where consecutive
    /// whitespace should collapse to a single space.
    last_was_space: bool = true,
    max_chars: usize,

    fn pushText(self: *Renderer, text: []const u8) !void {
        if (self.out.items.len >= self.max_chars) return;
        if (self.in_pre > 0) {
            try self.appendCapped(text);
            return;
        }
        // Whitespace collapsing for normal flow.
        for (text) |c| {
            if (self.out.items.len >= self.max_chars) return;
            if (std.ascii.isWhitespace(c)) {
                if (!self.last_was_space) {
                    try self.out.append(self.arena, ' ');
                    self.last_was_space = true;
                }
            } else {
                try self.out.append(self.arena, c);
                self.last_was_space = false;
            }
        }
    }

    fn appendCapped(self: *Renderer, s: []const u8) !void {
        const remaining = self.max_chars -| self.out.items.len;
        if (remaining == 0) return;
        const take = @min(s.len, remaining);
        try self.out.appendSlice(self.arena, s[0..take]);
        if (take > 0) self.last_was_space = (s[take - 1] == ' ' or s[take - 1] == '\n');
    }

    fn ensureBlankLine(self: *Renderer) !void {
        // Ensure the output ends with two newlines (for paragraph
        // boundaries). Trim trailing spaces first.
        while (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') {
            _ = self.out.pop();
        }
        var trailing_nl: usize = 0;
        var i = self.out.items.len;
        while (i > 0) : (i -= 1) {
            if (self.out.items[i - 1] != '\n') break;
            trailing_nl += 1;
        }
        const need: usize = if (self.out.items.len == 0) 0 else 2 -| trailing_nl;
        try self.out.appendNTimes(self.arena, '\n', need);
        self.last_was_space = true;
    }

    fn ensureNewline(self: *Renderer) !void {
        while (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') {
            _ = self.out.pop();
        }
        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] != '\n') {
            try self.out.append(self.arena, '\n');
        }
        self.last_was_space = true;
    }

    fn open(self: *Renderer, tag: Tag, attr: []const u8) !void {
        switch (tag) {
            .p, .blockquote => try self.ensureBlankLine(),
            .h1, .h2, .h3, .h4, .h5, .h6 => |h| {
                try self.ensureBlankLine();
                const n: u8 = switch (h) {
                    .h1 => 1,
                    .h2 => 2,
                    .h3 => 3,
                    .h4 => 4,
                    .h5 => 5,
                    .h6 => 6,
                    else => unreachable,
                };
                try self.out.appendNTimes(self.arena, '#', n);
                try self.out.append(self.arena, ' ');
                self.last_was_space = true;
            },
            .strong => try self.appendCapped("**"),
            .em => try self.appendCapped("*"),
            .code => {
                // Inside <pre> we're rendering a fenced block —
                // don't wrap the body in inline backticks.
                if (self.in_pre == 0) try self.appendCapped("`");
            },
            .pre => {
                try self.ensureBlankLine();
                try self.appendCapped("```");
                if (attr.len > 0) try self.appendCapped(attr);
                try self.appendCapped("\n");
                self.in_pre += 1;
            },
            .br => try self.appendCapped("\n"),
            .hr => {
                try self.ensureBlankLine();
                try self.appendCapped("---");
                try self.ensureBlankLine();
            },
            .ul, .ol => try self.ensureNewline(),
            .li => {
                try self.ensureNewline();
                // Find enclosing list to tell ul vs ol + counter.
                var i = self.stack.items.len;
                while (i > 0) : (i -= 1) {
                    const f = &self.stack.items[i - 1];
                    if (f.tag == .ol) {
                        f.counter += 1;
                        const marker = try std.fmt.allocPrint(self.arena, "{d}. ", .{f.counter});
                        try self.appendCapped(marker);
                        return;
                    }
                    if (f.tag == .ul) {
                        try self.appendCapped("- ");
                        return;
                    }
                }
                try self.appendCapped("- ");
            },
            .a, .other, .script, .style => {},
        }
        try self.stack.append(self.arena, .{
            .tag = tag,
            .attr = attr,
            .open_at = self.out.items.len,
        });
    }

    fn close(self: *Renderer, tag: Tag) !void {
        // Pop until we find the matching tag (handle malformed
        // HTML where some elements weren't closed).
        var i = self.stack.items.len;
        while (i > 0) : (i -= 1) {
            if (self.stack.items[i - 1].tag != tag) continue;
            const frame = self.stack.items[i - 1];
            self.stack.shrinkRetainingCapacity(i - 1);
            switch (tag) {
                .p, .blockquote, .h1, .h2, .h3, .h4, .h5, .h6 => try self.ensureBlankLine(),
                .strong => try self.appendCapped("**"),
                .em => try self.appendCapped("*"),
                .code => {
                    if (self.in_pre == 0) try self.appendCapped("`");
                },
                .pre => {
                    if (self.in_pre > 0) self.in_pre -= 1;
                    try self.ensureNewline();
                    try self.appendCapped("```");
                    try self.ensureBlankLine();
                },
                .a => {
                    if (frame.attr.len == 0) return;
                    // Wrap [text](href) by injecting at open_at and after.
                    const text_start = frame.open_at;
                    const text_end = self.out.items.len;
                    if (text_end <= text_start) return;
                    const text = try self.arena.dupe(u8, self.out.items[text_start..text_end]);
                    self.out.shrinkRetainingCapacity(text_start);
                    try self.appendCapped("[");
                    try self.appendCapped(text);
                    try self.appendCapped("](");
                    try self.appendCapped(frame.attr);
                    try self.appendCapped(")");
                },
                .ul, .ol => try self.ensureBlankLine(),
                .li => try self.ensureNewline(),
                else => {},
            }
            return;
        }
    }
};

/// Convert `html` into markdown. Trims leading/trailing whitespace
/// and collapses runs of blank lines to at most two.
pub fn convert(arena: std.mem.Allocator, html: []const u8, opts: Options) ![]const u8 {
    var r: Renderer = .{ .arena = arena, .max_chars = opts.max_chars };

    var i: usize = 0;
    while (i < html.len) {
        if (r.out.items.len >= r.max_chars) break;

        // HTML comments
        if (i + 4 <= html.len and std.mem.eql(u8, html[i .. i + 4], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
            i = if (end < html.len) end + 3 else html.len;
            continue;
        }

        if (html[i] == '<' and i + 1 < html.len) {
            const close_tag = html[i + 1] == '/';
            const name_start = i + 1 + @as(usize, if (close_tag) 1 else 0);
            const tag_end = std.mem.indexOfScalarPos(u8, html, name_start, '>') orelse {
                i += 1;
                continue;
            };
            // Tag name: from name_start until whitespace, '>' or '/'.
            var name_end = name_start;
            while (name_end < tag_end and !std.ascii.isWhitespace(html[name_end]) and html[name_end] != '/') name_end += 1;
            const tag_name = html[name_start..name_end];
            const tag = tagOf(tag_name);

            // Skip <script>...</script> and <style>...</style> wholesale.
            if (!close_tag and (tag == .script or tag == .style)) {
                const end_marker = if (tag == .script) "</script" else "</style";
                const end = std.mem.indexOfPos(u8, html, tag_end + 1, end_marker);
                if (end) |e| {
                    const after = std.mem.indexOfScalarPos(u8, html, e, '>') orelse html.len;
                    i = if (after < html.len) after + 1 else html.len;
                } else {
                    i = html.len;
                }
                continue;
            }

            // For self-closing tags (<br>, <hr>, <br/>) just open.
            const self_closing = tag == .br or tag == .hr or
                (tag_end > 0 and html[tag_end - 1] == '/');
            const attr_zone = if (name_end < tag_end) html[name_end..tag_end] else "";

            if (close_tag) {
                try r.close(tag);
            } else if (tag == .a) {
                try r.open(tag, attrValue(attr_zone, "href"));
            } else if (tag == .pre) {
                // Look ahead for an inner <code class="language-X"> to capture.
                const lang = innerCodeLanguage(html, tag_end + 1);
                try r.open(tag, lang);
            } else {
                try r.open(tag, "");
            }
            if (self_closing and !close_tag) {
                try r.close(tag);
            }
            i = tag_end + 1;
            continue;
        }

        // Decode common HTML entities inline.
        if (html[i] == '&') {
            if (decodeEntity(html[i..])) |result| {
                try r.pushText(result.text);
                i += result.consumed;
                continue;
            }
        }

        try r.pushText(html[i .. i + 1]);
        i += 1;
    }

    return std.mem.trim(u8, r.out.items, " \n\r\t");
}

fn attrValue(attr_zone: []const u8, name: []const u8) []const u8 {
    var i: usize = 0;
    while (i < attr_zone.len) {
        // Skip whitespace
        while (i < attr_zone.len and std.ascii.isWhitespace(attr_zone[i])) i += 1;
        // Read name
        const n_start = i;
        while (i < attr_zone.len and attr_zone[i] != '=' and !std.ascii.isWhitespace(attr_zone[i])) i += 1;
        const this_name = attr_zone[n_start..i];
        // Skip whitespace + '='
        while (i < attr_zone.len and std.ascii.isWhitespace(attr_zone[i])) i += 1;
        if (i >= attr_zone.len or attr_zone[i] != '=') {
            // Bare attribute without value
            continue;
        }
        i += 1; // past '='
        while (i < attr_zone.len and std.ascii.isWhitespace(attr_zone[i])) i += 1;
        if (i >= attr_zone.len) break;
        const quoted = attr_zone[i] == '"' or attr_zone[i] == '\'';
        const quote = if (quoted) attr_zone[i] else 0;
        if (quoted) i += 1;
        const v_start = i;
        if (quoted) {
            while (i < attr_zone.len and attr_zone[i] != quote) i += 1;
        } else {
            while (i < attr_zone.len and !std.ascii.isWhitespace(attr_zone[i])) i += 1;
        }
        const value = attr_zone[v_start..i];
        if (eqIgnoreCase(this_name, name)) return value;
        if (quoted and i < attr_zone.len) i += 1;
    }
    return "";
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// When we just opened `<pre>`, peek ahead for a `<code class="language-X">`
/// so we can stamp the fence with a language label.
fn innerCodeLanguage(html: []const u8, after_pre: usize) []const u8 {
    // Skip whitespace
    var i = after_pre;
    while (i < html.len and std.ascii.isWhitespace(html[i])) i += 1;
    if (i + 5 >= html.len) return "";
    const lower_chunk_end = @min(i + 32, html.len);
    var lc: [32]u8 = undefined;
    for (html[i..lower_chunk_end], 0..) |c, idx| lc[idx] = std.ascii.toLower(c);
    const peek = lc[0 .. lower_chunk_end - i];
    if (!std.mem.startsWith(u8, peek, "<code")) return "";
    // Find tag end and extract class attribute
    const tag_end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return "";
    const class = attrValue(html[i + 5 .. tag_end], "class");
    // Look for "language-XXX" prefix in class list.
    var iter = std.mem.tokenizeAny(u8, class, " \t");
    while (iter.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "language-")) return tok["language-".len..];
    }
    return "";
}

const EntityResult = struct {
    text: []const u8,
    consumed: usize,
};

fn decodeEntity(s: []const u8) ?EntityResult {
    if (s.len < 3 or s[0] != '&') return null;
    // Numeric: &#nnn; or &#xHH;
    if (s[1] == '#') {
        const semi = std.mem.indexOfScalar(u8, s, ';') orelse return null;
        if (semi > 8) return null;
        const body = s[2..semi];
        const code: u32 = if (body.len > 0 and (body[0] == 'x' or body[0] == 'X'))
            std.fmt.parseInt(u32, body[1..], 16) catch return null
        else
            std.fmt.parseInt(u32, body, 10) catch return null;
        // Encode as UTF-8 into a static buffer (tiny, returned slice).
        const Static = struct {
            var buf: [4]u8 = undefined;
        };
        const len = std.unicode.utf8Encode(@intCast(@min(code, 0x10FFFF)), &Static.buf) catch return null;
        return .{ .text = Static.buf[0..len], .consumed = semi + 1 };
    }
    // Named entities — we cover the basics.
    const named = [_]struct { name: []const u8, repl: []const u8 }{
        .{ .name = "&amp;", .repl = "&" },
        .{ .name = "&lt;", .repl = "<" },
        .{ .name = "&gt;", .repl = ">" },
        .{ .name = "&quot;", .repl = "\"" },
        .{ .name = "&apos;", .repl = "'" },
        .{ .name = "&nbsp;", .repl = " " },
        .{ .name = "&mdash;", .repl = "—" },
        .{ .name = "&ndash;", .repl = "–" },
        .{ .name = "&hellip;", .repl = "…" },
    };
    for (named) |n| {
        if (s.len >= n.name.len and std.mem.eql(u8, s[0..n.name.len], n.name)) {
            return .{ .text = n.repl, .consumed = n.name.len };
        }
    }
    return null;
}

// ───────── tests ─────────

const testing = std.testing;

fn convertExpect(html: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try convert(arena.allocator(), html, .{});
    try testing.expectEqualStrings(expected, out);
}

test "convert: plain text" {
    try convertExpect("hello", "hello");
}

test "convert: paragraphs separated by blank line" {
    try convertExpect("<p>one</p><p>two</p>", "one\n\ntwo");
}

test "convert: heading levels" {
    try convertExpect("<h1>Title</h1>", "# Title");
    try convertExpect("<h3>Subhead</h3>", "### Subhead");
}

test "convert: bold and italic" {
    try convertExpect("<p>see <strong>this</strong> and <em>that</em></p>", "see **this** and *that*");
}

test "convert: inline code" {
    try convertExpect("<p>use <code>foo()</code></p>", "use `foo()`");
}

test "convert: link with text" {
    try convertExpect("<p>see <a href=\"https://x.com\">our docs</a></p>", "see [our docs](https://x.com)");
}

test "convert: unordered list" {
    try convertExpect("<ul><li>one</li><li>two</li></ul>", "- one\n- two");
}

test "convert: ordered list numbered" {
    try convertExpect("<ol><li>first</li><li>second</li></ol>", "1. first\n2. second");
}

test "convert: code block with language class" {
    try convertExpect(
        "<pre><code class=\"language-zig\">const x = 1;\n</code></pre>",
        "```zig\nconst x = 1;\n```",
    );
}

test "convert: script blocks are stripped" {
    try convertExpect(
        "<p>before</p><script>alert('boo')</script><p>after</p>",
        "before\n\nafter",
    );
}

test "convert: style blocks are stripped" {
    try convertExpect(
        "<style>body { color: red }</style><p>hi</p>",
        "hi",
    );
}

test "convert: html comments are stripped" {
    try convertExpect(
        "<!-- bye --><p>hi</p>",
        "hi",
    );
}

test "convert: entity decoding" {
    try convertExpect("<p>5 &lt; 10 &amp; 10 &gt; 5</p>", "5 < 10 & 10 > 5");
    try convertExpect("<p>&#65; &#x42;</p>", "A B");
    try convertExpect("<p>&mdash;</p>", "—");
}

test "convert: collapses whitespace in flow text" {
    try convertExpect("<p>too    many\n  spaces</p>", "too many spaces");
}

test "convert: br emits newline" {
    try convertExpect("<p>line1<br>line2</p>", "line1\nline2");
}

test "convert: ignores unknown tags but keeps text" {
    try convertExpect("<div><span>hi</span></div>", "hi");
}

test "convert: malformed unclosed tag survives" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try convert(arena.allocator(), "<p>open <strong>bold no close", .{});
    try testing.expect(std.mem.indexOf(u8, out, "open") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bold no close") != null);
}

test "convert: respects max_chars cap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const html = "<p>" ++ ("x" ** 5000) ++ "</p>";
    const out = try convert(arena.allocator(), html, .{ .max_chars = 100 });
    try testing.expect(out.len <= 100);
}
