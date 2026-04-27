//! Persistent settings — the merged result of (in precedence order):
//!
//!   1. CLI flags                   (highest — applied later in main.zig)
//!   2. Project file `.velk/settings.json`
//!   3. User file   `$XDG_CONFIG_HOME/velk/settings.json` (or `~/.config/...`)
//!   4. Defaults baked in here.
//!
//! Sections shipped now: `defaults` (provider, model, system,
//! max_tokens) and `mcp_servers` (list of command lines that --mcp
//! would otherwise repeat). Stubs for `permissions`, `hooks`, `skills`
//! land in subsequent Phase-10 commits — kept as opaque JSON values
//! today so an early settings.json with future fields parses cleanly.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const hooks = @import("hooks.zig");

pub const default_filename: []const u8 = "settings.json";
pub const project_dir_name: []const u8 = ".velk";

pub const Defaults = struct {
    provider: ?cli.Provider = null,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    max_tokens: ?u32 = null,
};

pub const Settings = struct {
    defaults: Defaults = .{},
    /// Each entry is a shell command (matches `--mcp`). Loaded
    /// alongside any `--mcp` flags the user passed.
    mcp_servers: []const []const u8 = &.{},
    /// Permissions mode loaded from `permissions.mode`. `null`
    /// means "not set; main.zig will fall back to default".
    mode: ?[]const u8 = null,
    /// Reserved for future permissions engine fields (allow/deny
    /// rule lists, bash AST patterns). Stored as opaque JSON.
    permissions: ?std.json.Value = null,
    hooks: ?std.json.Value = null,
    skills: ?std.json.Value = null,
    /// Compiled hook engine. Built lazily by `compileHooks` once
    /// settings have been merged so project-level hooks override the
    /// user-level set wholesale (no concatenation — last one wins).
    hook_engine: hooks.Engine = .{},

    /// `Defaults` section overlay: every non-null field of `b`
    /// replaces the matching field on `self`.
    fn applyDefaults(self: *Settings, b: Defaults) void {
        if (b.provider) |p| self.defaults.provider = p;
        if (b.model) |m| self.defaults.model = m;
        if (b.system) |s| self.defaults.system = s;
        if (b.max_tokens) |t| self.defaults.max_tokens = t;
    }

    /// Merge `b` into `self`. `b` wins for every field it specifies;
    /// `self` keeps its existing values otherwise. `mcp_servers` is
    /// concatenated: project + user lists are both honoured.
    pub fn merge(self: *Settings, arena: std.mem.Allocator, b: Settings) !void {
        self.applyDefaults(b.defaults);
        if (b.mcp_servers.len > 0) {
            const merged = try arena.alloc([]const u8, self.mcp_servers.len + b.mcp_servers.len);
            @memcpy(merged[0..self.mcp_servers.len], self.mcp_servers);
            @memcpy(merged[self.mcp_servers.len..], b.mcp_servers);
            self.mcp_servers = merged;
        }
        if (b.mode) |m| self.mode = m;
        if (b.permissions) |v| self.permissions = v;
        if (b.hooks) |v| self.hooks = v;
        if (b.skills) |v| self.skills = v;
    }

    /// Compile the merged `hooks` JSON into a typed engine. Safe to
    /// call multiple times; later calls just overwrite. No-op when
    /// `hooks` is null.
    pub fn compileHooks(self: *Settings, arena: std.mem.Allocator) !void {
        if (self.hooks) |v| {
            self.hook_engine = try hooks.Engine.parse(arena, v);
        }
    }
};

pub const Error = error{
    HomeDirUnknown,
    InvalidSettingsJson,
} || std.mem.Allocator.Error;

/// Path to the per-user settings file. Uses `$XDG_CONFIG_HOME` if
/// set, falls back to `$HOME/.config`.
pub fn userPath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) ![]const u8 {
    const base = if (env_map.get("XDG_CONFIG_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.config", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/{s}", .{ base, default_filename });
}

/// Path to the per-project settings file (relative to the CWD that
/// velk was launched from). Always `<cwd>/.velk/settings.json`.
pub fn projectPath(arena: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir_name, default_filename });
}

