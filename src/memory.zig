//! Persistent memory store. Files live under
//! `$XDG_DATA_HOME/velk/memdir/<topic>.md` (or `~/.local/share/...`)
//! and the model reads/writes them via the `read_memory` / `write_memory`
//! / `list_memories` tools defined in `tools.zig`. Topics are
//! filename-safe slugs; the body is whatever Markdown the model wants
//! to keep across sessions.
//!
//! v1 is intentionally small: no tags, no full-text search, no
//! LRU/limit. The model gets a bare topic→file mapping and decides
//! how to organize.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    HomeDirUnknown,
    InvalidTopic,
} || std.mem.Allocator.Error;

/// Resolves the on-disk root for memdir. Honors XDG_DATA_HOME, falls
/// back to $HOME/.local/share. Does NOT create the directory.
pub fn rootPath(arena: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    const base = if (env_map.get("XDG_DATA_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/share", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/memdir", .{base});
}

/// Topic slugifier. Lowercases, replaces runs of non-`[a-z0-9]`
/// chars with `-`, trims leading/trailing dashes, caps at 64 chars.
/// Rejects empty results so the caller knows the topic was nothing
/// but punctuation.
pub fn slugify(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var prev_dash = true; // start as if previous char was a dash so leading dashes get skipped
    for (raw) |c| {
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const is_alnum = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (is_alnum) {
            try buf.append(arena, lower);
            prev_dash = false;
        } else if (!prev_dash) {
            try buf.append(arena, '-');
            prev_dash = true;
        }
    }
    // Trim trailing dash.
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') _ = buf.pop();
    if (buf.items.len == 0) return Error.InvalidTopic;
    if (buf.items.len > 64) buf.shrinkRetainingCapacity(64);
    // After truncation the last char might be a dash — re-trim.
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') _ = buf.pop();
    if (buf.items.len == 0) return Error.InvalidTopic;
    return buf.items;
}

/// Joins root + slug + ".md" so callers always hit the right
/// extension and never accidentally write outside the memdir root.
pub fn topicPath(arena: std.mem.Allocator, root: []const u8, slug: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(arena, "{s}/{s}.md", .{ root, slug });
}

/// Read the body of one topic. Returns null when the topic doesn't
/// exist yet — the caller surfaces that as an empty result rather
/// than an error so the model can still decide what to write.
pub fn read(arena: std.mem.Allocator, io: Io, env_map: *std.process.Environ.Map, slug: []const u8) !?[]const u8 {
    const root = try rootPath(arena, env_map);
    const path = try topicPath(arena, root, slug);
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, arena, .limited(1 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return data;
}

/// Write (overwrite) one topic. Creates the memdir root on demand.
pub fn write(arena: std.mem.Allocator, io: Io, env_map: *std.process.Environ.Map, slug: []const u8, body: []const u8) !void {
    const root = try rootPath(arena, env_map);
    try mkdirAllAbsolute(io, root);
    const path = try topicPath(arena, root, slug);
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = path, .data = body });
}

pub const Entry = struct {
    /// Slug (no `.md` suffix).
    topic: []const u8,
    /// Bytes on disk — useful for the catalog summary so the
    /// model knows whether a topic is a one-liner or a long note.
    bytes: u64,
    /// Tags declared in the topic's optional `---`-fenced YAML
    /// frontmatter (`tags: [a, b]` or `tags: a, b`). Empty when
    /// the topic has no frontmatter or no `tags:` key.
    tags: []const []const u8 = &.{},
};

/// Read up to the first 4 KB of a memory file and extract any
/// `tags:` value from its YAML frontmatter. Pure helper — exposed for
/// tests; callers normally see tags via `Entry.tags` from `list`.
pub fn parseTags(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    if (!std.mem.startsWith(u8, body, "---")) return &.{};
    const after_open = body[3..];
    const header_start = std.mem.indexOfScalar(u8, after_open, '\n') orelse return &.{};
    const block_start: usize = 3 + header_start + 1;
    if (block_start > body.len) return &.{};
    const close_rel = std.mem.indexOf(u8, body[block_start..], "\n---") orelse return &.{};
    const block = body[block_start .. block_start + close_rel];
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "tags:")) continue;
        var v = std.mem.trim(u8, line["tags:".len..], " \t");
        if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') v = v[1 .. v.len - 1];
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |raw_tag| {
            const t = std.mem.trim(u8, raw_tag, " \t\"'");
            if (t.len > 0) try out.append(arena, try arena.dupe(u8, t));
        }
    }
    return out.items;
}

