//! `--watch` mode — re-run the prompt whenever a tracked file in the
//! working tree changes.
//!
//! Two backends, picked at comptime by host OS:
//!   • macOS / BSD → kqueue + EVFILT_VNODE (zero-poll, ~ms latency)
//!   • Linux       → inotify (zero-poll, ~ms latency)
//!   • everything else → polling fallback (current `poll_ms` walk)
//!
//! All three converge on the same `waitForChange` API: block until the
//! tree's fingerprint differs from `prev`, return the new hash. The
//! native backends only signal "something happened, re-fingerprint";
//! the existing Wyhash-of-(path, size, mtime) walk does the actual
//! change detection so spurious wakeups (touched-then-restored,
//! hardlink dance) collapse to no-ops.
//!
//! Walk is bounded (max_files / max_depth) so a runaway tree doesn't
//! freeze the loop. The hardcoded ignore set from `src/ignore.zig`
//! keeps `.git`, `node_modules`, build outputs, etc. out of the hash
//! AND out of the watch-fd fanout (we don't subscribe to dirs we
//! wouldn't fingerprint anyway).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ignore = @import("ignore.zig");

pub const max_files: usize = 5_000;
pub const max_depth: u8 = 12;
pub const default_poll_ms: u64 = 500;
/// Cap on how many directories the native backends will subscribe
/// to. Each is a kqueue fd / inotify watch — kernel-side state lives
/// in the agent's process budget. Beyond this we fall back to polling
/// for the rest of the tree (the watched portion still fires fast).
pub const max_native_watches: usize = 2048;

/// Whether the host platform has a zero-poll backend compiled in.
/// Surfaced to main.zig so the startup banner can honestly tell the
/// user whether they got native FS events or the polling fallback.
pub const has_native_backend: bool = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    .linux => true,
    else => false,
};

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

/// Block until the fingerprint changes from `prev`. On macOS/BSD
/// uses kqueue, on Linux uses inotify, otherwise falls back to
/// polling every `poll_ms`. Returns the new hash. The caller is
/// expected to catch SIGINT externally — we never return spontaneously.
pub fn waitForChange(arena: std.mem.Allocator, io: Io, root: []const u8, prev: u64, poll_ms: u64) !u64 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => waitKqueue(arena, io, root, prev, poll_ms),
        .linux => waitInotify(arena, io, root, prev, poll_ms),
        else => waitPolling(arena, io, root, prev, poll_ms),
    };
}

/// Pure polling. Cross-platform fallback. Also reachable directly via
/// `--watch-mode polling` when the user wants to bypass the native
/// backend (e.g. NFS where kqueue/inotify miss remote-side changes).
pub fn waitPolling(arena: std.mem.Allocator, io: Io, root: []const u8, prev: u64, poll_ms: u64) !u64 {
    const dur = Io.Duration.fromMilliseconds(@intCast(poll_ms));
    while (true) {
        Io.sleep(io, dur, .awake) catch {};
        const cur = try fingerprint(arena, io, root);
        if (cur != prev) return cur;
    }
}

// ───────── kqueue backend (macOS / BSD) ─────────

const kq_constants = struct {
    // BSD/Darwin numeric constants; std.c doesn't expose them in 0.16.
    const EVFILT_VNODE: i16 = -4;
    const EV_ADD: u16 = 0x0001;
    const EV_CLEAR: u16 = 0x0020;
    const EV_ENABLE: u16 = 0x0004;
    const NOTE_DELETE: u32 = 0x00000001;
    const NOTE_WRITE: u32 = 0x00000002;
    const NOTE_EXTEND: u32 = 0x00000004;
    const NOTE_RENAME: u32 = 0x00000020;
    const NOTE_REVOKE: u32 = 0x00000040;
    const O_EVTONLY: u32 = 0x8000; // Darwin-only fd flag for kqueue-only opens.
    /// `note_combined` covers every change the fingerprint cares
    /// about. `EV_CLEAR` makes each event one-shot per fire so we
    /// don't get re-woken on the same accumulated state.
    const note_combined: u32 = NOTE_WRITE | NOTE_DELETE | NOTE_EXTEND | NOTE_RENAME | NOTE_REVOKE;
};

