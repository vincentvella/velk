//! Anonymous tool-use telemetry. **Off by default** — fires only
//! when both:
//!   1. `telemetry.opt_in: true` is set in the user's settings.json,
//!      or `VELK_TELEMETRY_OPT_IN=1` is in the environment.
//!   2. A `telemetry.url` is configured (or `VELK_TELEMETRY_URL`),
//!      pointing at the user's self-hosted ingest endpoint.
//!
//! No personally-identifying or content-bearing data is sent. The
//! payload is per-event:
//!   {"event":"tool_use","tool":"bash","ts":1745700000,"machine":"<sha256>"}
//! `machine` is a SHA-256 of the hostname so two runs from the same
//! machine fingerprint identically without exposing the hostname
//! itself. No prompts, no tool inputs, no file paths.
//!
//! Wire format: HTTP POST, JSON body, fire-and-forget. We don't
//! retry on failure — telemetry is best-effort by design. The whole
//! file is opt-in plumbing; the absence of a configured URL means
//! `record(...)` is a no-op without ever building a payload.

const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    /// User-confirmed opt-in. Both this AND `url != null` must be
    /// true for any network call to happen. Defaults false.
    opt_in: bool = false,
    /// Endpoint to POST events to. Null disables the whole subsystem.
    url: ?[]const u8 = null,
    /// SHA-256 of the hostname. Computed once at startup; constant
    /// for the session.
    machine_id: ?[]const u8 = null,
};

pub const Event = struct {
    /// `tool_use` | `turn_end` | `session_start` | `session_end`. Free-form
    /// to keep the wire format extensible without bumping a version.
    name: []const u8,
    /// Tool name for `tool_use` events; null otherwise.
    tool: ?[]const u8 = null,
    /// Provider model id for `turn_end`; null otherwise. Models are
    /// public identifiers — we don't redact them.
    model: ?[]const u8 = null,
    /// Unix-seconds timestamp.
    ts: i64,
};

/// Build a telemetry config from settings.json values + env-var
/// overrides. Env vars win — same precedence as the rest of velk's
/// "what to do at runtime" knobs.
pub fn fromSources(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    settings_opt_in: bool,
    settings_url: ?[]const u8,
) !Config {
    const opt_in_env = env_map.get("VELK_TELEMETRY_OPT_IN");
    const url_env = env_map.get("VELK_TELEMETRY_URL");
    var cfg: Config = .{
        .opt_in = if (opt_in_env) |v| envBool(v) else settings_opt_in,
        .url = if (url_env) |u| try arena.dupe(u8, u) else if (settings_url) |u| try arena.dupe(u8, u) else null,
    };
    cfg.machine_id = try machineFingerprint(arena, env_map);
    return cfg;
}

/// `1`/`true`/`yes`/`on` → true. Everything else → false. Mirrors
/// what most env-driven flags accept across velk.
pub fn envBool(s: []const u8) bool {
    if (s.len == 0) return false;
    return std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "true") or
        std.ascii.eqlIgnoreCase(s, "yes") or
        std.ascii.eqlIgnoreCase(s, "on");
}

/// Hostname → first 16 hex chars of its SHA-256. Stable across runs
/// on the same machine; different machines never collide. Falls
/// back to "unknown" when the hostname isn't readable so callers
/// always get a non-null id (the wire format includes it always).
pub fn machineFingerprint(arena: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    // `HOSTNAME` is set by most shells; `HOST` is a common fallback.
    // Failing those, hash a literal "unknown" — telemetry still fires,
    // grouping merges anonymous machines.
    const host: []const u8 = if (env_map.get("HOSTNAME")) |h|
        h
    else if (env_map.get("HOST")) |h|
        h
    else
        "unknown";
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update(host);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest[0..8], 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[(b >> 4) & 0xf];
        hex_buf[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return try arena.dupe(u8, &hex_buf);
}

/// Whether `record` will actually fire for this config. Useful in
/// `/doctor` and tests.
pub fn isActive(cfg: Config) bool {
    return cfg.opt_in and cfg.url != null;
}

/// Build the JSON body that would be POSTed for `event`. Pure —
/// callers can use this for testing without spawning HTTP.
pub fn buildPayload(arena: std.mem.Allocator, cfg: Config, event: Event) ![]const u8 {
    const Wire = struct {
        event: []const u8,
        ts: i64,
        machine: []const u8,
        tool: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };
    const w: Wire = .{
        .event = event.name,
        .ts = event.ts,
        .machine = cfg.machine_id orelse "unknown",
        .tool = event.tool,
        .model = event.model,
    };
    return try std.json.Stringify.valueAlloc(arena, w, .{ .emit_null_optional_fields = false });
}

/// Fire-and-forget POST. No retries. Returns success/failure to the
/// caller for logging but the agent never blocks on it. When the
/// config is inactive (opt-in off or URL null) this is a cheap
/// early-return; no payload is built.
pub fn record(
    gpa: std.mem.Allocator,
    io: Io,
    cfg: Config,
    event: Event,
) !void {
    if (!isActive(cfg)) return;
    const url = cfg.url.?;
    const payload = try buildPayload(gpa, cfg, event);
    defer gpa.free(payload);

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var resp_buf: Io.Writer.Allocating = .init(gpa);
    defer resp_buf.deinit();

    _ = http.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &resp_buf.writer,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = "velk-telemetry/1" },
        },
    }) catch |e| return e;
}