/// Enumerate every `<root>/*.md` file. Returns an empty slice when
/// memdir doesn't exist yet — the model can call `write_memory` to
/// create the first one.
pub fn list(arena: std.mem.Allocator, io: Io, env_map: *std.process.Environ.Map) ![]const Entry {
    const root = rootPath(arena, env_map) catch return &.{};
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    var out: std.ArrayList(Entry) = .empty;
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const slug = entry.name[0 .. entry.name.len - 3];
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        // Read just enough to cover any frontmatter without paying
        // the cost of slurping every body up-front. 4 KB comfortably
        // accommodates a few-line `---`-fenced YAML header.
        const head = dir.readFileAlloc(io, entry.name, arena, .limited(4 * 1024)) catch "";
        const tags = parseTags(arena, head) catch &.{};
        try out.append(arena, .{
            .topic = try arena.dupe(u8, slug),
            .bytes = stat.size,
            .tags = tags,
        });
    }
    return out.items;
}

pub const Hit = struct {
    /// Topic slug (no `.md`).
    topic: []const u8,
    /// 0-based line number where the match landed.
    line: usize,
    /// Up to 240 chars of the matching line, trimmed.
    snippet: []const u8,
};

/// Substring search across every memdir topic. Case-insensitive when
/// `query` is all-lowercase (the common case); literal otherwise.
/// Returns up to `max_hits` hits, scanned in directory-iteration
/// order. Long match lines are truncated to 240 chars to keep tool
/// output bounded.
pub fn search(
    arena: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
    query: []const u8,
    max_hits: usize,
    tag_filter: ?[]const u8,
) ![]const Hit {
    if (query.len == 0 and tag_filter == null) return &.{};
    const lower_query = std.ascii.allocLowerString(arena, query) catch return &.{};
    const case_insensitive = std.mem.eql(u8, lower_query, query);

    const root = rootPath(arena, env_map) catch return &.{};
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var hits: std.ArrayList(Hit) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (hits.items.len >= max_hits) break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const slug = entry.name[0 .. entry.name.len - 3];

        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.name });
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 * 1024 * 1024)) catch continue;

        // Tag filter: if set, the topic's frontmatter must include
        // a matching tag. Topics without frontmatter are skipped.
        if (tag_filter) |needle| {
            const tags = parseTags(arena, data) catch &.{};
            var matched = false;
            for (tags) |t| if (std.mem.eql(u8, t, needle)) {
                matched = true;
                break;
            };
            if (!matched) continue;
        }

        // Empty query + tag filter: synthesize a single hit per
        // matching topic so the model gets a useful list back.
        if (query.len == 0) {
            try hits.append(arena, .{
                .topic = try arena.dupe(u8, slug),
                .line = 0,
                .snippet = "",
            });
            continue;
        }

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            if (hits.items.len >= max_hits) break;
            const found: bool = if (case_insensitive)
                indexOfCaseInsensitive(line, query) != null
            else
                std.mem.indexOf(u8, line, query) != null;
            if (!found) continue;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const cap = @min(trimmed.len, 240);
            try hits.append(arena, .{
                .topic = try arena.dupe(u8, slug),
                .line = line_no,
                .snippet = try arena.dupe(u8, trimmed[0..cap]),
            });
        }
    }
    return hits.items;
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}

