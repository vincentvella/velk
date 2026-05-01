//! Remote managed settings. **Off by default** — fires only when
//! `VELK_MANAGED_SETTINGS_URL` is set in the environment (or the
//! `managed_settings.url` field in user/project settings.json).
//!
//! Behaviour: fetch the URL, parse as a normal velk settings JSON
//! body, cache the response on disk, and merge the parsed object
//! at the **lowest** priority — below user, below project. So org
//! policy provides defaults a user can override locally, not a hard
//! lock-down (that's still a v2 lift, when we have a real
//! "policy.lock" tier in the merge order).
//!
//! Cache lives at `$XDG_CACHE_HOME/velk/managed-settings.json`.
//! Stale cache is preferred over network failure: if the GET fails
//! AND we have a cached body, we use it. This way a flaky managed-
//! settings host doesn't break user sessions.
//!
//! The fetch is gated by `VELK_MANAGED_SETTINGS_REFRESH_SECS`
//! (default 3600 = 1h). Within the refresh window we go straight to
//! cache without hitting the network.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    HomeDirUnknown,
    InvalidUrl,
} || std.mem.Allocator.Error;

/// Resolve the URL from env first, then the (already-parsed)
/// settings field. Env wins so an org admin can pin the URL via
/// MDM regardless of what a user has in `~/.config/velk`.
pub fn resolveUrl(env_map: *std.process.Environ.Map, settings_url: ?[]const u8) ?[]const u8 {
    if (env_map.get("VELK_MANAGED_SETTINGS_URL")) |u| return u;
    return settings_url;
}

/// On-disk path for the cached managed-settings body.
pub fn cachePath(arena: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    const base = if (env_map.get("XDG_CACHE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.cache", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/managed-settings.json", .{base});
}

/// Refresh window in seconds. Override via
/// `VELK_MANAGED_SETTINGS_REFRESH_SECS`; clamped to [60, 86400].
/// 3600 (1h) is the default — fresh enough that a policy update
/// rolls out within an hour, slow enough that a busy team doesn't
/// hammer the ingest endpoint.
pub fn refreshSeconds(env_map: *std.process.Environ.Map) u64 {
    const raw = env_map.get("VELK_MANAGED_SETTINGS_REFRESH_SECS") orelse return 3600;
    const parsed = std.fmt.parseInt(u64, raw, 10) catch return 3600;
    if (parsed < 60) return 60;
    if (parsed > 86_400) return 86_400;
    return parsed;
}

/// Whether the cache at `path` is still fresh (mtime within the
/// refresh window). Missing cache → not fresh.
pub fn isCacheFresh(io: Io, path: []const u8, refresh_secs: u64) bool {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch return false;
    const mtime_secs: i64 = stat.mtime.toSeconds();
    const now: i64 = Io.Clock.now(.real, io).toSeconds();
    if (now < mtime_secs) return true; // clock skew safety
    const age: u64 = @intCast(now - mtime_secs);
    return age < refresh_secs;
}

pub const FetchResult = struct {
    /// Raw JSON body (settings shape). Caller `parse`s it and merges.
    body: []const u8,
    /// True when we used a network call; false when the cache was
    /// fresh enough that we skipped HTTP. Useful in `/doctor`.
    from_network: bool,
};

/// One-shot fetch with cache. Result body is owned by `arena`.
/// On network failure the cached body wins. On no-cache+failure we
/// return null — callers treat that as "no managed config, run with
/// what you've got".
pub fn fetchOrCache(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
    url: []const u8,
) !?FetchResult {
    const path = try cachePath(arena, env_map);
    const refresh = refreshSeconds(env_map);

    // Cache hit within the freshness window: skip the network.
    if (isCacheFresh(io, path, refresh)) {
        const cached = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch null;
        if (cached) |body| return .{ .body = body, .from_network = false };
    }

    // Try the network.
    const fresh = doFetch(arena, gpa, io, url) catch null;
    if (fresh) |body| {
        // Persist for next launch, ignoring write failures.
        writeCache(io, arena, path, body) catch {};
        return .{ .body = body, .from_network = true };
    }

    // Network failed — fall back to whatever we have on disk, even
    // if it's past the refresh window. Better stale policy than no
    // policy.
    const cached = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return null;
    return .{ .body = cached, .from_network = false };
}

fn doFetch(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
) ![]const u8 {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var resp_buf: Io.Writer.Allocating = .init(gpa);
    defer resp_buf.deinit();

    const result = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &resp_buf.writer,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "velk-managed-settings/1" },
            .{ .name = "accept", .value = "application/json" },
        },
    });

    if (@intFromEnum(result.status) >= 400) return Error.InvalidUrl;
    const buffered = resp_buf.writer.buffered();
    return try arena.dupe(u8, buffered);
}

fn writeCache(io: Io, arena: std.mem.Allocator, path: []const u8, body: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, path[0..slash]);
    _ = arena;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
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

test "resolveUrl: env beats settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_MANAGED_SETTINGS_URL", "https://env.example.com/policy.json");
    const url = resolveUrl(&env, "https://settings.example.com/policy.json");
    try testing.expectEqualStrings("https://env.example.com/policy.json", url.?);
}

test "resolveUrl: settings used when env empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    const url = resolveUrl(&env, "https://settings.example.com/policy.json");
    try testing.expectEqualStrings("https://settings.example.com/policy.json", url.?);
}

test "resolveUrl: null when nothing set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try testing.expect(resolveUrl(&env, null) == null);
}

test "cachePath: honors XDG_CACHE_HOME" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("XDG_CACHE_HOME", "/tmp/cache");
    const p = try cachePath(arena.allocator(), &env);
    try testing.expectEqualStrings("/tmp/cache/velk/managed-settings.json", p);
}

test "cachePath: falls back to HOME/.cache" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("HOME", "/home/v");
    const p = try cachePath(arena.allocator(), &env);
    try testing.expectEqualStrings("/home/v/.cache/velk/managed-settings.json", p);
}

test "refreshSeconds: defaults to 3600" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try testing.expectEqual(@as(u64, 3600), refreshSeconds(&env));
}

test "refreshSeconds: honors override" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_MANAGED_SETTINGS_REFRESH_SECS", "300");
    try testing.expectEqual(@as(u64, 300), refreshSeconds(&env));
}

test "refreshSeconds: clamps tiny values to 60s" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_MANAGED_SETTINGS_REFRESH_SECS", "1");
    try testing.expectEqual(@as(u64, 60), refreshSeconds(&env));
}

test "refreshSeconds: clamps absurd values to 1d" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_MANAGED_SETTINGS_REFRESH_SECS", "999999999");
    try testing.expectEqual(@as(u64, 86_400), refreshSeconds(&env));
}

test "refreshSeconds: garbage falls back to default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_MANAGED_SETTINGS_REFRESH_SECS", "notanumber");
    try testing.expectEqual(@as(u64, 3600), refreshSeconds(&env));
}

test "isCacheFresh: missing cache is not fresh" {
    try testing.expect(!isCacheFresh(testing.io, "/tmp/this-does-not-exist-velk-test.json", 3600));
}

test "isCacheFresh: just-written cache is fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const path = try std.fmt.allocPrint(a, "{s}/cache.json", .{tmp_abs});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "{}" });
    try testing.expect(isCacheFresh(testing.io, path, 3600));
}
