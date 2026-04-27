//! Crash-recovery lockfile. Touched at startup, removed on clean
//! exit. On startup, if a stale lockfile is present (i.e. exists
//! from a previous run that didn't clean it up), we know the prior
//! session likely crashed — surface a nudge toward `/resume`.
//!
//! Lives at `$XDG_STATE_HOME/velk/lock` (or `$HOME/.local/state/...`).
//! Single-process: we don't try to support concurrent velk invocations
//! sharing the same state directory. The lockfile contains the pid +
//! ISO timestamp purely for human debugging — we don't kill stale
//! processes by pid.

const std = @import("std");
const Io = std.Io;

pub fn lockfilePath(arena: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    const base = if (env_map.get("XDG_STATE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/state", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/lock", .{base});
}

/// Returns true if a lockfile already existed (i.e. previous run
/// didn't remove it cleanly). Always tries to (re)create the file
/// after the check so subsequent /resume nudges don't fire on
/// every launch.
pub fn touchAndCheckStale(
    arena: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
) !bool {
    const path = try lockfilePath(arena, env_map);
    const dir = std.fs.path.dirname(path) orelse return error.HomeDirUnknown;
    mkdirAllAbsolute(io, dir) catch {};

    const cwd = Io.Dir.cwd();
    const existed = blk: {
        _ = cwd.statFile(io, path, .{}) catch break :blk false;
        break :blk true;
    };

    var pid_buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&pid_buf, "pid={d}\n", .{std.c.getpid()}) catch "pid=?\n";
    cwd.writeFile(io, .{ .sub_path = path, .data = body }) catch {};
    return existed;
}

/// Best-effort removal at clean shutdown. Failures are silent —
/// next launch's stale-detection just turns into a false positive
/// and the user sees a `/resume` nudge they can ignore.
pub fn release(io: Io, arena: std.mem.Allocator, env_map: *std.process.Environ.Map) void {
    const path = lockfilePath(arena, env_map) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
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

test "lockfilePath honors XDG_STATE_HOME" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("XDG_STATE_HOME", "/tmp/state");
    const p = try lockfilePath(arena_state.allocator(), &env);
    try testing.expectEqualStrings("/tmp/state/velk/lock", p);
}

test "lockfilePath falls back to HOME/.local/state" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("HOME", "/home/v");
    const p = try lockfilePath(arena_state.allocator(), &env);
    try testing.expectEqualStrings("/home/v/.local/state/velk/lock", p);
}

test "touchAndCheckStale: first run reports false, second reports true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_STATE_HOME", tmp_abs);

    const first = try touchAndCheckStale(a, testing.io, &env);
    try testing.expect(!first);
    const second = try touchAndCheckStale(a, testing.io, &env);
    try testing.expect(second);

    release(testing.io, a, &env);
    const after_release = try touchAndCheckStale(a, testing.io, &env);
    try testing.expect(!after_release);
}
