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
};

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
        try out.append(arena, .{
            .topic = try arena.dupe(u8, slug),
            .bytes = stat.size,
        });
    }
    return out.items;
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
