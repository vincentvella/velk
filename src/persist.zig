//! Session persistence: load/save the message history as JSON under
//! `$XDG_DATA_HOME/velk/sessions/<name>.json` (or
//! `$HOME/.local/share/velk/sessions/<name>.json`). Reuses
//! `provider.Message` directly — Zig's std.json round-trips the
//! tagged-union ContentBlock as `{"variant": value}` without help.

const std = @import("std");
const Io = std.Io;
const provider = @import("provider.zig");

pub const Stored = struct {
    version: u32 = 1,
    messages: []const provider.Message,
};

pub const Error = error{
    HomeDirUnknown,
    InvalidSessionName,
} || std.mem.Allocator.Error;

/// Compute the on-disk path for a named session. `name` must not
/// contain `/` or `..` so a malicious value can't escape the sessions
/// directory.
pub fn sessionPath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    name: []const u8,
) ![]const u8 {
    if (name.len == 0) return Error.InvalidSessionName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return Error.InvalidSessionName;
    if (std.mem.indexOf(u8, name, "..") != null) return Error.InvalidSessionName;

    const base = if (env_map.get("XDG_DATA_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/share", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/sessions/{s}.json", .{ base, name });
}

/// Path to the shared TUI input history file. Stored under
/// `$XDG_STATE_HOME/velk/history.txt` (or `~/.local/state/velk/...`).
pub fn historyPath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) ![]const u8 {
    const base = if (env_map.get("XDG_STATE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/state", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/history.txt", .{base});
}

/// Maximum number of entries kept on disk; older lines are dropped on
/// next save.
pub const max_history_entries: usize = 1000;

/// Load the history file. Returns oldest-first list (matches the
/// in-memory order the TUI expects). Missing file → empty slice.
pub fn loadHistory(
    arena: std.mem.Allocator,
    io: Io,
    abs_path: []const u8,
) ![]const []const u8 {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, abs_path, arena, .limited(1 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(arena, line);
    }
    return lines.items;
}

/// Append a single entry to the history file, atomically. Truncates
/// the file to the most recent `max_history_entries` lines after each
/// write so the file doesn't grow without bound.
pub fn appendHistory(
    arena: std.mem.Allocator,
    io: Io,
    abs_path: []const u8,
    entry: []const u8,
) !void {
    if (entry.len == 0) return;
    if (std.mem.indexOfScalar(u8, entry, '\n') != null) return; // skip multi-line for now

    const slash = std.mem.lastIndexOfScalar(u8, abs_path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, abs_path[0..slash]);

    // Read existing, append new, truncate to last N, write back.
    const cwd = Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, abs_path, arena, .limited(1 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };

    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, existing, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(arena, line);
    }
    try lines.append(arena, entry);

    const start: usize = if (lines.items.len > max_history_entries)
        lines.items.len - max_history_entries
    else
        0;

    var out: std.ArrayList(u8) = .empty;
    for (lines.items[start..]) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try cwd.writeFile(io, .{ .sub_path = abs_path, .data = out.items });
}

/// Load a previously-saved session. Returns null if the file doesn't
/// exist; propagates other I/O / parse errors.
pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    abs_path: []const u8,
) !?[]const provider.Message {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, abs_path, arena, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    const parsed = try std.json.parseFromSliceLeaky(Stored, arena, data, .{ .ignore_unknown_fields = true });
    return parsed.messages;
}

pub const SessionMeta = struct {
    /// Name without the `.json` suffix.
    name: []const u8,
    /// Absolute path to the session file.
    path: []const u8,
    /// Bytes on disk (rough proxy for size).
    size_bytes: u64,
};

/// Enumerate every saved session (directory listing of
/// `<XDG_DATA_HOME>/velk/sessions/*.json`). Names are returned in
/// reverse-alphabetical order so the most-recently created shows
/// first in typical naming schemes (`turn-2026-04-26-…`). Missing
/// directory yields an empty slice.
pub fn listSessions(
    arena: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
) ![]const SessionMeta {
    const base = if (env_map.get("XDG_DATA_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/share", .{home});
    };
    const dir_path = try std.fmt.allocPrint(arena, "{s}/velk/sessions", .{base});

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var out: std.ArrayList(SessionMeta) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const stem = name[0 .. name.len - ".json".len];
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, name });
        var size: u64 = 0;
        if (Io.Dir.cwd().statFile(io, path, .{})) |st| {
            size = st.size;
        } else |_| {}
        try out.append(arena, .{
            .name = try arena.dupe(u8, stem),
            .path = path,
            .size_bytes = size,
        });
    }

    // Reverse-alphabetical: caller treats the front of the list as
    // most-recent under timestamped names.
    std.mem.sort(SessionMeta, out.items, {}, struct {
        fn lessThan(_: void, a: SessionMeta, b: SessionMeta) bool {
            return std.mem.order(u8, a.name, b.name) == .gt;
        }
    }.lessThan);

    return out.items;
}

/// Save the current message list. Creates parent directories as needed.
pub fn save(
    arena: std.mem.Allocator,
    io: Io,
    abs_path: []const u8,
    messages: []const provider.Message,
) !void {
    // Ensure the parent directory exists.
    const slash = std.mem.lastIndexOfScalar(u8, abs_path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, abs_path[0..slash]);

    const stored: Stored = .{ .messages = messages };
    const json = try std.json.Stringify.valueAlloc(arena, stored, .{ .emit_null_optional_fields = false });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = json });
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

const testing = std.testing;

test "sessionPath: rejects path traversal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("HOME", "/home/test");

    try testing.expectError(Error.InvalidSessionName, sessionPath(arena.allocator(), &env, "../etc"));
    try testing.expectError(Error.InvalidSessionName, sessionPath(arena.allocator(), &env, "a/b"));
    try testing.expectError(Error.InvalidSessionName, sessionPath(arena.allocator(), &env, ""));
}

test "sessionPath: uses XDG_DATA_HOME when set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("XDG_DATA_HOME", "/tmp/xdg");

    const p = try sessionPath(arena.allocator(), &env, "work");
    try testing.expectEqualStrings("/tmp/xdg/velk/sessions/work.json", p);
}

test "sessionPath: falls back to HOME/.local/share" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("HOME", "/home/v");

    const p = try sessionPath(arena.allocator(), &env, "main");
    try testing.expectEqualStrings("/home/v/.local/share/velk/sessions/main.json", p);
}