/// Load+parse `path` if it exists; return null when missing. Errors
/// only on parse failure or other IO. The returned Settings borrows
/// strings from the arena.
pub fn loadFile(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !?Settings {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, arena, .limited(1 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return try parse(arena, data);
}

/// Convenience: load both user and project files (if present) and
/// merge user → project so project wins.
pub fn loadAndMerge(
    arena: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
) !Settings {
    var out: Settings = .{};
    if (userPath(arena, env_map)) |up| {
        if (try loadFile(arena, io, up)) |u| try out.merge(arena, u);
    } else |_| {}
    const pp = try projectPath(arena);
    if (try loadFile(arena, io, pp)) |p| try out.merge(arena, p);
    try out.compileHooks(arena);
    return out;
}

const Wire = struct {
    /// Mirrors `Defaults` but with `provider` as a string so the
    /// JSON file stays human-friendly (`"provider": "anthropic"`).
    defaults: ?WireDefaults = null,
    mcp_servers: ?[][]const u8 = null,
    permissions: ?WirePermissions = null,
    hooks: ?std.json.Value = null,
    skills: ?std.json.Value = null,
};

const WirePermissions = struct {
    mode: ?[]const u8 = null,
    /// Anything else (rule lists, bash patterns) lives here as an
    /// opaque blob so a forward-compatible file parses now and we
    /// can wire the fields up in v2.
    rest: ?std.json.Value = null,
};

const WireDefaults = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    max_tokens: ?u32 = null,
};

fn parse(arena: std.mem.Allocator, data: []const u8) !Settings {
    const wire = std.json.parseFromSliceLeaky(Wire, arena, data, .{ .ignore_unknown_fields = true }) catch
        return Error.InvalidSettingsJson;

    var out: Settings = .{};
    if (wire.defaults) |d| {
        if (d.provider) |p| {
            if (std.mem.eql(u8, p, "anthropic")) out.defaults.provider = .anthropic
            else if (std.mem.eql(u8, p, "openai")) out.defaults.provider = .openai
            else if (std.mem.eql(u8, p, "openrouter")) out.defaults.provider = .openrouter
            else return Error.InvalidSettingsJson;
        }
        out.defaults.model = d.model;
        out.defaults.system = d.system;
        out.defaults.max_tokens = d.max_tokens;
    }
    if (wire.mcp_servers) |m| out.mcp_servers = m;
    if (wire.permissions) |p| {
        out.mode = p.mode;
        out.permissions = p.rest;
    }
    out.hooks = wire.hooks;
    out.skills = wire.skills;
    return out;
}

// ───────── tests ─────────

const testing = std.testing;

test "parse: empty object yields zero-valued Settings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), "{}");
    try testing.expect(s.defaults.provider == null);
    try testing.expectEqual(@as(usize, 0), s.mcp_servers.len);
}

test "parse: defaults section is honoured" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "defaults": {
        \\   "provider": "openai",
        \\   "model": "gpt-5",
        \\   "system": "be terse",
        \\   "max_tokens": 1024
        \\}}
    ;
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqual(cli.Provider.openai, s.defaults.provider.?);
    try testing.expectEqualStrings("gpt-5", s.defaults.model.?);
    try testing.expectEqualStrings("be terse", s.defaults.system.?);
    try testing.expectEqual(@as(u32, 1024), s.defaults.max_tokens.?);
}

test "parse: unknown provider rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"defaults\":{\"provider\":\"googly\"}}";
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), json));
}

test "parse: unknown top-level fields are tolerated" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"future_field\": 42, \"defaults\": {\"model\":\"x\"}}";
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqualStrings("x", s.defaults.model.?);
}

test "parse: malformed JSON errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), "not json"));
}

test "parse: mcp_servers list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"mcp_servers\":[\"npx server-one\", \"npx server-two\"]}";
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqual(@as(usize, 2), s.mcp_servers.len);
    try testing.expectEqualStrings("npx server-one", s.mcp_servers[0]);
    try testing.expectEqualStrings("npx server-two", s.mcp_servers[1]);
}

test "merge: project overrides user defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user = try parse(arena, "{\"defaults\":{\"model\":\"sonnet\",\"max_tokens\":512}}");
    const project = try parse(arena, "{\"defaults\":{\"model\":\"opus\"}}");
    try user.merge(arena, project);
    try testing.expectEqualStrings("opus", user.defaults.model.?);
    try testing.expectEqual(@as(u32, 512), user.defaults.max_tokens.?);
}

test "merge: mcp_servers are concatenated" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user = try parse(arena, "{\"mcp_servers\":[\"a\"]}");
    const project = try parse(arena, "{\"mcp_servers\":[\"b\",\"c\"]}");
    try user.merge(arena, project);
    try testing.expectEqual(@as(usize, 3), user.mcp_servers.len);
    try testing.expectEqualStrings("a", user.mcp_servers[0]);
    try testing.expectEqualStrings("c", user.mcp_servers[2]);
}

test "userPath: uses XDG_CONFIG_HOME when set" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("XDG_CONFIG_HOME", "/tmp/xdg");
    const p = try userPath(arena_state.allocator(), &env);
    try testing.expectEqualStrings("/tmp/xdg/velk/settings.json", p);
}

test "userPath: falls back to HOME/.config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("HOME", "/home/v");
    const p = try userPath(arena_state.allocator(), &env);
    try testing.expectEqualStrings("/home/v/.config/velk/settings.json", p);
}
