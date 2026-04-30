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
    /// Optional default output style by name ("concise", "verbose",
    /// etc.). Persisted by `/style` so the next launch starts in the
    /// last-selected style.
    style: ?[]const u8 = null,
};

pub const Profile = struct {
    name: []const u8,
    defaults: Defaults = .{},
    /// Optional tool-name allowlist. When non-empty, the registry is
    /// filtered to just these names while this profile is active —
    /// useful for `review`, `audit`, or other read-only personas.
    /// Null/empty = no filtering (all tools exposed). Mirrors how the
    /// `task` sub-agent's `tools:` array filters the parent registry.
    tools: []const []const u8 = &.{},
};

/// User-declared shell tool. The model invokes it like any other
/// tool; the implementation shells out to `command` via `/bin/sh -c`.
/// v1 has no input substitution — the command is fixed; the tool's
/// JSON input schema is empty. A `description` is required so the
/// model has guidance on when to call it.
pub const CustomTool = struct {
    name: []const u8,
    command: []const u8,
    description: []const u8,
    /// Optional named arguments. Each name appears in `command` as
    /// `${name}` and is shell-escaped at substitution time. When
    /// `args` is empty the input schema is `{}` (no parameters).
    args: []const CustomToolArg = &.{},
    /// Per-tool timeout. Falls back to the default bash timeout when
    /// null so existing entries keep their behaviour.
    timeout_ms: ?u32 = null,
    /// Working directory the command runs in. Resolved relative to
    /// CWD when relative; null = inherit CWD (current behaviour).
    cwd: ?[]const u8 = null,
};

pub const CustomToolArg = struct {
    name: []const u8,
    description: []const u8 = "",
    /// When true, the model MUST supply this arg. Default false: the
    /// substitution falls back to an empty string when the arg is
    /// missing, so optional args degrade gracefully.
    required: bool = false,
};