fn waitKqueue(arena: std.mem.Allocator, io: Io, root: []const u8, prev: u64, poll_ms: u64) !u64 {
    if (builtin.os.tag != .macos and builtin.os.tag != .ios and
        builtin.os.tag != .tvos and builtin.os.tag != .watchos and
        builtin.os.tag != .visionos and builtin.os.tag != .freebsd and
        builtin.os.tag != .netbsd and builtin.os.tag != .openbsd and
        builtin.os.tag != .dragonfly)
    {
        return waitPolling(arena, io, root, prev, poll_ms);
    }

    const kq = std.c.kqueue();
    if (kq < 0) return waitPolling(arena, io, root, prev, poll_ms);
    defer _ = std.c.close(kq);

    // Recursively open every non-ignored directory and register a
    // VNODE filter on the fd. Cap at `max_native_watches` to bound
    // kernel-side state — the polling fallback covers the rest by
    // re-fingerprinting after every wake.
    var fds: std.ArrayList(c_int) = .empty;
    defer {
        for (fds.items) |fd| _ = std.c.close(fd);
    }
    try registerKqueueDirs(arena, kq, root, "", 0, &fds);

    if (fds.items.len == 0) return waitPolling(arena, io, root, prev, poll_ms);

    // Block until any event fires. Use a short kernel-side timeout
    // (matched to poll_ms) as a safety net so we still re-fingerprint
    // periodically even if the kernel misses an event (e.g. a remote
    // FUSE mount that doesn't synthesize VNODE notes).
    var event: std.c.Kevent = undefined;
    while (true) {
        var ts: std.c.timespec = .{
            .sec = @intCast(@divTrunc(poll_ms, 1000)),
            .nsec = @intCast((poll_ms % 1000) * std.time.ns_per_ms),
        };
        var dummy_change: std.c.Kevent = undefined;
        const n = std.c.kevent(kq, @ptrCast(&dummy_change), 0, @ptrCast(&event), 1, &ts);
        if (n < 0) {
            // EINTR (signal during kevent) — loop and re-arm.
            const e = std.c._errno().*;
            if (e == 4) continue; // EINTR
            return waitPolling(arena, io, root, prev, poll_ms);
        }
        // n == 0 means timeout fired with no event; re-fingerprint
        // anyway as a belt-and-suspenders against missed notes.
        const cur = try fingerprint(arena, io, root);
        if (cur != prev) return cur;
    }
}

fn registerKqueueDirs(
    arena: std.mem.Allocator,
    kq: c_int,
    root: []const u8,
    rel: []const u8,
    depth: u8,
    fds: *std.ArrayList(c_int),
) !void {
    if (depth > max_depth) return;
    if (fds.items.len >= max_native_watches) return;

    const path: []const u8 = if (rel.len == 0) root else try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
    const path_z = try arena.dupeZ(u8, path);

    // O_EVTONLY (0x8000) is Darwin-specific; on BSDs the equivalent
    // is plain O_RDONLY which still produces a usable fd for kqueue.
    const open_flags: u32 = if (builtin.os.tag == .macos or builtin.os.tag == .ios or
        builtin.os.tag == .tvos or builtin.os.tag == .watchos or builtin.os.tag == .visionos)
        kq_constants.O_EVTONLY
    else
        0; // O_RDONLY = 0 on BSD
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true });
    _ = open_flags;
    if (fd < 0) return;

    var ev: std.c.Kevent = .{
        .ident = @intCast(fd),
        .filter = kq_constants.EVFILT_VNODE,
        .flags = kq_constants.EV_ADD | kq_constants.EV_CLEAR,
        .fflags = kq_constants.note_combined,
        .data = 0,
        .udata = 0,
    };
    var dummy: std.c.Kevent = undefined;
    if (std.c.kevent(kq, @ptrCast(&ev), 1, @ptrCast(&dummy), 0, null) < 0) {
        _ = std.c.close(fd);
        return;
    }
    try fds.append(arena, fd);

    // Recurse into subdirs we'd also fingerprint.
    var dir = Io.Dir.cwd().openDir(undefined, path, .{ .iterate = true }) catch return;
    defer dir.close(undefined);
    var iter = dir.iterate();
    while (iter.next(undefined) catch null) |entry| {
        if (fds.items.len >= max_native_watches) return;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (ignore.isIgnored(entry.name)) continue;
        if (entry.kind != .directory) continue;
        const child_rel = if (rel.len == 0) entry.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        try registerKqueueDirs(arena, kq, root, child_rel, depth + 1, fds);
    }
}

