//! `@file` and `@symbol` mention expansion. Scans a user prompt
//! for tokens of the form:
//!
//!   @path                 — attach whole file
//!   @path:N               — attach line N
//!   @path:N-M             — attach lines N..M
//!   @symbol               — attach files whose top-level decl
//!                           matches `(pub )?(fn|const|var|extern fn) <symbol>`
//!
//! The original mention text stays in the prompt — the LLM sees
//! both the file content (in the attachments block) and the user's
//! reference to it. Path-or-symbol routing: a token that contains
//! `/` or fails to read as a literal file but matches an identifier
//! pattern falls through to symbol search.
//!
//! Path safety: lexical validation against CWD. We reject paths
//! that escape via `..` so a malicious `@../../etc/passwd` doesn't
//! exfiltrate. Caller controls the actual sandbox via `unsafe`.

const std = @import("std");
const Io = std.Io;
const ignore = @import("ignore.zig");
const mvzr = @import("mvzr");

pub const max_mention_bytes: usize = 64 * 1024;

pub const Mention = struct {
    path: []const u8,
    start_line: ?usize = null, // 1-based inclusive
    end_line: ?usize = null, // inclusive
};

/// Pure parser: walk `prompt` and return every `@path` /
/// `@path:N-M` token. Ignores `@` followed by whitespace, end of
/// string, or a digit (so `@1234` for context-cap discussion etc.
/// doesn't try to read a file). Mentions can appear anywhere on a
/// line and are terminated by whitespace.
pub fn parse(arena: std.mem.Allocator, prompt: []const u8) ![]const Mention {
    var out: std.ArrayList(Mention) = .empty;
    var i: usize = 0;
    while (i < prompt.len) : (i += 1) {
        if (prompt[i] != '@') continue;
        // Boundary: either start of string or preceded by whitespace.
        if (i > 0 and !std.ascii.isWhitespace(prompt[i - 1])) continue;
        const start = i + 1;
        if (start >= prompt.len) break;
        if (std.ascii.isWhitespace(prompt[start])) continue;
        if (std.ascii.isDigit(prompt[start])) continue;

        // Walk to next whitespace or end.
        var end = start;
        while (end < prompt.len and !std.ascii.isWhitespace(prompt[end])) end += 1;
        const token = prompt[start..end];

        // Split off optional `:N-M` line-range tail.
        var path = token;
        var sl: ?usize = null;
        var el: ?usize = null;
        if (std.mem.lastIndexOfScalar(u8, token, ':')) |colon| {
            const range = token[colon + 1 ..];
            if (parseLineRange(range)) |r| {
                path = token[0..colon];
                sl = r.start;
                el = r.end;
            }
        }
        if (path.len == 0) {
            i = end;
            continue;
        }
        try out.append(arena, .{
            .path = try arena.dupe(u8, path),
            .start_line = sl,
            .end_line = el,
        });
        i = end;
    }
    return out.toOwnedSlice(arena);
}

const Range = struct { start: usize, end: usize };

fn parseLineRange(s: []const u8) ?Range {
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
        const a = std.fmt.parseInt(usize, s[0..dash], 10) catch return null;
        const b = std.fmt.parseInt(usize, s[dash + 1 ..], 10) catch return null;
        if (a == 0 or b == 0 or b < a) return null;
        return .{ .start = a, .end = b };
    }
    // Single line: `@path:42` → just that line.
    const a = std.fmt.parseInt(usize, s, 10) catch return null;
    if (a == 0) return null;
    return .{ .start = a, .end = a };
}

/// Validate against CWD-only escape: reject absolute paths and any
/// component-level `..`. When `unsafe = true` we let everything
/// through (matches the same flag elsewhere). Returns the path
/// unchanged on success.
pub fn validatePath(unsafe: bool, raw: []const u8) ![]const u8 {
    if (unsafe) return raw;
    if (raw.len == 0) return error.InvalidPath;
    if (raw[0] == '/') return error.PathOutsideCwd;
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return error.PathOutsideCwd;
    }
    return raw;
}

