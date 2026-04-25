//! Desktop / webhook notification on turn completion. Fires only when
//! a turn took longer than a threshold (default 10s) so short replies
//! don't spam the user.
//!
//! Backends, in order:
//!   1. `VELK_NOTIFY_WEBHOOK` env → POST a JSON body to that URL
//!   2. macOS → spawn `osascript -e 'display notification ...'`
//!   3. Linux → spawn `notify-send`
//!
//! All errors are swallowed — a failed notification must never break
//! the agent loop. Set `VELK_NOTIFY=0` to disable entirely.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

pub const default_threshold_ms: u64 = 10_000;

/// Decide whether to fire and dispatch the right backend. `elapsed_ms`
/// is the wall-clock duration of the turn that just finished.
pub fn maybe(
    arena: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
    title: []const u8,
    body: []const u8,
    elapsed_ms: u64,
) void {
    if (env_map.get("VELK_NOTIFY")) |v| {
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) return;
    }
    const threshold = thresholdFromEnv(env_map);
    if (elapsed_ms < threshold) return;

    if (env_map.get("VELK_NOTIFY_WEBHOOK")) |url| {
        webhook(arena, io, url, title, body, elapsed_ms) catch {};
        return;
    }

    desktop(arena, io, title, body) catch {};
}

fn thresholdFromEnv(env_map: *std.process.Environ.Map) u64 {
    const raw = env_map.get("VELK_NOTIFY_AFTER_MS") orelse return default_threshold_ms;
    return std.fmt.parseInt(u64, raw, 10) catch default_threshold_ms;
}

fn desktop(arena: std.mem.Allocator, io: Io, title: []const u8, body: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try osascript(arena, io, title, body),
        .linux => try notifySend(arena, io, title, body),
        else => {},
    }
}

fn osascript(arena: std.mem.Allocator, io: Io, title: []const u8, body: []const u8) !void {
    // Hand-build the AppleScript so quotes/backslashes don't escape
    // the literal. Anything weird in title/body is converted to a
    // single space (notifications truncate hard anyway).
    const safe_title = try sanitize(arena, title);
    const safe_body = try sanitize(arena, body);
    const script = try std.fmt.allocPrint(
        arena,
        "display notification \"{s}\" with title \"{s}\"",
        .{ safe_body, safe_title },
    );
    try fireAndForget(io, &.{ "osascript", "-e", script });
}

fn notifySend(arena: std.mem.Allocator, io: Io, title: []const u8, body: []const u8) !void {
    _ = arena;
    try fireAndForget(io, &.{ "notify-send", title, body });
}

/// Spawn a short-lived helper, wait for it, ignore exit status. Used
/// for osascript / notify-send. We `wait` (rather than fully detach)
/// to avoid leaving a zombie.
fn fireAndForget(io: Io, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn webhook(
    arena: std.mem.Allocator,
    io: Io,
    url: []const u8,
    title: []const u8,
    body: []const u8,
    elapsed_ms: u64,
) !void {
    var http: std.http.Client = .{ .allocator = arena, .io = io };
    defer http.deinit();
    const Payload = struct {
        title: []const u8,
        body: []const u8,
        elapsed_ms: u64,
        source: []const u8 = "velk",
    };
    const json = try std.json.Stringify.valueAlloc(arena, Payload{
        .title = title,
        .body = body,
        .elapsed_ms = elapsed_ms,
    }, .{});
    _ = http.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = json,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
}

/// Strip quotes / backslashes / newlines from a notification field so
/// shelling out via osascript doesn't blow up. Also clamps to 200
/// chars — desktop notifications truncate aggressively anyway.
fn sanitize(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const max = 200;
    const len = @min(s.len, max);
    const buf = try arena.alloc(u8, len);
    for (s[0..len], 0..) |c, i| {
        buf[i] = switch (c) {
            '"', '\\', '\n', '\r' => ' ',
            else => c,
        };
    }
    return buf;
}

// ───────── tests ─────────

const testing = std.testing;

test "thresholdFromEnv: default when missing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try testing.expectEqual(default_threshold_ms, thresholdFromEnv(&env));
}

test "thresholdFromEnv: parses integer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_NOTIFY_AFTER_MS", "2500");
    try testing.expectEqual(@as(u64, 2500), thresholdFromEnv(&env));
}

test "thresholdFromEnv: bad value falls back to default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_NOTIFY_AFTER_MS", "lots");
    try testing.expectEqual(default_threshold_ms, thresholdFromEnv(&env));
}

test "sanitize: strips quotes + clamps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try sanitize(arena.allocator(), "hello \"world\"\nbye");
    try testing.expectEqualStrings("hello  world  bye", out);
}