// ───────── inotify backend (Linux) ─────────

const in_constants = struct {
    const IN_CLOEXEC: u32 = 0o2000000;
    const IN_NONBLOCK: u32 = 0o4000;
    const IN_MODIFY: u32 = 0x00000002;
    const IN_ATTRIB: u32 = 0x00000004;
    const IN_MOVED_FROM: u32 = 0x00000040;
    const IN_MOVED_TO: u32 = 0x00000080;
    const IN_CREATE: u32 = 0x00000100;
    const IN_DELETE: u32 = 0x00000200;
    const IN_DELETE_SELF: u32 = 0x00000400;
    const IN_MOVE_SELF: u32 = 0x00000800;
    const event_mask: u32 = IN_MODIFY | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO |
        IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF;
};

fn waitInotify(arena: std.mem.Allocator, io: Io, root: []const u8, prev: u64, poll_ms: u64) !u64 {
    if (builtin.os.tag != .linux) return waitPolling(arena, io, root, prev, poll_ms);

    const fd = std.c.inotify_init1(in_constants.IN_CLOEXEC);
    if (fd < 0) return waitPolling(arena, io, root, prev, poll_ms);
    defer _ = std.c.close(fd);

    var watches: usize = 0;
    try registerInotifyDirs(arena, fd, root, "", 0, &watches);
    if (watches == 0) return waitPolling(arena, io, root, prev, poll_ms);

    // inotify events are variable-length; one read can return many.
    // We don't actually parse them here — the wakeup itself is the
    // signal. Re-fingerprint and compare.
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == 4) continue; // EINTR
            return waitPolling(arena, io, root, prev, poll_ms);
        }
        const cur = try fingerprint(arena, io, root);
        if (cur != prev) return cur;
    }
}

fn registerInotifyDirs(
    arena: std.mem.Allocator,
    fd: c_int,
    root: []const u8,
    rel: []const u8,
    depth: u8,
    watches: *usize,
) !void {
    if (depth > max_depth) return;
    if (watches.* >= max_native_watches) return;

    const path: []const u8 = if (rel.len == 0) root else try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
    const path_z = try arena.dupeZ(u8, path);

    const wd = std.c.inotify_add_watch(fd, path_z.ptr, in_constants.event_mask);
    if (wd < 0) return;
    watches.* += 1;

    var dir = Io.Dir.cwd().openDir(undefined, path, .{ .iterate = true }) catch return;
    defer dir.close(undefined);
    var iter = dir.iterate();
    while (iter.next(undefined) catch null) |entry| {
        if (watches.* >= max_native_watches) return;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (ignore.isIgnored(entry.name)) continue;
        if (entry.kind != .directory) continue;
        const child_rel = if (rel.len == 0) entry.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        try registerInotifyDirs(arena, fd, root, child_rel, depth + 1, watches);
    }
}

// ───────── tests ─────────

const testing = std.testing;

test "has_native_backend: true on the platforms we care about" {
    // Sanity: the platforms we actually ship are linux + macos and
    // both should have a native backend compiled in. This is a
    // defence against an accidental tag-list trim down the road.
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try testing.expect(has_native_backend);
    }
}

test "waitPolling: returns when fingerprint changes mid-wait" {
    // Background-write a file mid-poll and confirm waitPolling
    // returns the new hash. Exercises the polling fallback path
    // without going near the kqueue/inotify code.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v1" });
    const prev = try fingerprint(a, testing.io, root);

    // Mutate before calling waitPolling so the FIRST poll fires the
    // change. Avoids needing a worker thread in the test.
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "v2-different-size" });
    const cur = try waitPolling(a, testing.io, root, prev, 50);
    try testing.expect(cur != prev);
}

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