// ───────── tests ─────────

const testing = std.testing;

test "envBool: accepts 1/true/yes/on" {
    try testing.expect(envBool("1"));
    try testing.expect(envBool("true"));
    try testing.expect(envBool("TRUE"));
    try testing.expect(envBool("yes"));
    try testing.expect(envBool("on"));
    try testing.expect(!envBool("0"));
    try testing.expect(!envBool("false"));
    try testing.expect(!envBool(""));
}

test "machineFingerprint: stable across runs with same HOSTNAME" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("HOSTNAME", "macbook-vince");
    const a = try machineFingerprint(arena.allocator(), &env);
    const b = try machineFingerprint(arena.allocator(), &env);
    try testing.expectEqualStrings(a, b);
    try testing.expectEqual(@as(usize, 16), a.len);
}

test "machineFingerprint: differs across hostnames" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env_a: std.process.Environ.Map = .init(arena.allocator());
    var env_b: std.process.Environ.Map = .init(arena.allocator());
    try env_a.put("HOSTNAME", "host-a");
    try env_b.put("HOSTNAME", "host-b");
    const a = try machineFingerprint(arena.allocator(), &env_a);
    const b = try machineFingerprint(arena.allocator(), &env_b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "machineFingerprint: falls back to 'unknown' when env is empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    const id = try machineFingerprint(arena.allocator(), &env);
    try testing.expectEqual(@as(usize, 16), id.len);
}

test "fromSources: env vars override settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("VELK_TELEMETRY_OPT_IN", "true");
    try env.put("VELK_TELEMETRY_URL", "https://env.example.com/ingest");
    const cfg = try fromSources(arena.allocator(), &env, false, "https://settings.example.com/ingest");
    try testing.expect(cfg.opt_in);
    try testing.expectEqualStrings("https://env.example.com/ingest", cfg.url.?);
}

test "fromSources: settings used when env is empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    const cfg = try fromSources(arena.allocator(), &env, true, "https://settings.example.com/ingest");
    try testing.expect(cfg.opt_in);
    try testing.expectEqualStrings("https://settings.example.com/ingest", cfg.url.?);
}

test "fromSources: defaults to off when nothing is set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    const cfg = try fromSources(arena.allocator(), &env, false, null);
    try testing.expect(!cfg.opt_in);
    try testing.expect(cfg.url == null);
    try testing.expect(!isActive(cfg));
}

test "isActive: requires both opt_in AND url" {
    try testing.expect(!isActive(.{ .opt_in = false, .url = null }));
    try testing.expect(!isActive(.{ .opt_in = true, .url = null }));
    try testing.expect(!isActive(.{ .opt_in = false, .url = "https://x" }));
    try testing.expect(isActive(.{ .opt_in = true, .url = "https://x" }));
}

test "buildPayload: includes machine + event + ts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cfg: Config = .{ .opt_in = true, .url = "https://x", .machine_id = "deadbeefcafebabe" };
    const body = try buildPayload(arena.allocator(), cfg, .{
        .name = "tool_use",
        .tool = "bash",
        .ts = 1745700000,
    });
    try testing.expect(std.mem.indexOf(u8, body, "\"event\":\"tool_use\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"machine\":\"deadbeefcafebabe\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool\":\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"ts\":1745700000") != null);
}

test "buildPayload: omits null fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cfg: Config = .{ .opt_in = true, .url = "https://x", .machine_id = "abc" };
    const body = try buildPayload(arena.allocator(), cfg, .{
        .name = "session_start",
        .ts = 0,
    });
    // Neither `tool` nor `model` should appear when unset.
    try testing.expect(std.mem.indexOf(u8, body, "tool") == null);
    try testing.expect(std.mem.indexOf(u8, body, "model") == null);
}

test "record: no-op when inactive" {
    // Should not even attempt a network call. No way to assert
    // "didn't fire" directly, but at least confirm it returns
    // success without an HTTP error.
    const cfg: Config = .{ .opt_in = false, .url = null };
    try record(testing.allocator, testing.io, cfg, .{ .name = "tool_use", .ts = 0 });
}