/// Render a `<memory-index>` block listing every topic + its byte
/// size. Suitable for prepending onto the system prompt at startup
/// so the model knows which long-term notes exist without having to
/// call `list_memories` first. Returns an empty slice when memdir is
/// empty — the caller skips the block entirely in that case.
pub fn formatIndex(arena: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    if (entries.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "<memory-index>\n");
    try buf.appendSlice(arena, "Long-term memory topics. Read with `read_memory <topic>`, write with `write_memory <topic> <body>`, find with `search_memory <query>`.\n\n");
    for (entries) |e| {
        try buf.print(arena, "- {s} ({d} bytes)", .{ e.topic, e.bytes });
        if (e.tags.len > 0) {
            try buf.appendSlice(arena, " · tags: ");
            for (e.tags, 0..) |t, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try buf.appendSlice(arena, t);
            }
        }
        try buf.append(arena, '\n');
    }
    try buf.appendSlice(arena, "</memory-index>\n");
    return buf.items;
}

fn mkdirAllAbsolute(io: Io, abs_path: []const u8) !void {
    if (abs_path.len == 0 or abs_path[0] != '/') return;
    var i: usize = 1;
    while (true) {
        const next = std.mem.indexOfScalarPos(u8, abs_path, i, '/');
        const end = next orelse abs_path.len;
        if (end > i) {
            const prefix = abs_path[0..end];
            Io.Dir.createDirAbsolute(io, prefix, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        if (next == null) return;
        i = end + 1;
    }
}

// ───────── tests ─────────

const testing = std.testing;

test "rootPath honors XDG_DATA_HOME" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("XDG_DATA_HOME", "/tmp/data");
    const p = try rootPath(arena_state.allocator(), &env);
    try testing.expectEqualStrings("/tmp/data/velk/memdir", p);
}

test "rootPath falls back to HOME" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("HOME", "/home/v");
    const p = try rootPath(arena_state.allocator(), &env);
    try testing.expectEqualStrings("/home/v/.local/share/velk/memdir", p);
}

test "slugify: ascii lowercased and stable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try slugify(arena_state.allocator(), "Hello World");
    try testing.expectEqualStrings("hello-world", s);
}

test "slugify: collapses non-alnum runs into single dash" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try slugify(arena_state.allocator(), "  Many !! Punctuations.. here  ");
    try testing.expectEqualStrings("many-punctuations-here", s);
}

test "slugify: rejects empty / pure-punctuation input" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(Error.InvalidTopic, slugify(arena_state.allocator(), ""));
    try testing.expectError(Error.InvalidTopic, slugify(arena_state.allocator(), "   "));
    try testing.expectError(Error.InvalidTopic, slugify(arena_state.allocator(), "!@#$%"));
}

test "slugify: caps at 64 chars and re-trims trailing dash" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // 64 'a's + tail that gets sliced — should land at 64 chars exactly.
    const big = "a" ** 64 ++ "-trailing";
    const s = try slugify(arena_state.allocator(), big);
    try testing.expectEqual(@as(usize, 64), s.len);
}

test "topicPath: composes root + slug + .md" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = try topicPath(arena_state.allocator(), "/tmp/memdir", "topic-name");
    try testing.expectEqualStrings("/tmp/memdir/topic-name.md", p);
}

test "list: returns empty when memdir doesn't exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);
    // No write yet → listing returns empty.
    const entries = try list(a, testing.io, &env);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "write+read+list: round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "first-topic", "first body\n");
    try write(a, testing.io, &env, "second-topic", "second body — longer note\n");

    const r1 = (try read(a, testing.io, &env, "first-topic")).?;
    try testing.expectEqualStrings("first body\n", r1);
    const r2 = (try read(a, testing.io, &env, "second-topic")).?;
    try testing.expect(std.mem.indexOf(u8, r2, "longer note") != null);

    // Missing topic → null, not error.
    const missing = try read(a, testing.io, &env, "never-written");
    try testing.expect(missing == null);

    const entries = try list(a, testing.io, &env);
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Both slugs present (order is filesystem-defined).
    var saw_first = false;
    var saw_second = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.topic, "first-topic")) saw_first = true;
        if (std.mem.eql(u8, e.topic, "second-topic")) saw_second = true;
    }
    try testing.expect(saw_first and saw_second);
}