/// Per-language LSP server config. `extension` is matched against a
/// file's tail (`.zig`, `.rs`, etc.) — the leading dot is included
/// in the key so `path.endsWith(ext)` works directly.
pub const LspServer = struct {
    extension: []const u8,
    command: []const u8,
    /// LSP `languageId` field sent in `textDocument/didOpen`. Server-
    /// specific (zls wants "zig", rust-analyzer wants "rust", etc.).
    language_id: []const u8,
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
    /// Named profiles (e.g. `review`, `fast`). Each is a `Defaults`
    /// overlay selected at launch via `-P <name>` / `--profile`.
    /// Project profiles win on name collision (merge order is
    /// user-then-project, last-write-wins).
    profiles: []const Profile = &.{},
    /// User-declared shell tools. Merged from user + project files;
    /// later entries with the same name replace earlier ones.
    custom_tools: []const CustomTool = &.{},
    /// Per-language LSP servers. Same merge semantics as `custom_tools`:
    /// later entries replace same-extension earlier ones.
    lsp_servers: []const LspServer = &.{},
    /// Compiled hook engine. Built lazily by `compileHooks` once
    /// settings have been merged so project-level hooks override the
    /// user-level set wholesale (no concatenation — last one wins).
    hook_engine: hooks.Engine = .{},

    /// `Defaults` section overlay: every non-null field of `b`
    /// replaces the matching field on `self`.
    pub fn applyDefaults(self: *Settings, b: Defaults) void {
        if (b.provider) |p| self.defaults.provider = p;
        if (b.model) |m| self.defaults.model = m;
        if (b.system) |s| self.defaults.system = s;
        if (b.max_tokens) |t| self.defaults.max_tokens = t;
        if (b.style) |s| self.defaults.style = s;
    }

    /// Look up a named profile. Case-sensitive. Returns null when no
    /// match — main.zig surfaces that as a startup warning so a
    /// typoed `-P revview` doesn't silently downgrade to defaults.
    pub fn findProfile(self: Settings, name: []const u8) ?Defaults {
        for (self.profiles) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.defaults;
        }
        return null;
    }

    /// Like `findProfile` but returns the whole record so callers
    /// can also read the tools allowlist. Kept separate so existing
    /// callers that only care about `Defaults` don't need to change.
    pub fn findProfileFull(self: Settings, name: []const u8) ?Profile {
        for (self.profiles) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Merge `b` into `self`. `b` wins for every field it specifies;
    /// `self` keeps its existing values otherwise. `mcp_servers` is
    /// concatenated: project + user lists are both honoured. `profiles`
    /// are merged by name with last-write-wins so a project file can
    /// override a same-named user profile without losing the rest.
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
        if (b.profiles.len > 0) {
            self.profiles = try mergeProfiles(arena, self.profiles, b.profiles);
        }
        if (b.custom_tools.len > 0) {
            self.custom_tools = try mergeCustomTools(arena, self.custom_tools, b.custom_tools);
        }
        if (b.lsp_servers.len > 0) {
            self.lsp_servers = try mergeLspServers(arena, self.lsp_servers, b.lsp_servers);
        }
    }

    /// Lookup an LSP server config by file extension. Match is exact
    /// (case-sensitive), so settings should use `.zig` / `.rs` /
    /// etc. with the dot included.
    pub fn findLspServer(self: Settings, extension: []const u8) ?LspServer {
        for (self.lsp_servers) |s| {
            if (std.mem.eql(u8, s.extension, extension)) return s;
        }
        return null;
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

/// Persist the active output-style name to `.velk/settings.json` so
/// the next launch picks it back up. The mutation is targeted: read
/// the existing file (or start from `{}`), set `defaults.style`, and
/// rewrite. Other top-level keys and unknown fields are preserved
/// — the JSON round-trip is via `std.json.Value`, which keeps
/// everything we don't touch intact.
///
/// Pass `null` for `style_name` to clear the persisted style.
pub fn setProjectStyle(
    arena: std.mem.Allocator,
    io: Io,
    style_name: ?[]const u8,
) !void {
    const path = try projectPath(arena);
    try setStyleAtPath(arena, io, Io.Dir.cwd(), project_dir_name, path, style_name);
}

/// Path-taking primitive used by `setProjectStyle`. Tests target this
/// directly via a tmp `Io.Dir` so they don't have to chdir.
fn setStyleAtPath(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    dir_name: []const u8,
    file_path: []const u8,
    style_name: ?[]const u8,
) !void {
    var root: std.json.Value = .{ .object = .empty };
    if (dir.readFileAlloc(io, file_path, arena, .limited(1 * 1024 * 1024))) |data| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch
            return Error.InvalidSettingsJson;
        if (parsed != .object) return Error.InvalidSettingsJson;
        root = parsed;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    var defaults: std.json.ObjectMap = if (root.object.get("defaults")) |d|
        if (d == .object) d.object else .empty
    else
        .empty;
    if (style_name) |name| {
        try defaults.put(arena, "style", .{ .string = try arena.dupe(u8, name) });
    } else {
        _ = defaults.swapRemove("style");
    }
    try root.object.put(arena, "defaults", .{ .object = defaults });

    dir.createDirPath(io, dir_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const out = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    const with_nl = try std.fmt.allocPrint(arena, "{s}\n", .{out});
    try dir.writeFile(io, .{ .sub_path = file_path, .data = with_nl });
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
    /// `{ "review": { "model": "...", ... }, "fast": { ... } }`.
    /// Stored as opaque JSON during the JSON-leaky parse and
    /// resolved into `Profile[]` afterwards so unknown keys inside
    /// each profile (forward-compat) don't bomb the whole file.
    profiles: ?std.json.Value = null,
    /// `[{"name":"lint","command":"npm run lint","description":"…"}, ...]`.
    /// Strict-shape array; keys other than name/command/description
    /// are tolerated and ignored.
    tools: ?[]WireCustomTool = null,
    /// `{"extension":".zig","command":"zls","language_id":"zig"}, ...`
    lsp: ?WireLsp = null,
};

const WireCustomTool = struct {
    name: ?[]const u8 = null,
    command: ?[]const u8 = null,
    description: ?[]const u8 = null,
    args: ?[]WireCustomToolArg = null,
    timeout_ms: ?u32 = null,
    cwd: ?[]const u8 = null,
};

const WireCustomToolArg = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

const WireLsp = struct {
    servers: ?[]WireLspServer = null,
};

const WireLspServer = struct {
    extension: ?[]const u8 = null,
    command: ?[]const u8 = null,
    language_id: ?[]const u8 = null,
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
    style: ?[]const u8 = null,
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
        out.defaults.style = d.style;
    }
    if (wire.mcp_servers) |m| out.mcp_servers = m;
    if (wire.permissions) |p| {
        out.mode = p.mode;
        out.permissions = p.rest;
    }
    out.hooks = wire.hooks;
    out.skills = wire.skills;
    if (wire.profiles) |v| out.profiles = try parseProfiles(arena, v);
    if (wire.tools) |t| out.custom_tools = try parseCustomTools(arena, t);
    if (wire.lsp) |l| {
        if (l.servers) |s| {
            out.lsp_servers = try parseLspServers(arena, s);
        }
    }
    return out;
}

fn parseLspServers(arena: std.mem.Allocator, raw: []WireLspServer) ![]const LspServer {
    var list: std.ArrayList(LspServer) = .empty;
    for (raw) |w| {
        const ext = w.extension orelse return Error.InvalidSettingsJson;
        const cmd = w.command orelse return Error.InvalidSettingsJson;
        const lid = w.language_id orelse return Error.InvalidSettingsJson;
        try list.append(arena, .{
            .extension = try arena.dupe(u8, ext),
            .command = try arena.dupe(u8, cmd),
            .language_id = try arena.dupe(u8, lid),
        });
    }
    return list.items;
}

fn mergeLspServers(arena: std.mem.Allocator, a: []const LspServer, b: []const LspServer) ![]const LspServer {
    var list: std.ArrayList(LspServer) = .empty;
    try list.appendSlice(arena, a);
    outer: for (b) |new| {
        for (list.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.extension, new.extension)) {
                list.items[i] = new;
                continue :outer;
            }
        }
        try list.append(arena, new);
    }
    return list.items;
}

