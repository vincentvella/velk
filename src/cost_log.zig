//! Per-turn cost log. Appends one JSON line to
//! `$XDG_STATE_HOME/velk/cost.jsonl` (or `~/.local/state/velk/...`)
//! every time a turn completes; `/cost` reads the file back and
//! aggregates by date for today / week / month / all-time totals.
//!
//! JSONL line shape:
//!   {"ts":1745672400,"model":"claude-opus-4-7","in":1234,"out":567,
//!    "cache_read":0,"cache_write":0,"cost_usd":0.0123}
//!
//! `ts` is unix-seconds. We store the timestamp as an integer (not
//! ISO-8601 string) so windowing math is trivial without a date
//! parser.

const std = @import("std");
const Io = std.Io;

pub const Entry = struct {
    ts: i64,
    model: []const u8,
    in: u64 = 0,
    out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost_usd: f64 = 0,
};

pub const Error = error{
    HomeDirUnknown,
} || std.mem.Allocator.Error;

pub fn logPath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) ![]const u8 {
    const base = if (env_map.get("XDG_STATE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/state", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/cost.jsonl", .{base});
}

/// Append a single turn record. Best-effort — IO failures are
/// swallowed by the caller; missing cost files create cleanly.
pub fn append(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    entry: Entry,
) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, path[0..slash]);

    const cwd = Io.Dir.cwd();
    // Read existing, append, write back. The log is small (a few
    // KB even after thousands of turns) so a full rewrite is fine.
    const existing = cwd.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try out.append(arena, '\n');
    }
    try out.print(arena,
        "{{\"ts\":{d},\"model\":\"{s}\",\"in\":{d},\"out\":{d},\"cache_read\":{d},\"cache_write\":{d},\"cost_usd\":{d:.6}}}\n",
        .{
            entry.ts,
            entry.model,
            entry.in,
            entry.out,
            entry.cache_read,
            entry.cache_write,
            entry.cost_usd,
        },
    );
    try cwd.writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Read every entry. Missing file → empty slice. Malformed lines
/// are skipped silently (logs from a future velk version with
/// extra fields still parse via `ignore_unknown_fields`).
pub fn readAll(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
) ![]const Entry {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    return try parse(arena, data);
}

fn parse(arena: std.mem.Allocator, data: []const u8) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(Entry, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        try out.append(arena, parsed);
    }
    return out.items;
}

pub const Window = enum { today, week, month, all };

pub const Totals = struct {
    in_tokens: u64 = 0,
    out_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    cost_usd: f64 = 0,
    turns: u64 = 0,
};

/// Sum entries within `window` ending at `now_ts`. Day boundaries
/// are 24h-rolling (not calendar midnight) — close enough for a
/// "today" totals line and avoids dragging in timezone math.
pub fn aggregate(entries: []const Entry, window: Window, now_ts: i64) Totals {
    const cutoff: i64 = switch (window) {
        .today => now_ts - 24 * 60 * 60,
        .week => now_ts - 7 * 24 * 60 * 60,
        .month => now_ts - 30 * 24 * 60 * 60,
        .all => std.math.minInt(i64),
    };
    var t: Totals = .{};
    for (entries) |e| {
        if (e.ts < cutoff) continue;
        t.in_tokens +|= e.in;
        t.out_tokens +|= e.out;
        t.cache_read_tokens +|= e.cache_read;
        t.cache_write_tokens +|= e.cache_write;
        t.cost_usd += e.cost_usd;
        t.turns += 1;
    }
    return t;
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

test "parse: empty input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), e.len);
}

test "parse: skips malformed lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const data =
        \\{"ts":100,"model":"x","in":10,"out":5,"cache_read":0,"cache_write":0,"cost_usd":0.001}
        \\not-json-at-all
        \\{"ts":200,"model":"y","in":20,"out":10,"cache_read":0,"cache_write":0,"cost_usd":0.002}
    ;
    const e = try parse(arena.allocator(), data);
    try testing.expectEqual(@as(usize, 2), e.len);
    try testing.expectEqualStrings("x", e[0].model);
    try testing.expectEqualStrings("y", e[1].model);
}

test "parse: tolerates forward-compat extra fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const data =
        \\{"ts":1,"model":"m","in":2,"out":3,"cache_read":0,"cache_write":0,"cost_usd":0.5,"future":"hi"}
    ;
    const e = try parse(arena.allocator(), data);
    try testing.expectEqual(@as(usize, 1), e.len);
}

test "aggregate: window cutoffs work" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const now: i64 = 1_000_000;
    const entries = &[_]Entry{
        .{ .ts = now - 60, .model = "a", .in = 100, .out = 50, .cost_usd = 0.01 }, // last minute
        .{ .ts = now - 2 * 24 * 60 * 60, .model = "a", .in = 200, .out = 100, .cost_usd = 0.02 }, // 2 days ago
        .{ .ts = now - 10 * 24 * 60 * 60, .model = "a", .in = 400, .out = 200, .cost_usd = 0.04 }, // 10 days ago
        .{ .ts = now - 60 * 24 * 60 * 60, .model = "a", .in = 800, .out = 400, .cost_usd = 0.08 }, // 60 days ago
    };
    const today = aggregate(entries, .today, now);
    try testing.expectEqual(@as(u64, 1), today.turns);
    const week = aggregate(entries, .week, now);
    try testing.expectEqual(@as(u64, 2), week.turns);
    const month = aggregate(entries, .month, now);
    try testing.expectEqual(@as(u64, 3), month.turns);
    const all = aggregate(entries, .all, now);
    try testing.expectEqual(@as(u64, 4), all.turns);
    try testing.expectApproxEqAbs(@as(f64, 0.15), all.cost_usd, 1e-9);
}

test "logPath: uses XDG_STATE_HOME when set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("XDG_STATE_HOME", "/tmp/xdg-state");
    const p = try logPath(arena.allocator(), &env);
    try testing.expectEqualStrings("/tmp/xdg-state/velk/cost.jsonl", p);
}