test "formatIndex: empty list yields empty string" {
    const out = try formatIndex(testing.allocator, &.{});
    try testing.expectEqualStrings("", out);
}

test "formatIndex: lists topics + byte sizes inside fence" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const entries = [_]Entry{
        .{ .topic = "user-prefs", .bytes = 42 },
        .{ .topic = "project-notes", .bytes = 1024 },
    };
    const out = try formatIndex(a, &entries);
    try testing.expect(std.mem.startsWith(u8, out, "<memory-index>\n"));
    try testing.expect(std.mem.endsWith(u8, out, "</memory-index>\n"));
    try testing.expect(std.mem.indexOf(u8, out, "user-prefs (42 bytes)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "project-notes (1024 bytes)") != null);
}

test "parseTags: inline list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\tags: [decision, security]
        \\---
        \\body
    ;
    const tags = try parseTags(arena_state.allocator(), body);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("decision", tags[0]);
    try testing.expectEqualStrings("security", tags[1]);
}

test "parseTags: bare comma list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\tags: alpha, beta
        \\---
        \\body
    ;
    const tags = try parseTags(arena_state.allocator(), body);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("alpha", tags[0]);
    try testing.expectEqualStrings("beta", tags[1]);
}

test "parseTags: missing frontmatter yields empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const tags = try parseTags(arena_state.allocator(), "no frontmatter here");
    try testing.expectEqual(@as(usize, 0), tags.len);
}

test "search: substring match returns topic + line + snippet" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "decisions",
        \\line one
        \\our retry policy is exponential backoff
        \\line three
    );
    try write(a, testing.io, &env, "other", "nothing relevant\n");

    const hits = try search(a, testing.io, &env, "retry policy", 50, null);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("decisions", hits[0].topic);
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "exponential backoff") != null);
}

test "search: case-insensitive when query is all-lowercase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "notes", "RETRY POLICY: backoff\n");
    const hits = try search(a, testing.io, &env, "retry policy", 50, null);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "search: tag filter narrows to matching frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "alpha",
        \\---
        \\tags: [decision]
        \\---
        \\retry policy lives here
    );
    try write(a, testing.io, &env, "beta",
        \\---
        \\tags: [scratch]
        \\---
        \\retry policy lives here too
    );
    const hits = try search(a, testing.io, &env, "retry", 50, "decision");
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("alpha", hits[0].topic);
}

test "search: empty query + tag enumerates topics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "alpha",
        \\---
        \\tags: [decision]
        \\---
        \\
    );
    try write(a, testing.io, &env, "beta",
        \\---
        \\tags: [decision, security]
        \\---
        \\
    );
    try write(a, testing.io, &env, "gamma", "no frontmatter\n");
    const hits = try search(a, testing.io, &env, "", 50, "decision");
    try testing.expectEqual(@as(usize, 2), hits.len);
}

test "list: populates tags from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "tagged",
        \\---
        \\tags: [foo, bar]
        \\---
        \\body
    );
    const entries = try list(a, testing.io, &env);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(usize, 2), entries[0].tags.len);
}

test "write: overwrites existing topic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", tmp_abs);

    try write(a, testing.io, &env, "ovr", "v1\n");
    try write(a, testing.io, &env, "ovr", "v2 (replaces v1)\n");
    const r = (try read(a, testing.io, &env, "ovr")).?;
    try testing.expectEqualStrings("v2 (replaces v1)\n", r);
}