fn parseCustomTools(arena: std.mem.Allocator, raw: []WireCustomTool) ![]const CustomTool {
    var list: std.ArrayList(CustomTool) = .empty;
    for (raw) |w| {
        const name = w.name orelse return Error.InvalidSettingsJson;
        const command = w.command orelse return Error.InvalidSettingsJson;
        const description = w.description orelse return Error.InvalidSettingsJson;
        var args_out: []CustomToolArg = &.{};
        if (w.args) |raw_args| {
            const buf = try arena.alloc(CustomToolArg, raw_args.len);
            for (raw_args, 0..) |wa, i| {
                const aname = wa.name orelse return Error.InvalidSettingsJson;
                buf[i] = .{
                    .name = try arena.dupe(u8, aname),
                    .description = if (wa.description) |d| try arena.dupe(u8, d) else "",
                    .required = wa.required orelse false,
                };
            }
            args_out = buf;
        }
        try list.append(arena, .{
            .name = try arena.dupe(u8, name),
            .command = try arena.dupe(u8, command),
            .description = try arena.dupe(u8, description),
            .args = args_out,
            .timeout_ms = w.timeout_ms,
            .cwd = if (w.cwd) |c| try arena.dupe(u8, c) else null,
        });
    }
    return list.items;
}

fn mergeCustomTools(arena: std.mem.Allocator, a: []const CustomTool, b: []const CustomTool) ![]const CustomTool {
    var list: std.ArrayList(CustomTool) = .empty;
    try list.appendSlice(arena, a);
    outer: for (b) |new| {
        for (list.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.name, new.name)) {
                list.items[i] = new;
                continue :outer;
            }
        }
        try list.append(arena, new);
    }
    return list.items;
}

