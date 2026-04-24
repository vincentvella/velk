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
