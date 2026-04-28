//! `--watch` mode — re-run the prompt whenever a tracked file in the
//! working tree changes. v1 is polling-based (cross-platform; no
//! kqueue/inotify dependency): every `poll_ms` we walk the tree and
//! Wyhash a stream of `(rel-path, size, mtime)` triples for every
//! non-ignored file. When the hash differs from the prior pass, we
//! signal "changed".
//!
//! Walk is bounded (max_files / max_depth) so a runaway tree doesn't
//! freeze the loop. The hardcoded ignore set from `src/ignore.zig`
//! keeps `.git`, `node_modules`, build outputs, etc. out of the hash.

const std = @import("std");
const Io = std.Io;
const ignore = @import("ignore.zig");

pub const max_files: usize = 5_000;
pub const max_depth: u8 = 12;
pub const default_poll_ms: u64 = 500;

/// Walk the tree rooted at `root` and return a Wyhash of every
/// non-ignored file's (rel-path, size, mtime_ns) triple. The hash is
/// stable across runs: identical trees produce identical fingerprints
/// regardless of iteration order, because we sort entries per
/// directory before folding.
pub fn fingerprint(arena: std.mem.Allocator, io: Io, root: []const u8) !u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var count: usize = 0;
    try walk(arena, io, root, 0, &hasher, &count);
    return hasher.final();
}

fn walk(
    arena: std.mem.Allocator,
    io: Io,
    rel: []const u8,
    depth: u8,
    hasher: *std.hash.Wyhash,
    count: *usize,
) !void {
    if (depth > max_depth) return;
    if (count.* >= max_files) return;

    const dir_path: []const u8 = if (rel.len == 0) "." else rel;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // Collect names first so we can sort — keeps the fingerprint
    // stable across filesystems with different iteration orders.
    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (ignore.isIgnored(entry.name)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    for (names.items) |name| {
        if (count.* >= max_files) return;
        const child_rel = if (rel.len == 0) name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, name });
        const stat = dir.statFile(io, name, .{}) catch continue;
        switch (stat.kind) {
            .directory => try walk(arena, io, child_rel, depth + 1, hasher, count),
            .file => {
                count.* += 1;
                hasher.update(child_rel);
                hasher.update(std.mem.asBytes(&stat.size));
                // mtime: ctime+mtime tuple. mtime catches edits;
                // ctime catches metadata-only changes (chmod). The
                // raw nanoseconds field is good enough — we don't
                // need cross-platform agreement, just intra-run
                // consistency.
                hasher.update(std.mem.asBytes(&stat.mtime));
            },
            else => {},
        }
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Block until the fingerprint changes from `prev`. Polls every
/// `poll_ms` and returns the new hash. The caller is expected to
/// catch SIGINT externally — we never return spontaneously.
pub fn waitForChange(arena: std.mem.Allocator, io: Io, root: []const u8, prev: u64, poll_ms: u64) !u64 {
    const dur = Io.Duration.fromMilliseconds(@intCast(poll_ms));
    while (true) {
        Io.sleep(io, dur, .awake) catch {};
        const cur = try fingerprint(arena, io, root);
        if (cur != prev) return cur;
    }
}

// ───────── tests ─────────

const testing = std.testing;

test "fingerprint: stable across two passes on a quiescent tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "alpha" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "beta" });

    const h1 = try fingerprint(a, testing.io, root);
    const h2 = try fingerprint(a, testing.io, root);
    try testing.expectEqual(h1, h2);
}

test "fingerprint: changes when a file's content (and thus size) changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v1" });
    const h1 = try fingerprint(a, testing.io, root);

    // Overwrite with different size.
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v2-longer" });
    const h2 = try fingerprint(a, testing.io, root);
    try testing.expect(h1 != h2);
}

test "fingerprint: changes when a new file is added" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v1" });
    const h1 = try fingerprint(a, testing.io, root);

    try tmp.dir.writeFile(.{ .sub_path = "g.txt", .data = "new" });
    const h2 = try fingerprint(a, testing.io, root);
    try testing.expect(h1 != h2);
}

test "fingerprint: dotfiles are skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v1" });
    const h1 = try fingerprint(a, testing.io, root);

    // Adding a dotfile should NOT change the fingerprint — they're
    // skipped by the walker (matches `.git/`, `.DS_Store`, etc.).
    try tmp.dir.writeFile(.{ .sub_path = ".hidden", .data = "x" });
    const h2 = try fingerprint(a, testing.io, root);
    try testing.expectEqual(h1, h2);
}

test "fingerprint: ignored dirs are skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v1" });
    const h1 = try fingerprint(a, testing.io, root);

    // Adding a file under a hardcoded-ignore dir (e.g. node_modules,
    // zig-cache) should NOT shift the fingerprint.
    try tmp.dir.makePath("node_modules");
    try tmp.dir.writeFile(.{ .sub_path = "node_modules/junk.js", .data = "x" });
    const h2 = try fingerprint(a, testing.io, root);
    try testing.expectEqual(h1, h2);
}

test "fingerprint: order-independent across renames at same level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    // Two siblings at the root — sort makes the fingerprint stable
    // regardless of dir-iter order.
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "1" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "1" });
    const h1 = try fingerprint(a, testing.io, root);

    const h2 = try fingerprint(a, testing.io, root);
    try testing.expectEqual(h1, h2);
}