/// Resolve a JSON object whose keys are profile names and whose values
/// are `Defaults`-shaped objects. Unknown keys inside each profile are
/// tolerated (forward-compat). An invalid `provider` enum value rejects
/// the whole file — same as the top-level defaults check.
fn parseProfiles(arena: std.mem.Allocator, v: std.json.Value) ![]const Profile {
    const obj = switch (v) {
        .object => |o| o,
        else => return Error.InvalidSettingsJson,
    };
    var list: std.ArrayList(Profile) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = try arena.dupe(u8, entry.key_ptr.*);
        var prof: Profile = .{ .name = name };
        const inner = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return Error.InvalidSettingsJson,
        };
        var inner_it = inner.iterator();
        while (inner_it.next()) |kv| {
            const k = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (std.mem.eql(u8, k, "provider")) {
                const s = switch (val) {
                    .string => |str| str,
                    else => return Error.InvalidSettingsJson,
                };
                if (std.mem.eql(u8, s, "anthropic")) prof.defaults.provider = .anthropic
                else if (std.mem.eql(u8, s, "openai")) prof.defaults.provider = .openai
                else if (std.mem.eql(u8, s, "openrouter")) prof.defaults.provider = .openrouter
                else return Error.InvalidSettingsJson;
            } else if (std.mem.eql(u8, k, "model")) {
                prof.defaults.model = switch (val) {
                    .string => |s| try arena.dupe(u8, s),
                    else => return Error.InvalidSettingsJson,
                };
            } else if (std.mem.eql(u8, k, "system")) {
                prof.defaults.system = switch (val) {
                    .string => |s| try arena.dupe(u8, s),
                    else => return Error.InvalidSettingsJson,
                };
            } else if (std.mem.eql(u8, k, "max_tokens")) {
                prof.defaults.max_tokens = switch (val) {
                    .integer => |i| if (i < 0) return Error.InvalidSettingsJson else @intCast(i),
                    else => return Error.InvalidSettingsJson,
                };
            } else if (std.mem.eql(u8, k, "tools")) {
                const arr = switch (val) {
                    .array => |a| a,
                    else => return Error.InvalidSettingsJson,
                };
                const buf = try arena.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    buf[i] = switch (item) {
                        .string => |s| try arena.dupe(u8, s),
                        else => return Error.InvalidSettingsJson,
                    };
                }
                prof.tools = buf;
            }
            // Unknown keys inside a profile are ignored (forward-compat).
        }
        try list.append(arena, prof);
    }
    return list.items;
}

/// Profile-list merge: same-name entries from `b` replace `a`'s entry;
/// fresh names are appended. The result is freshly allocated so the
/// caller can swap it in.
fn mergeProfiles(arena: std.mem.Allocator, a: []const Profile, b: []const Profile) ![]const Profile {
    var list: std.ArrayList(Profile) = .empty;
    try list.appendSlice(arena, a);
    outer: for (b) |new| {
        for (list.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.name, new.name)) {
                list.items[i] = new;
                continue :outer;
            }
        }
        try list.append(arena, new);
    }
    return list.items;
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

test "setStyleAtPath: writes defaults.style when file is fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const dir_name = try std.fmt.allocPrint(a, "{s}/.velk", .{tmp_abs});
    const file_path = try std.fmt.allocPrint(a, "{s}/.velk/settings.json", .{tmp_abs});

    try setStyleAtPath(a, testing.io, Io.Dir.cwd(), dir_name, file_path, "concise");
    const data = try Io.Dir.cwd().readFileAlloc(testing.io, file_path, a, .limited(64 * 1024));
    try testing.expect(std.mem.indexOf(u8, data, "\"style\": \"concise\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"defaults\"") != null);
}

test "setStyleAtPath: preserves unrelated keys on update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const dir_name = try std.fmt.allocPrint(a, "{s}/.velk", .{tmp_abs});
    const file_path = try std.fmt.allocPrint(a, "{s}/.velk/settings.json", .{tmp_abs});

    Io.Dir.cwd().createDirPath(testing.io, dir_name) catch {};
    const seed =
        \\{ "defaults": { "model": "claude-sonnet-4-6" },
        \\  "mcp_servers": ["a","b"] }
    ;
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file_path, .data = seed });

    try setStyleAtPath(a, testing.io, Io.Dir.cwd(), dir_name, file_path, "verbose");
    const data = try Io.Dir.cwd().readFileAlloc(testing.io, file_path, a, .limited(64 * 1024));
    try testing.expect(std.mem.indexOf(u8, data, "\"model\": \"claude-sonnet-4-6\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"style\": \"verbose\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"mcp_servers\"") != null);
}

test "setStyleAtPath: null style_name removes defaults.style" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const dir_name = try std.fmt.allocPrint(a, "{s}/.velk", .{tmp_abs});
    const file_path = try std.fmt.allocPrint(a, "{s}/.velk/settings.json", .{tmp_abs});

    try setStyleAtPath(a, testing.io, Io.Dir.cwd(), dir_name, file_path, "concise");
    try setStyleAtPath(a, testing.io, Io.Dir.cwd(), dir_name, file_path, null);
    const data = try Io.Dir.cwd().readFileAlloc(testing.io, file_path, a, .limited(64 * 1024));
    try testing.expect(std.mem.indexOf(u8, data, "\"style\"") == null);
}

