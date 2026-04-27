//! Repo map — a filtered directory listing prepended to the system
//! prompt so the model has the project shape on every turn without
//! the user copy-pasting it. V1 is structure-only (directory tree
//! + sizes); a symbol skeleton (first non-blank line of each file
//! or top-level decl extraction) is a v2 lift.
//!
//! Caching: the map is regenerated when `git status --porcelain`
//! output changes — i.e. whenever the user edits, stages, or
//! commits a file. The cache lives at
//! `$XDG_CACHE_HOME/velk/<base32-of-cwd>/repo-map.cache` so two
//! checkouts of the same repo (e.g. a worktree) don't clobber
//! each other.

const std = @import("std");
const Io = std.Io;
const ignore = @import("ignore.zig");
const git_commit = @import("git_commit.zig");

pub const max_entries: usize = 500;
pub const max_depth: u8 = 6;

pub const Error = error{
    HomeDirUnknown,
} || std.mem.Allocator.Error;

/// Walk CWD and produce a flat-but-indented listing string. Sizes
/// are shown for files; directories get a trailing `/`. Hits the
/// ignore filter from `src/ignore.zig` so node_modules etc. don't
/// pollute the output.
pub fn generate(arena: std.mem.Allocator, io: Io) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "Repo layout (filtered):\n");
    var entry_count: usize = 0;
    try walk(arena, io, "", 0, &out, &entry_count);
    if (entry_count >= max_entries) {
        try out.print(arena, "… (truncated at {d} entries)\n", .{max_entries});
    }
    return out.items;
}

fn walk(
    arena: std.mem.Allocator,
    io: Io,
    rel: []const u8,
    depth: u8,
    out: *std.ArrayList(u8),
    entry_count: *usize,
) !void {
    if (depth > max_depth) return;
    if (entry_count.* >= max_entries) return;

    const dir_path: []const u8 = if (rel.len == 0) "." else rel;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    var names: std.ArrayList(NamedEntry) = .empty;
    while (try iter.next(io)) |entry| {
        if (ignore.isIgnored(entry.name)) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') {
            // Skip dotfiles other than the few we explicitly want
            // (kept simple: just always skip — they rarely add
            // signal in a repo overview, and the ignore set already
            // catches `.git` etc).
            continue;
        }
        try names.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }
    std.mem.sort(NamedEntry, names.items, {}, NamedEntry.lessThan);

    for (names.items) |entry| {
        if (entry_count.* >= max_entries) return;
        const child_rel = if (rel.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        try indent(arena, out, depth);
        switch (entry.kind) {
            .directory => {
                try out.print(arena, "{s}/\n", .{entry.name});
                entry_count.* += 1;
                try walk(arena, io, child_rel, depth + 1, out, entry_count);
            },
            .file => {
                const stat = Io.Dir.cwd().statFile(io, child_rel, .{}) catch {
                    try out.print(arena, "{s}\n", .{entry.name});
                    entry_count.* += 1;
                    continue;
                };
                try out.print(arena, "{s} ({d}b)\n", .{ entry.name, stat.size });
                entry_count.* += 1;
            },
            else => {
                try out.print(arena, "{s}\n", .{entry.name});
                entry_count.* += 1;
            },
        }
    }
}

const NamedEntry = struct {
    name: []const u8,
    kind: Io.File.Kind,

    fn lessThan(_: void, a: NamedEntry, b: NamedEntry) bool {
        // Directories first, then alpha within each kind.
        const a_dir = a.kind == .directory;
        const b_dir = b.kind == .directory;
        if (a_dir and !b_dir) return true;
        if (!a_dir and b_dir) return false;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

fn indent(arena: std.mem.Allocator, out: *std.ArrayList(u8), depth: u8) !void {
    var i: u8 = 0;
    while (i < depth) : (i += 1) {
        try out.appendSlice(arena, "  ");
    }
}

/// Compute a stable cache key from `git status --porcelain` output.
/// When the output changes (any edit, stage, or commit), the map is
/// invalidated. Returns `.{ .key, .ok }` — `ok=false` when git is
/// missing / not a repo, in which case the caller should fall back
/// to "always regenerate" (no cache).
pub fn statusKey(io: Io, gpa: std.mem.Allocator) ?u64 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    return std.hash.Wyhash.hash(0, result.stdout);
}

/// Cache file path. `cwd_key` is a base16-encoded hash of the
/// absolute CWD so distinct checkouts of the same repo don't share
/// state.
pub fn cachePath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cwd_key: []const u8,
) ![]const u8 {
    const base = if (env_map.get("XDG_CACHE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.cache", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/repo-map/{s}.cache", .{ base, cwd_key });
}

/// Cache file format: 16 ASCII hex chars (the git-status hash) +
/// '\n' + the map body. Splitting by the first newline yields both.
fn parseCache(data: []const u8) ?struct { key: u64, body: []const u8 } {
    if (data.len < 17) return null;
    if (data[16] != '\n') return null;
    const k = std.fmt.parseInt(u64, data[0..16], 16) catch return null;
    return .{ .key = k, .body = data[17..] };
}

/// Generate or reuse the cached map for the current CWD. When git
/// is unavailable, regenerates every time (no caching). On any
/// cache write failure, falls through silently.
pub fn cachedOrGenerate(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cwd_key: []const u8,
) ![]const u8 {
    const key_opt = statusKey(io, gpa);
    if (key_opt == null) return generate(arena, io);

    const key = key_opt.?;
    const path = cachePath(arena, env_map, cwd_key) catch return generate(arena, io);

    // Try cache hit.
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 * 1024 * 1024))) |data| {
        if (parseCache(data)) |c| {
            if (c.key == key) return c.body;
        }
    } else |_| {}

    const body = try generate(arena, io);
    writeCache(io, arena, path, key, body) catch {};
    return body;
}

fn writeCache(
    io: Io,
    arena: std.mem.Allocator,
    path: []const u8,
    key: u64,
    body: []const u8,
) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, path[0..slash]);
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "{x:0>16}\n", .{key});
    try buf.appendSlice(arena, body);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
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

test "parseCache: round-trips key + body" {
    const sample = "deadbeefcafebabe\nhello world\n";
    const c = parseCache(sample) orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 0xdeadbeefcafebabe), c.key);
    try testing.expectEqualStrings("hello world\n", c.body);
}

test "parseCache: rejects too-short input" {
    try testing.expect(parseCache("short") == null);
}

test "parseCache: rejects missing newline at offset 16" {
    try testing.expect(parseCache("0123456789abcdefXbody") == null);
}