/// Read the bytes referenced by a single mention. Honours line
/// ranges by slicing after read. Returns null when the file
/// doesn't exist or the line range is out of bounds — caller
/// surfaces that as a soft error in the attachments block.
pub fn readMention(
    arena: std.mem.Allocator,
    io: Io,
    m: Mention,
    unsafe: bool,
) !?[]const u8 {
    _ = validatePath(unsafe, m.path) catch return null;
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, m.path, arena, .limited(max_mention_bytes)) catch |e| switch (e) {
        error.FileNotFound, error.IsDir => return null,
        else => return e,
    };

    const sl = m.start_line orelse return data;
    const el = m.end_line orelse data.len;

    // Slice by line. 1-based inclusive on both ends.
    var line_no: usize = 1;
    var slice_start: usize = 0;
    var slice_end: usize = data.len;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (line_no == sl and i == 0 or (i > 0 and data[i - 1] == '\n' and line_no == sl)) {
            slice_start = i;
        }
        if (data[i] == '\n') {
            if (line_no == el) {
                slice_end = i;
                break;
            }
            line_no += 1;
        }
    }
    if (sl > line_no) return null;
    return data[slice_start..@min(slice_end, data.len)];
}

/// True when `s` looks like an identifier (no path separators, all
/// alphanumeric / underscore, leading char is alpha or `_`).
/// Symbol-mention candidates have to pass this gate so we don't
/// kick off a full-repo grep for `@2024` or `@some.thing`.
pub fn looksLikeSymbol(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, '/') != null) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// Maximum files attached for a single `@symbol` mention.
pub const max_symbol_hits: usize = 3;

/// Walk the repo from CWD, looking for files containing a top-level
/// declaration of `name`. Returns up to `max_symbol_hits` paths,
/// honoring the common-ignore set. Pure path scan — caller calls
/// `readMention` with each result.
pub fn searchSymbol(
    arena: std.mem.Allocator,
    io: Io,
    name: []const u8,
) ![]const []const u8 {
    var hits: std.ArrayList([]const u8) = .empty;

    const pattern_str = try std.fmt.allocPrint(
        arena,
        "(pub )?(fn|const|var|extern fn) {s}",
        .{name},
    );
    var regex = mvzr.compile(pattern_str) orelse return &.{};

    var dir = Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (hits.items.len >= max_symbol_hits) break;
        if (entry.kind != .file) continue;
        if (ignore.isIgnored(entry.path)) continue;
        const data = Io.Dir.cwd().readFileAlloc(io, entry.path, arena, .limited(max_mention_bytes)) catch continue;
        // Scan line-by-line so we anchor the regex correctly (mvzr
        // doesn't gate `^` and we want top-level decls only).
        var line_iter = std.mem.splitScalar(u8, data, '\n');
        while (line_iter.next()) |line| {
            // Top-level: the line must NOT start with whitespace.
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;
            if (regex.isMatch(line)) {
                try hits.append(arena, try arena.dupe(u8, entry.path));
                break;
            }
        }
    }
    return hits.items;
}

/// Expand all mentions found in `prompt` into a single string with
/// an `<attachments>` block prepended. Returns the original prompt
/// unchanged when no mentions are present (so this is cheap to
/// call on every submit).
pub fn expand(
    arena: std.mem.Allocator,
    io: Io,
    prompt: []const u8,
    unsafe: bool,
) ![]const u8 {
    const mentions = try parse(arena, prompt);
    if (mentions.len == 0) return prompt;

    var attach: std.ArrayList(u8) = .empty;
    try attach.appendSlice(arena, "<attachments>\n");
    for (mentions) |m| {
        const body_opt = readMention(arena, io, m, unsafe) catch null;
        if (body_opt) |body| {
            if (m.start_line) |sl| {
                try attach.print(arena, "<file path=\"{s}\" lines=\"{d}-{d}\">\n", .{
                    m.path, sl, m.end_line orelse sl,
                });
            } else {
                try attach.print(arena, "<file path=\"{s}\">\n", .{m.path});
            }
            try attach.appendSlice(arena, body);
            if (body.len > 0 and body[body.len - 1] != '\n') try attach.append(arena, '\n');
            try attach.appendSlice(arena, "</file>\n");
            continue;
        }
        // Not a literal file — fall through to symbol search if the
        // token looks like an identifier.
        if (looksLikeSymbol(m.path)) {
            const hits = searchSymbol(arena, io, m.path) catch &[_][]const u8{};
            if (hits.len > 0) {
                for (hits) |hit_path| {
                    const data = Io.Dir.cwd().readFileAlloc(io, hit_path, arena, .limited(max_mention_bytes)) catch continue;
                    try attach.print(arena, "<file path=\"{s}\" matched-symbol=\"{s}\">\n", .{ hit_path, m.path });
                    try attach.appendSlice(arena, data);
                    if (data.len > 0 and data[data.len - 1] != '\n') try attach.append(arena, '\n');
                    try attach.appendSlice(arena, "</file>\n");
                }
                continue;
            }
        }
        try attach.print(arena, "<file path=\"{s}\" error=\"unreadable\"/>\n", .{m.path});
    }
    try attach.appendSlice(arena, "</attachments>\n\n");
    try attach.appendSlice(arena, prompt);
    return attach.items;
}