test "defaults.style: parsed from settings.json" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), "{\"defaults\":{\"style\":\"concise\"}}");
    try testing.expectEqualStrings("concise", s.defaults.style.?);
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

test "profiles: parsed and looked up by name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "profiles": {
        \\   "review": { "model": "claude-sonnet-4-6", "system": "be terse", "max_tokens": 8192 },
        \\   "fast":   { "model": "claude-haiku-4-5", "max_tokens": 1024 }
        \\}}
    ;
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqual(@as(usize, 2), s.profiles.len);

    const review = s.findProfile("review").?;
    try testing.expectEqualStrings("claude-sonnet-4-6", review.model.?);
    try testing.expectEqualStrings("be terse", review.system.?);
    try testing.expectEqual(@as(u32, 8192), review.max_tokens.?);

    const fast = s.findProfile("fast").?;
    try testing.expectEqualStrings("claude-haiku-4-5", fast.model.?);
}

test "profiles: tools allowlist parsed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "profiles": {
        \\   "review": { "model": "claude-sonnet-4-6", "tools": ["read_file","grep","bash"] }
        \\}}
    ;
    const s = try parse(arena_state.allocator(), json);
    const prof = s.findProfileFull("review").?;
    try testing.expectEqual(@as(usize, 3), prof.tools.len);
    try testing.expectEqualStrings("read_file", prof.tools[0]);
    try testing.expectEqualStrings("grep", prof.tools[1]);
    try testing.expectEqualStrings("bash", prof.tools[2]);
}

test "profiles: tools field defaults to empty when absent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), "{\"profiles\":{\"a\":{\"model\":\"x\"}}}");
    const prof = s.findProfileFull("a").?;
    try testing.expectEqual(@as(usize, 0), prof.tools.len);
}

test "profiles: tools must be string array" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"profiles\":{\"a\":{\"tools\":\"read_file\"}}}";
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), json));
}

test "profiles: lookup miss returns null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), "{\"profiles\":{\"a\":{\"model\":\"x\"}}}");
    try testing.expect(s.findProfile("nope") == null);
}

test "profiles: invalid provider in profile rejects file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"profiles\":{\"x\":{\"provider\":\"googly\"}}}";
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), json));
}

test "profiles: unknown keys inside a profile are tolerated" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"profiles\":{\"x\":{\"model\":\"m\",\"future\":42}}}";
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqualStrings("m", s.findProfile("x").?.model.?);
}

test "profiles: project profile overrides same-named user profile" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var user = try parse(arena, "{\"profiles\":{\"review\":{\"model\":\"sonnet\"},\"keep\":{\"model\":\"haiku\"}}}");
    const project = try parse(arena, "{\"profiles\":{\"review\":{\"model\":\"opus\"}}}");
    try user.merge(arena, project);
    try testing.expectEqual(@as(usize, 2), user.profiles.len);
    try testing.expectEqualStrings("opus", user.findProfile("review").?.model.?);
    try testing.expectEqualStrings("haiku", user.findProfile("keep").?.model.?);
}

test "profiles: applyDefaults overlays a Defaults onto Settings.defaults" {
    var s: Settings = .{};
    s.defaults.model = "base-model";
    s.defaults.max_tokens = 2048;
    s.applyDefaults(.{ .model = "profile-model" });
    try testing.expectEqualStrings("profile-model", s.defaults.model.?);
    try testing.expectEqual(@as(u32, 2048), s.defaults.max_tokens.?);
}

test "custom_tools: parsed from tools array" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "tools": [
        \\   {"name": "lint",  "command": "npm run lint",  "description": "Run the linter"},
        \\   {"name": "tests", "command": "zig build test", "description": "Run unit tests"}
        \\]}
    ;
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqual(@as(usize, 2), s.custom_tools.len);
    try testing.expectEqualStrings("lint", s.custom_tools[0].name);
    try testing.expectEqualStrings("npm run lint", s.custom_tools[0].command);
    try testing.expectEqualStrings("Run the linter", s.custom_tools[0].description);
    try testing.expectEqualStrings("tests", s.custom_tools[1].name);
}

test "custom_tools: parses args + timeout_ms + cwd" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "tools": [{
        \\  "name": "wcfile",
        \\  "command": "wc -l ${path}",
        \\  "description": "count lines",
        \\  "args": [
        \\    {"name":"path","description":"file to count","required":true}
        \\  ],
        \\  "timeout_ms": 5000,
        \\  "cwd": "/tmp"
        \\}]}
    ;
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqual(@as(usize, 1), s.custom_tools.len);
    const ct = s.custom_tools[0];
    try testing.expectEqualStrings("wcfile", ct.name);
    try testing.expectEqual(@as(usize, 1), ct.args.len);
    try testing.expectEqualStrings("path", ct.args[0].name);
    try testing.expectEqualStrings("file to count", ct.args[0].description);
    try testing.expect(ct.args[0].required);
    try testing.expectEqual(@as(?u32, 5000), ct.timeout_ms);
    try testing.expectEqualStrings("/tmp", ct.cwd.?);
}

test "custom_tools: args optional fields default sanely" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "tools": [{
        \\  "name": "x", "command": "echo ${y}", "description": "d",
        \\  "args": [{"name":"y"}]
        \\}]}
    ;
    const s = try parse(arena_state.allocator(), json);
    const arg = s.custom_tools[0].args[0];
    try testing.expectEqualStrings("y", arg.name);
    try testing.expectEqualStrings("", arg.description);
    try testing.expect(!arg.required);
}

test "custom_tools: arg missing name rejects file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"tools":[{"name":"x","command":"y","description":"z","args":[{"required":true}]}]}
    ;
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), json));
}

test "custom_tools: missing required field rejects file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"tools\":[{\"name\":\"x\",\"command\":\"echo\"}]}"; // no description
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), json));
}

test "lsp_servers: parsed from lsp.servers array" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "lsp": { "servers": [
        \\   {"extension": ".zig", "command": "zls",            "language_id": "zig"},
        \\   {"extension": ".rs",  "command": "rust-analyzer",  "language_id": "rust"}
        \\]}}
    ;
    const s = try parse(arena_state.allocator(), json);
    try testing.expectEqual(@as(usize, 2), s.lsp_servers.len);
    const z = s.findLspServer(".zig").?;
    try testing.expectEqualStrings("zls", z.command);
    try testing.expectEqualStrings("zig", z.language_id);
    const r = s.findLspServer(".rs").?;
    try testing.expectEqualStrings("rust-analyzer", r.command);
}

test "lsp_servers: missing required field rejects file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json = "{\"lsp\":{\"servers\":[{\"extension\":\".zig\",\"command\":\"zls\"}]}}"; // no language_id
    try testing.expectError(Error.InvalidSettingsJson, parse(arena_state.allocator(), json));
}

test "lsp_servers: project entry replaces same-extension user entry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var user = try parse(arena, "{\"lsp\":{\"servers\":[{\"extension\":\".zig\",\"command\":\"zls-old\",\"language_id\":\"zig\"}]}}");
    const project = try parse(arena, "{\"lsp\":{\"servers\":[{\"extension\":\".zig\",\"command\":\"zls-new\",\"language_id\":\"zig\"}]}}");
    try user.merge(arena, project);
    try testing.expectEqual(@as(usize, 1), user.lsp_servers.len);
    try testing.expectEqualStrings("zls-new", user.findLspServer(".zig").?.command);
}

test "lsp_servers: lookup miss returns null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), "{\"lsp\":{\"servers\":[{\"extension\":\".zig\",\"command\":\"zls\",\"language_id\":\"zig\"}]}}");
    try testing.expect(s.findLspServer(".rs") == null);
}

test "custom_tools: project entry replaces same-named user entry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var user = try parse(arena, "{\"tools\":[{\"name\":\"lint\",\"command\":\"old\",\"description\":\"d\"},{\"name\":\"keep\",\"command\":\"k\",\"description\":\"d\"}]}");
    const project = try parse(arena, "{\"tools\":[{\"name\":\"lint\",\"command\":\"new\",\"description\":\"d2\"}]}");
    try user.merge(arena, project);
    try testing.expectEqual(@as(usize, 2), user.custom_tools.len);
    // Find by name (merge preserves user-list-then-overrides order).
    var found_lint: ?CustomTool = null;
    var found_keep: ?CustomTool = null;
    for (user.custom_tools) |c| {
        if (std.mem.eql(u8, c.name, "lint")) found_lint = c;
        if (std.mem.eql(u8, c.name, "keep")) found_keep = c;
    }
    try testing.expectEqualStrings("new", found_lint.?.command);
    try testing.expectEqualStrings("k", found_keep.?.command);
}