// ───────── tests ─────────

const testing = std.testing;

test "parse: bare @path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "look at @src/main.zig please");
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqualStrings("src/main.zig", m[0].path);
    try testing.expect(m[0].start_line == null);
}

test "parse: @path:start-end line range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "skim @src/tui.zig:50-120 mostly");
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqualStrings("src/tui.zig", m[0].path);
    try testing.expectEqual(@as(usize, 50), m[0].start_line.?);
    try testing.expectEqual(@as(usize, 120), m[0].end_line.?);
}

test "parse: @path:N single-line range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "see @file.txt:42");
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqual(@as(usize, 42), m[0].start_line.?);
    try testing.expectEqual(@as(usize, 42), m[0].end_line.?);
}

test "parse: multiple mentions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "compare @a.zig with @b.zig:1-10");
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqualStrings("a.zig", m[0].path);
    try testing.expectEqualStrings("b.zig", m[1].path);
}

test "parse: @ at start of prompt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "@README.md");
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqualStrings("README.md", m[0].path);
}

test "parse: @<digit> not treated as a path (matches '@1k tokens' style)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "context cap is @1234 tokens");
    try testing.expectEqual(@as(usize, 0), m.len);
}

test "parse: bare @ followed by whitespace ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "ping @ joe");
    try testing.expectEqual(@as(usize, 0), m.len);
}

test "parse: @ inside email-like text not a mention" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // `vince@example.com` — the @ is preceded by a non-whitespace
    // char, so it doesn't qualify.
    const m = try parse(arena.allocator(), "ping vince@example.com about it");
    try testing.expectEqual(@as(usize, 0), m.len);
}

test "validatePath: blocks .. + absolute paths when sandboxed" {
    try testing.expectError(error.PathOutsideCwd, validatePath(false, "../etc/passwd"));
    try testing.expectError(error.PathOutsideCwd, validatePath(false, "/etc/passwd"));
    try testing.expectError(error.PathOutsideCwd, validatePath(false, "src/../../etc/passwd"));
    _ = try validatePath(false, "src/main.zig");
    _ = try validatePath(true, "/etc/passwd"); // unsafe lets it through
}

test "expand: no mentions returns prompt unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try expand(arena.allocator(), undefined, "just a regular prompt", false);
    try testing.expectEqualStrings("just a regular prompt", out);
}

test "looksLikeSymbol: identifier-shaped tokens pass" {
    try testing.expect(looksLikeSymbol("maybeRequestApproval"));
    try testing.expect(looksLikeSymbol("Settings"));
    try testing.expect(looksLikeSymbol("_underscore"));
    try testing.expect(looksLikeSymbol("snake_case_name"));
    try testing.expect(looksLikeSymbol("name42"));
}

test "looksLikeSymbol: non-identifier tokens reject" {
    try testing.expect(!looksLikeSymbol(""));
    try testing.expect(!looksLikeSymbol("src/main.zig")); // path
    try testing.expect(!looksLikeSymbol("foo.bar")); // dotted (file ext)
    try testing.expect(!looksLikeSymbol("42name")); // leading digit
    try testing.expect(!looksLikeSymbol("name-with-dashes"));
    try testing.expect(!looksLikeSymbol("hello world"));
}
