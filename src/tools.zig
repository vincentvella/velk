//! Built-in tools the agent can call. Each tool is a small wrapper:
//! parse JSON input, validate path safety where applicable, do the
//! work, format the output. Schemas are JSON strings parsed once at
//! `buildAll` time and reused per request.
//!
//! All filesystem and process operations route through the Io
//! threaded into `Settings.io` (`std.process.Init.io` in the real
//! program, `std.testing.io` in tests).

const std = @import("std");
const Io = std.Io;
const mvzr = @import("mvzr");
const tool = @import("tool.zig");
const diff = @import("diff.zig");
const approval = @import("approval.zig");
const permissions = @import("permissions.zig");
const ignore = @import("ignore.zig");
const web = @import("web.zig");
const todos_mod = @import("todos.zig");
const ask_mod = @import("ask.zig");
const provider_mod = @import("provider.zig");
const agent_mod = @import("agent.zig");
const hooks_mod = @import("hooks.zig");

/// Per-process tool settings. Pointed to by every tool's `context` field
/// so any tool that touches the filesystem can consult `unsafe` and reuse
/// the right `io` implementation.
pub const Settings = struct {
    io: Io,
    /// gpa for diff/path duplications that the approval gate hands off
    /// to the TUI thread. Required when `approval` is non-null.
    gpa: std.mem.Allocator,
    /// When false, paths must be relative and lexically inside CWD.
    unsafe: bool = false,
    /// Optional cross-thread gate. When set, write-side tools surface
    /// a unified diff to the TUI and block until the user approves /
    /// skips / always-applies. When null, every change auto-applies
    /// (`--no-tui`, one-shot CLI, smoke tests).
    approval: ?*approval.ApprovalGate = null,
    /// Permissions mode. `plan` refuses every write tool; the others
    /// affect whether the gate prompts (handled at startup by setting
    /// `gate.bypass` for `accept_*` modes).
    mode: permissions.Mode = .default,
    /// When true, `ls` and `grep` descend into / list paths that
    /// match the common-ignore set (node_modules, .git, etc) AND
    /// any `.gitignore` parsed at startup.
    include_ignored: bool = false,
    /// Optional parsed `.gitignore` matcher. When non-empty, ls /
    /// grep also skip paths matching its rules. The hardcoded
    /// common-ignore set is always engaged regardless.
    gitignore_matcher: ignore.Matcher = .empty(),
    /// Process env (for XDG_CACHE_HOME etc). Nullable for tests.
    env_map: ?*std.process.Environ.Map = null,
    /// Optional todo store. When set, the `todo_write` tool is
    /// registered and writes here; the TUI renders from a snapshot.
    todos: ?*todos_mod.Store = null,
    /// Optional ask gate. When set, the `ask_user_question` tool is
    /// registered; calls block on the gate until the TUI delivers a
    /// selection (or Esc cancels).
    ask: ?*ask_mod.AskGate = null,
    /// Sub-agent dispatcher. Populated by `main.zig` *after*
    /// `buildAll` runs (the `task` tool needs a back-pointer to the
    /// rest of the registry). When non-null, the `task` tool is
    /// registered.
    sub_agent: ?*const SubAgent = null,
    /// Per-language LSP server configs (extension → command +
    /// languageId). Populated from settings.json. The
    /// `lsp_diagnostics` tool looks up by extension.
    lsp_servers: []const LspServerConfig = &.{},
};

/// Mirror of `settings.LspServer` — duplicated here so tools.zig
/// doesn't have to import settings.zig (which would create a
/// dependency cycle through the wire types).
pub const LspServerConfig = struct {
    extension: []const u8,
    command: []const u8,
    language_id: []const u8,
};

/// Wires the `task` tool's child agent into the parent's runtime.
/// Owned by main.zig; back-pointed from `Settings.sub_agent` once
/// the tool registry has been built.
pub const SubAgent = struct {
    provider: provider_mod.Provider,
    model: []const u8,
    max_tokens: u32 = 4096,
    /// The full parent registry. The child filters by name when the
    /// caller passes a `tools` allowlist; otherwise it inherits all.
    tools: []const tool.Tool = &.{},
    max_iterations: u32 = 5,
    /// Optional system prompt for the child. If null we let the
    /// child run with no system prompt at all (matches what the
    /// caller asked for, no parent leakage).
    system: ?[]const u8 = null,
    /// Hooks fire inside child tool calls just like the parent —
    /// safety boundaries should still apply. Null disables.
    hook_engine: ?*const hooks_mod.Engine = null,
    hook_io: ?Io = null,
};

pub const Error = error{
    PathOutsideCwd,
    InvalidPath,
};

const max_output_bytes = 32 * 1024;
const max_file_bytes = 256 * 1024;

/// Build every built-in tool. The returned slice borrows from `arena`
/// and from `settings` — both must outlive the tools.
pub fn buildAll(arena: std.mem.Allocator, settings: *const Settings) ![]const tool.Tool {
    var list: std.ArrayList(tool.Tool) = .empty;
    try list.append(arena, try buildEcho(arena));
    try list.append(arena, try buildReadFile(arena, settings));
    try list.append(arena, try buildWriteFile(arena, settings));
    try list.append(arena, try buildEdit(arena, settings));
    try list.append(arena, try buildLs(arena, settings));
    try list.append(arena, try buildGrep(arena, settings));
    try list.append(arena, try buildBash(arena, settings));
    try list.append(arena, try buildWebFetch(arena, settings));
    try list.append(arena, try buildWebSearch(arena, settings));
    try list.append(arena, try buildWorktree(arena, settings));
    try list.append(arena, try buildWritePlan(arena, settings));
    try list.append(arena, try buildReadMemory(arena, settings));
    try list.append(arena, try buildWriteMemory(arena, settings));
    try list.append(arena, try buildLspDiagnostics(arena, settings));
    try list.append(arena, try buildViewImage(arena, settings));
    if (settings.todos != null) try list.append(arena, try buildTodoWrite(arena, settings));
    if (settings.ask != null) try list.append(arena, try buildAskUserQuestion(arena, settings));
    if (settings.sub_agent != null) try list.append(arena, try buildTask(arena, settings));
    if (settings.sub_agent != null) try list.append(arena, try buildTeam(arena, settings));
    return list.items;
}

// ───────── safety ─────────

/// Reject absolute paths and any relative path that escapes CWD via `..`.
/// Lexical-only: symlinks pointing outside CWD are not caught.
fn validatePath(settings: *const Settings, raw: []const u8) ![]const u8 {
    if (settings.unsafe) return raw;
    if (raw.len == 0) return Error.InvalidPath;
    if (std.fs.path.isAbsolute(raw)) return Error.PathOutsideCwd;

    var depth: i32 = 0;
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return Error.PathOutsideCwd;
        } else {
            depth += 1;
        }
    }
    return raw;
}

fn settingsFromCtx(ctx: ?*anyopaque) *const Settings {
    return @ptrCast(@alignCast(ctx.?));
}

fn errorOutput(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !tool.Output {
    return .{ .text = try std.fmt.allocPrint(arena, fmt, args), .is_error = true };
}

// ───────── echo ─────────

const echo_schema_json: []const u8 =
    \\{"type":"object","properties":{"text":{"type":"string","description":"The text to echo back."}},"required":["text"]}
;

pub fn buildEcho(arena: std.mem.Allocator) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, echo_schema_json, .{});
    return .{
        .name = "echo",
        .description = "Echo back the provided text. Useful for sanity-checking the tool loop.",
        .input_schema = schema,
        .execute = echoExecute,
    };
}

fn echoExecute(_: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const text = (try getString(input, "text")) orelse return errorOutput(arena, "echo: missing 'text'", .{});
    return .{ .text = try arena.dupe(u8, text) };
}

// ───────── read_file ─────────

const read_file_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "path":{"type":"string","description":"Relative path from CWD."},
    \\   "offset":{"type":"integer","description":"Optional 1-indexed line to start from."},
    \\   "limit":{"type":"integer","description":"Optional max number of lines to read."}
    \\ },
    \\ "required":["path"]}
;

pub fn buildReadFile(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, read_file_schema_json, .{});
    return .{
        .name = "read_file",
        .description = "Read a file's contents. Optionally slice by line range with `offset` (1-indexed start) and `limit` (max lines).",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = readFileExecute,
    };
}

fn readFileExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const raw_path = (try getString(input, "path")) orelse return errorOutput(arena, "read_file: missing 'path'", .{});
    const path = validatePath(settings, raw_path) catch |e| return errorOutput(arena, "read_file: {s}", .{@errorName(e)});

    const offset_opt = try getInt(input, "offset");
    const limit_opt = try getInt(input, "limit");

    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(settings.io, path, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.StreamTooLong => return errorOutput(arena, "read_file: {s} exceeds {d} bytes", .{ path, max_file_bytes }),
        else => return errorOutput(arena, "read_file: {s}: {s}", .{ path, @errorName(e) }),
    };

    if (offset_opt == null and limit_opt == null) {
        return .{ .text = data };
    }

    const start_line: usize = if (offset_opt) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const max_lines: usize = if (limit_opt) |l| (if (l > 0) @intCast(l) else 0) else std.math.maxInt(usize);

    var out: std.ArrayList(u8) = .empty;
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    var current: usize = 1;
    var emitted: usize = 0;
    while (line_iter.next()) |line| {
        if (current >= start_line and emitted < max_lines) {
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
            emitted += 1;
        }
        current += 1;
        if (emitted >= max_lines) break;
    }
    return .{ .text = out.items };
}

// ───────── write_file ─────────

const write_file_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "path":{"type":"string","description":"Relative path from CWD. Parent directory must already exist."},
    \\   "content":{"type":"string","description":"Full file contents to write (overwrites existing)."}
    \\ },
    \\ "required":["path","content"]}
;

pub fn buildWriteFile(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, write_file_schema_json, .{});
    return .{
        .name = "write_file",
        .description = "Create or overwrite a file with the given contents. Parent directory must exist.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = writeFileExecute,
    };
}

fn writeFileExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    if (settings.mode.refusesWrites()) {
        return errorOutput(arena, "write_file: refused — velk is in plan mode (read-only)", .{});
    }
    const raw_path = (try getString(input, "path")) orelse return errorOutput(arena, "write_file: missing 'path'", .{});
    const content = (try getString(input, "content")) orelse return errorOutput(arena, "write_file: missing 'content'", .{});
    const path = validatePath(settings, raw_path) catch |e| return errorOutput(arena, "write_file: {s}", .{@errorName(e)});

    const cwd = Io.Dir.cwd();
    // Read the existing file (if any) for the "old" diff side. A
    // missing file is a 0-byte old; the diff renders as all `+` lines.
    const original = cwd.readFileAlloc(settings.io, path, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return errorOutput(arena, "write_file: read {s}: {s}", .{ path, @errorName(e) }),
    };

    switch (try maybeRequestApproval(settings, arena, path, original, content)) {
        .apply, .always_apply => {},
        .skip => return .{ .text = try std.fmt.allocPrint(arena, "write_file: user skipped {s}", .{path}) },
    }

    cwd.writeFile(settings.io, .{ .sub_path = path, .data = content }) catch |e|
        return errorOutput(arena, "write_file: {s}: {s}", .{ path, @errorName(e) });

    return .{ .text = try std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, path }) };
}

// ───────── edit ─────────

const edit_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "path":{"type":"string","description":"Relative path from CWD."},
    \\   "old_string":{"type":"string","description":"Exact text to replace. Must occur exactly once."},
    \\   "new_string":{"type":"string","description":"Replacement text."}
    \\ },
    \\ "required":["path","old_string","new_string"]}
;

pub fn buildEdit(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, edit_schema_json, .{});
    return .{
        .name = "edit",
        .description = "Replace `old_string` with `new_string` in a file. Errors if the match is missing or non-unique.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = editExecute,
    };
}

fn editExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    if (settings.mode.refusesWrites()) {
        return errorOutput(arena, "edit: refused — velk is in plan mode (read-only)", .{});
    }
    const raw_path = (try getString(input, "path")) orelse return errorOutput(arena, "edit: missing 'path'", .{});
    const old_str = (try getString(input, "old_string")) orelse return errorOutput(arena, "edit: missing 'old_string'", .{});
    const new_str = (try getString(input, "new_string")) orelse return errorOutput(arena, "edit: missing 'new_string'", .{});
    const path = validatePath(settings, raw_path) catch |e| return errorOutput(arena, "edit: {s}", .{@errorName(e)});

    if (old_str.len == 0) return errorOutput(arena, "edit: old_string is empty", .{});

    const cwd = Io.Dir.cwd();
    const original = cwd.readFileAlloc(settings.io, path, arena, .limited(max_file_bytes)) catch |e|
        return errorOutput(arena, "edit: read {s}: {s}", .{ path, @errorName(e) });

    const first = std.mem.indexOf(u8, original, old_str) orelse return errorOutput(arena, "edit: no match for old_string in {s}", .{path});
    if (std.mem.indexOfPos(u8, original, first + 1, old_str) != null) {
        return errorOutput(arena, "edit: old_string matches more than once in {s} — make it more specific", .{path});
    }

    const total_len = original.len - old_str.len + new_str.len;
    var out = try arena.alloc(u8, total_len);
    @memcpy(out[0..first], original[0..first]);
    @memcpy(out[first .. first + new_str.len], new_str);
    @memcpy(out[first + new_str.len ..], original[first + old_str.len ..]);

    switch (try maybeRequestApproval(settings, arena, path, original, out)) {
        .apply, .always_apply => {},
        .skip => return .{ .text = try std.fmt.allocPrint(arena, "edit: user skipped {s}", .{path}) },
    }

    cwd.writeFile(settings.io, .{ .sub_path = path, .data = out }) catch |e|
        return errorOutput(arena, "edit: write {s}: {s}", .{ path, @errorName(e) });

    return .{ .text = try std.fmt.allocPrint(arena, "replaced 1 occurrence in {s}", .{path}) };
}

/// Compute the unified diff between `old` and `new`, surface it to
/// the TUI via the approval gate (if any), and block on the user's
/// decision. Auto-applies when no gate is configured (one-shot CLI,
/// `--no-tui`, smoke tests).
///
/// Dangerous-path override: writes to `~/.ssh`, `~/.aws`, or `.env*`
/// always force a prompt regardless of mode / gate.bypass — those
/// paths are never silently overwritten.
fn maybeRequestApproval(
    settings: *const Settings,
    arena: std.mem.Allocator,
    path: []const u8,
    old: []const u8,
    new: []const u8,
) !approval.Decision {
    const gate = settings.approval orelse return .apply;
    if (std.mem.eql(u8, old, new)) return .apply; // no-op write — don't bother prompting

    const dangerous = permissions.isDangerousPath(path);

    // The gate takes ownership of these gpa-allocated copies.
    const path_dup = try settings.gpa.dupe(u8, path);
    errdefer settings.gpa.free(path_dup);
    const diff_text = try diff.unifiedStringLabeled(arena, old, new, path, path, .{});
    const diff_dup = try settings.gpa.dupe(u8, diff_text);
    errdefer settings.gpa.free(diff_dup);

    if (dangerous) {
        // Bypass the bypass: temporarily clear it, force-prompt,
        // then restore (so subsequent non-dangerous edits still
        // honour acceptAll/acceptEdits).
        const saved = gate.bypass;
        gate.bypass = false;
        const decision = try gate.requestApproval(path_dup, diff_dup);
        gate.bypass = saved;
        // `always_apply` from a dangerous-path prompt only counts
        // for *this* path — don't promote the gate-wide bypass.
        if (decision == .always_apply) return .apply;
        return decision;
    }

    return gate.requestApproval(path_dup, diff_dup);
}

// ───────── ls ─────────

const ls_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "path":{"type":"string","description":"Relative directory path. Defaults to '.' (CWD)."}
    \\ }}
;

pub fn buildLs(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, ls_schema_json, .{});
    return .{
        .name = "ls",
        .description = "List entries in a directory with file sizes. Limited to 200 entries.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = lsExecute,
    };
}

fn lsExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const raw_path = (try getString(input, "path")) orelse ".";
    const path = validatePath(settings, raw_path) catch |e| return errorOutput(arena, "ls: {s}", .{@errorName(e)});

    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(settings.io, path, .{ .iterate = true }) catch |e|
        return errorOutput(arena, "ls: open {s}: {s}", .{ path, @errorName(e) });
    defer dir.close(settings.io);

    var out: std.ArrayList(u8) = .empty;
    var iter = dir.iterate();
    var count: usize = 0;
    var skipped: usize = 0;
    while (try iter.next(settings.io)) |entry| {
        if (!settings.include_ignored) {
            if (ignore.isIgnored(entry.name)) {
                skipped += 1;
                continue;
            }
            if (settings.gitignore_matcher.patterns.len > 0 and
                settings.gitignore_matcher.isIgnored(entry.name))
            {
                skipped += 1;
                continue;
            }
        }
        if (count >= 200) {
            try out.appendSlice(arena, "… (truncated at 200 entries)\n");
            break;
        }
        switch (entry.kind) {
            .directory => try out.print(arena, "{s}/\n", .{entry.name}),
            .file => {
                const stat = dir.statFile(settings.io, entry.name, .{}) catch {
                    try out.print(arena, "{s}\n", .{entry.name});
                    count += 1;
                    continue;
                };
                try out.print(arena, "{s} ({d} bytes)\n", .{ entry.name, stat.size });
            },
            else => try out.print(arena, "{s} ({s})\n", .{ entry.name, @tagName(entry.kind) }),
        }
        count += 1;
    }
    if (skipped > 0) {
        try out.print(arena, "(skipped {d} ignored entries — pass --include-ignored to see them)\n", .{skipped});
    }
    return .{ .text = out.items };
}

// ───────── grep ─────────

const grep_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "pattern":{"type":"string","description":"Regular expression pattern. Supports common metacharacters (^$.*+?[]|()), character classes, and anchors."},
    \\   "path":{"type":"string","description":"File or directory to search. Directories are walked recursively."},
    \\   "max_results":{"type":"integer","description":"Optional cap on result lines (default 100)."}
    \\ },
    \\ "required":["pattern","path"]}
;

pub fn buildGrep(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, grep_schema_json, .{});
    return .{
        .name = "grep",
        .description = "Regex-search a file or recursively across a directory. Returns matches as `path:lineno:content`.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = grepExecute,
    };
}

fn grepExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const pattern = (try getString(input, "pattern")) orelse return errorOutput(arena, "grep: missing 'pattern'", .{});
    const raw_path = (try getString(input, "path")) orelse return errorOutput(arena, "grep: missing 'path'", .{});
    const path = validatePath(settings, raw_path) catch |e| return errorOutput(arena, "grep: {s}", .{@errorName(e)});
    const max_results: usize = if (try getInt(input, "max_results")) |m| @intCast(@max(m, 1)) else 100;
    if (pattern.len == 0) return errorOutput(arena, "grep: pattern is empty", .{});

    var regex = mvzr.compile(pattern) orelse return errorOutput(arena, "grep: invalid regex: {s}", .{pattern});

    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(settings.io, path, .{}) catch |e|
        return errorOutput(arena, "grep: stat {s}: {s}", .{ path, @errorName(e) });

    var out: std.ArrayList(u8) = .empty;
    var hits: usize = 0;

    switch (stat.kind) {
        .file => try grepOneFile(settings, arena, &out, path, &regex, max_results, &hits),
        .directory => {
            var dir = cwd.openDir(settings.io, path, .{ .iterate = true }) catch |e|
                return errorOutput(arena, "grep: open dir {s}: {s}", .{ path, @errorName(e) });
            defer dir.close(settings.io);
            var walker = try dir.walk(arena);
            defer walker.deinit();
            while (try walker.next(settings.io)) |entry| {
                if (entry.kind != .file) continue;
                if (!settings.include_ignored) {
                    if (ignore.isIgnored(entry.path)) continue;
                    if (settings.gitignore_matcher.patterns.len > 0 and
                        settings.gitignore_matcher.isIgnored(entry.path))
                    {
                        continue;
                    }
                }
                const full = try std.fs.path.join(arena, &.{ path, entry.path });
                grepOneFile(settings, arena, &out, full, &regex, max_results, &hits) catch continue;
                if (hits >= max_results) break;
            }
        },
        else => return errorOutput(arena, "grep: {s} is not a regular file or directory", .{path}),
    }

    if (hits == 0) return .{ .text = try arena.dupe(u8, "(no matches)") };
    if (hits >= max_results) try out.print(arena, "… (truncated at {d} matches)\n", .{max_results});
    return .{ .text = out.items };
}

fn grepOneFile(
    settings: *const Settings,
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    regex: *const mvzr.Regex,
    max_results: usize,
    hits: *usize,
) !void {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(settings.io, path, arena, .limited(max_file_bytes)) catch return;
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    var lineno: usize = 1;
    while (line_iter.next()) |line| : (lineno += 1) {
        if (regex.match(line) != null) {
            try out.print(arena, "{s}:{d}:{s}\n", .{ path, lineno, line });
            hits.* += 1;
            if (hits.* >= max_results) return;
        }
    }
}

// ───────── bash ─────────

// ───────── web_search ─────────

const web_search_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "query":{"type":"string","description":"Search query."},
    \\   "max_results":{"type":"integer","description":"Cap on results returned (default 5, max 10)."}
    \\ },
    \\ "required":["query"]}
;

pub fn buildWebSearch(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, web_search_schema_json, .{});
    return .{
        .name = "web_search",
        .description = "Search the web. Uses Brave Search API when BRAVE_API_KEY is set; otherwise falls back to DuckDuckGo's HTML endpoint. Returns title, url, snippet for each hit.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = webSearchExecute,
    };
}

fn webSearchExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const query = (try getString(input, "query")) orelse return errorOutput(arena, "web_search: missing 'query'", .{});
    if (query.len == 0) return errorOutput(arena, "web_search: empty query", .{});
    const max_int = (try getInt(input, "max_results")) orelse 5;
    const max_results: usize = @intCast(@min(@max(max_int, 1), 10));
    const env_map = settings.env_map orelse return errorOutput(arena, "web_search: env not configured", .{});

    if (env_map.get("BRAVE_API_KEY")) |key| {
        const text = web.braveSearch(arena, settings.io, settings.gpa, query, key, max_results) catch |e|
            return errorOutput(arena, "web_search (brave): {s}", .{@errorName(e)});
        return .{ .text = text };
    }

    const text = web.duckduckgoSearch(arena, settings.io, settings.gpa, env_map, query, max_results) catch |e|
        return errorOutput(arena, "web_search (ddg): {s}", .{@errorName(e)});
    return .{ .text = text };
}

// ───────── web_fetch ─────────

const web_fetch_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "url":{"type":"string","description":"Absolute http(s) URL to fetch."}
    \\ },
    \\ "required":["url"]}
;

pub fn buildWebFetch(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, web_fetch_schema_json, .{});
    return .{
        .name = "web_fetch",
        .description = "Fetch an http(s) URL and return its body. HTML responses are converted to markdown; everything else is returned verbatim. Honors robots.txt; results are cached for 15 minutes.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = webFetchExecute,
    };
}

fn webFetchExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const url = (try getString(input, "url")) orelse return errorOutput(arena, "web_fetch: missing 'url'", .{});
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return errorOutput(arena, "web_fetch: only http(s) URLs are supported (got: {s})", .{url});
    }
    const env_map = settings.env_map orelse return errorOutput(arena, "web_fetch: env not configured", .{});

    const result = web.fetch(arena, settings.io, settings.gpa, env_map, url) catch |e| switch (e) {
        web.Error.DisallowedByRobots => return errorOutput(arena, "web_fetch: blocked by robots.txt for {s}", .{url}),
        else => return errorOutput(arena, "web_fetch: {s}: {s}", .{ url, @errorName(e) }),
    };

    if (result.status >= 400) {
        return errorOutput(arena, "web_fetch: HTTP {d} for {s}\n{s}", .{ result.status, url, result.body });
    }

    const cache_marker: []const u8 = if (result.from_cache) " (cached)" else "";
    const text = try std.fmt.allocPrint(
        arena,
        "GET {s} → {d}{s}\n\n{s}",
        .{ url, result.status, cache_marker, result.body },
    );
    return .{ .text = text };
}

const bash_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "command":{"type":"string","description":"Shell command to execute via /bin/sh -c."},
    \\   "timeout_ms":{"type":"integer","description":"Optional wall-clock timeout in milliseconds. Defaults to 30000."}
    \\ },
    \\ "required":["command"]}
;

const default_bash_timeout_ms: i64 = 30_000;

pub fn buildBash(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, bash_schema_json, .{});
    return .{
        .name = "bash",
        .description = "Run a shell command via `/bin/sh -c`. Returns exit code, stdout, and stderr.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = bashExecute,
    };
}

fn bashExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    if (settings.mode.refusesWrites()) {
        return errorOutput(arena, "bash: refused — velk is in plan mode (read-only)", .{});
    }
    const command = (try getString(input, "command")) orelse return errorOutput(arena, "bash: missing 'command'", .{});
    const timeout_ms: i64 = (try getInt(input, "timeout_ms")) orelse default_bash_timeout_ms;

    const result = runBash(arena, settings.io, command, timeout_ms) catch |e| switch (e) {
        error.Timeout => return errorOutput(arena, "bash: timed out after {d}ms", .{timeout_ms}),
        error.Canceled => return errorOutput(arena, "bash: aborted", .{}),
        else => return errorOutput(arena, "bash: spawn failed: {s}", .{@errorName(e)}),
    };

    const exit_code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
        else => -1,
    };

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "exit: {d}\n", .{exit_code});
    if (result.stdout.len > 0) try out.print(arena, "--- stdout ---\n{s}", .{result.stdout});
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0 and !std.mem.endsWith(u8, result.stdout, "\n")) try out.append(arena, '\n');
        try out.print(arena, "--- stderr ---\n{s}", .{result.stderr});
    }
    return .{ .text = out.items, .is_error = exit_code != 0 };
}

/// Mirror of `std.process.run` that spawns the child as a new process
/// group leader (`pgid: 0`) and, on every exit path, signals the whole
/// group via `kill(-pgid, SIGKILL)`. Without the group kill, child
/// processes the shell spawned (e.g. `sleep` in `sleep 30 && echo`)
/// get reparented and outlive the abort.
fn runBash(
    arena: std.mem.Allocator,
    io: Io,
    command: []const u8,
    timeout_ms: i64,
) !std.process.RunResult {
    // Run via bash with alias expansion + ~/.bashrc sourced when
    // available. Non-interactive bash normally skips both, so an
    // `alias git='hub'` in the user's bashrc wouldn't apply.
    //
    // Subtle: bash parses a `;`-joined compound command as a unit
    // before running any of it, so `shopt -s expand_aliases; .
    // ~/.bashrc; some_alias` doesn't actually pick up `some_alias`
    // — the parser has already resolved the third statement before
    // the alias is in the table. The fix is to pass the user's
    // command as a positional arg ($1) and `eval` it after the
    // setup runs; eval re-parses in a fresh scope that sees the
    // newly-defined aliases.
    //
    // Falls back to `/bin/sh -c` when bash isn't on PATH (Alpine
    // without bash, scratch images).
    const wrapper = "shopt -s expand_aliases 2>/dev/null; if [ -f ~/.bashrc ]; then . ~/.bashrc 2>/dev/null; fi; eval \"$1\"";
    const argv: []const []const u8 = if (bashAvailable())
        &[_][]const u8{ "/bin/bash", "-c", wrapper, "_", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };
    const timeout: Io.Timeout = if (timeout_ms <= 0) .none else .{
        .duration = .{
            .raw = Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        },
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0, // make the child its own process-group leader
    });
    const child_pid = child.id; // stash before wait clears it
    defer killGroup(child_pid);
    defer child.kill(io); // belt-and-suspenders; idempotent after wait

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);

    return .{
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
        .term = term,
    };
}

/// True when /bin/bash is executable. Cached after the first probe
/// because the answer doesn't change for the lifetime of the process.
fn bashAvailable() bool {
    const Cache = struct {
        var checked: bool = false;
        var has_bash: bool = false;
    };
    if (Cache.checked) return Cache.has_bash;
    Cache.checked = true;
    // F_OK probe via libc — std.fs in Zig 0.16 is Io-based and we
    // don't have an Io handle in this static context. libc access()
    // returns 0 on existing+visible, -1 otherwise.
    // POSIX F_OK = 0; just probe existence + executable.
    Cache.has_bash = std.c.access("/bin/bash", 0) == 0;
    return Cache.has_bash;
}

/// Send SIGKILL to a process group. Best-effort — silently ignores
/// errors so cleanup never panics.
fn killGroup(pid: ?std.posix.pid_t) void {
    const id = pid orelse return;
    if (id <= 0) return;
    // Negative PID means "this process group" in POSIX kill().
    _ = std.c.kill(-id, std.posix.SIG.KILL);
}

// ───────── worktree ─────────

const worktree_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "action":{"type":"string","enum":["add","list","remove"],"description":"Operation to perform."},
    \\   "path":{"type":"string","description":"Worktree path (required for add/remove)."},
    \\   "branch":{"type":"string","description":"Optional branch to check out (add only)."},
    \\   "force":{"type":"boolean","description":"Pass --force to remove."}
    \\ },
    \\ "required":["action"]}
;

pub fn buildWorktree(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, worktree_schema_json, .{});
    return .{
        .name = "worktree",
        .description = "Manage git worktrees. `action: add` creates one (optionally on a branch); `list` enumerates them; `remove` deletes one. Useful for isolating sub-agent work so parallel changes don't clobber each other.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = worktreeExecute,
    };
}

fn worktreeExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    if (settings.mode.refusesWrites()) {
        return errorOutput(arena, "worktree: refused — velk is in plan mode (read-only)", .{});
    }
    const action = (try getString(input, "action")) orelse return errorOutput(arena, "worktree: missing 'action'", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "worktree" });

    if (std.mem.eql(u8, action, "list")) {
        try argv.append(arena, "list");
    } else if (std.mem.eql(u8, action, "add")) {
        const path = (try getString(input, "path")) orelse return errorOutput(arena, "worktree: 'path' required for add", .{});
        try argv.append(arena, "add");
        try argv.append(arena, path);
        if (try getString(input, "branch")) |b| {
            try argv.append(arena, "-b");
            try argv.append(arena, b);
        }
    } else if (std.mem.eql(u8, action, "remove")) {
        const path = (try getString(input, "path")) orelse return errorOutput(arena, "worktree: 'path' required for remove", .{});
        try argv.append(arena, "remove");
        if (input == .object) {
            if (input.object.get("force")) |v| switch (v) {
                .bool => |b| if (b) try argv.append(arena, "--force"),
                else => {},
            };
        }
        try argv.append(arena, path);
    } else {
        return errorOutput(arena, "worktree: unknown action: {s}", .{action});
    }

    const result = std.process.run(settings.gpa, settings.io, .{ .argv = argv.items }) catch |e| {
        return errorOutput(arena, "worktree: spawn failed: {s}", .{@errorName(e)});
    };
    defer settings.gpa.free(result.stdout);
    defer settings.gpa.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "git worktree {s} (exit {d})\n", .{ action, exit_code });
    if (result.stdout.len > 0) try out.print(arena, "{s}", .{result.stdout});
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0 and !std.mem.endsWith(u8, result.stdout, "\n")) try out.append(arena, '\n');
        try out.print(arena, "[stderr] {s}", .{result.stderr});
    }
    return .{ .text = try arena.dupe(u8, out.items), .is_error = exit_code != 0 };
}

// ───────── write_plan (plan-mode exemption) ─────────

const write_plan_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "steps":{"type":"array","description":"Ordered list of steps. Each item is one short sentence.",
    \\     "items":{"type":"string"}},
    \\   "summary":{"type":"string","description":"Optional one-line summary that goes at the top of PLAN.md."}
    \\ },
    \\ "required":["steps"]}
;

pub fn buildWritePlan(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, write_plan_schema_json, .{});
    return .{
        .name = "write_plan",
        .description = "Write a checklist to PLAN.md. Use this in plan mode to commit to a sequence of steps before any other writes happen — `write_plan` is the *only* write tool exempt from plan-mode refusal. After PLAN.md is written, ask the user to switch to exec mode (the `/exec` slash command).",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = writePlanExecute,
    };
}

fn writePlanExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    // No plan-mode refusal here — write_plan is the exemption.

    const arr_v = switch (input) {
        .object => |o| o.get("steps") orelse return errorOutput(arena, "write_plan: missing 'steps'", .{}),
        else => return errorOutput(arena, "write_plan: input must be an object", .{}),
    };
    const arr = switch (arr_v) {
        .array => |a| a,
        else => return errorOutput(arena, "write_plan: 'steps' must be an array", .{}),
    };
    if (arr.items.len == 0) return errorOutput(arena, "write_plan: 'steps' must be non-empty", .{});

    const summary: ?[]const u8 = try getString(input, "summary");

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "# Plan\n\n");
    if (summary) |s| {
        try buf.print(arena, "{s}\n\n", .{s});
    }
    for (arr.items, 0..) |item, idx| {
        const text = switch (item) {
            .string => |s| s,
            else => return errorOutput(arena, "write_plan: steps[{d}] must be a string", .{idx}),
        };
        try buf.print(arena, "- [ ] {s}\n", .{text});
    }

    const path = "PLAN.md";
    Io.Dir.cwd().writeFile(settings.io, .{ .sub_path = path, .data = buf.items }) catch |e| {
        return errorOutput(arena, "write_plan: write failed: {s}", .{@errorName(e)});
    };

    const text = try std.fmt.allocPrint(
        arena,
        "wrote {s} ({d} step(s)). The user can review the plan; when ready they will run /exec to switch out of plan mode.",
        .{ path, arr.items.len },
    );
    return .{ .text = text };
}

// ───────── todo_write ─────────

const todo_write_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "todos":{"type":"array","description":"The full task list. Replaces any prior list.",
    \\     "items":{"type":"object",
    \\       "properties":{
    \\         "content":{"type":"string","description":"What needs to be done."},
    \\         "status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Current state."}
    \\       },
    \\       "required":["content","status"]}}
    \\ },
    \\ "required":["todos"]}
;

pub fn buildTodoWrite(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, todo_write_schema_json, .{});
    return .{
        .name = "todo_write",
        .description = "Replace the working todo list. Pass the full list every call (the previous list is discarded). Each item has `content` and `status` (pending|in_progress|completed). The user sees the list in the TUI; use it to track multi-step work.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = todoWriteExecute,
    };
}

fn todoWriteExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const store = settings.todos orelse return errorOutput(arena, "todo_write: no store wired (TUI-only feature)", .{});

    const arr_v = switch (input) {
        .object => |o| o.get("todos") orelse return errorOutput(arena, "todo_write: missing 'todos'", .{}),
        else => return errorOutput(arena, "todo_write: input must be an object", .{}),
    };
    const arr = switch (arr_v) {
        .array => |a| a,
        else => return errorOutput(arena, "todo_write: 'todos' must be an array", .{}),
    };

    var built: std.ArrayList(todos_mod.Item) = .empty;
    for (arr.items, 0..) |item, idx| {
        const obj = switch (item) {
            .object => |o| o,
            else => return errorOutput(arena, "todo_write: todos[{d}] must be an object", .{idx}),
        };
        const content_v = obj.get("content") orelse return errorOutput(arena, "todo_write: todos[{d}].content missing", .{idx});
        const content = switch (content_v) {
            .string => |s| s,
            else => return errorOutput(arena, "todo_write: todos[{d}].content must be a string", .{idx}),
        };
        const status_str: []const u8 = blk: {
            const v = obj.get("status") orelse break :blk "pending";
            break :blk switch (v) {
                .string => |s| s,
                else => return errorOutput(arena, "todo_write: todos[{d}].status must be a string", .{idx}),
            };
        };
        const status = todos_mod.Status.fromString(status_str) orelse
            return errorOutput(arena, "todo_write: todos[{d}].status invalid: {s}", .{ idx, status_str });
        try built.append(arena, .{ .content = content, .status = status });
    }

    try store.set(settings.io, built.items);

    // Render a compact summary back to the model so it can re-cite
    // the list without re-emitting it. Format: one line per item,
    // glyph + content.
    var out: std.ArrayList(u8) = .empty;
    if (built.items.len == 0) {
        try out.appendSlice(arena, "todo list cleared.");
    } else {
        try out.print(arena, "todo list updated ({d} item(s)):\n", .{built.items.len});
        for (built.items) |it| {
            try out.print(arena, "{s} {s}\n", .{ it.status.glyph(), it.content });
        }
    }
    return .{ .text = out.items };
}

// ───────── task (sub-agent) ─────────

const task_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "prompt":{"type":"string","description":"The instructions for the sub-agent. The sub-agent has its own message history and runs to completion before returning."},
    \\   "tools":{"type":"array","description":"Optional. Names of parent tools the child is allowed to call. When omitted, the child inherits the full registry minus `task` itself.",
    \\     "items":{"type":"string"}},
    \\   "model":{"type":"string","description":"Optional. Run the child with this model id instead of the sub-agent default. Use to delegate reasoning-heavy work to a more capable (and expensive) model — e.g. `model='claude-opus-4-7'` from a Haiku parent."}
    \\ },
    \\ "required":["prompt"]}
;

pub fn buildTask(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, task_schema_json, .{});
    return .{
        .name = "task",
        .description = "Spawn a sub-agent with isolated context. Pass a `prompt` (and optionally a `tools` allowlist by name); the sub-agent runs the agent loop with its own fresh message history and returns the final assistant text. Use for self-contained sub-tasks where you don't want to pollute the main conversation. Sub-agents do not nest — `task` is excluded from the child's tool set.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = taskExecute,
    };
}

fn taskExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const sub = settings.sub_agent orelse return errorOutput(arena, "task: no sub-agent runtime configured", .{});

    const prompt = (try getString(input, "prompt")) orelse return errorOutput(arena, "task: missing 'prompt'", .{});

    // Build the child's tool set: parent's registry minus `task`,
    // optionally filtered by the caller's allowlist.
    var allow: ?[]const []const u8 = null;
    if (input == .object) {
        if (input.object.get("tools")) |v| switch (v) {
            .array => |a| {
                var names = try arena.alloc([]const u8, a.items.len);
                for (a.items, 0..) |item, i| {
                    names[i] = switch (item) {
                        .string => |s| s,
                        else => return errorOutput(arena, "task: tools[{d}] must be a string", .{i}),
                    };
                }
                allow = names;
            },
            else => return errorOutput(arena, "task: 'tools' must be an array", .{}),
        };
    }

    var child_tools: std.ArrayList(tool.Tool) = .empty;
    for (sub.tools) |t| {
        if (std.mem.eql(u8, t.name, "task")) continue;
        if (allow) |names| {
            var matched = false;
            for (names) |n| if (std.mem.eql(u8, t.name, n)) {
                matched = true;
                break;
            };
            if (!matched) continue;
        }
        try child_tools.append(arena, t);
    }

    // The child runs synchronously on this same worker thread.
    // We capture its final assistant text via a SilentSink so the
    // parent's UI doesn't receive interleaved deltas — only the
    // final result (returned as the tool's Output) lands.
    var capture: ChildCapture = .{};
    const sink: agent_mod.Sink = .{
        .ctx = &capture,
        .onText = ChildCapture.onText,
        .onToolCall = ChildCapture.onToolCall,
        .onToolResult = ChildCapture.onToolResult,
        .onTurnEnd = ChildCapture.onTurnEnd,
    };

    const child_arena = arena; // child shares this turn's arena
    capture.arena = child_arena;

    // Per-call model override. Falls back to the sub-agent default
    // (which `--planner-model` sets at startup, otherwise inherits
    // the parent's model).
    const child_model: []const u8 = (try getString(input, "model")) orelse sub.model;

    _ = agent_mod.run(child_arena, sub.provider, sink, .{
        .model = child_model,
        .max_tokens = sub.max_tokens,
        .system = sub.system,
        .prompt = prompt,
        .tools = child_tools.items,
        .max_iterations = sub.max_iterations,
        .hook_engine = sub.hook_engine,
        .hook_gpa = settings.gpa,
        .hook_io = sub.hook_io,
    }) catch |e| {
        return errorOutput(arena, "task: child agent failed: {s}", .{@errorName(e)});
    };

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "task complete ({d} tool call(s) across {d} iteration(s))\n\n", .{
        capture.tool_calls,
        capture.iterations,
    });
    if (capture.final_text.items.len > 0) {
        try out.appendSlice(arena, capture.final_text.items);
    } else {
        try out.appendSlice(arena, "(no final text produced)");
    }
    return .{ .text = out.items };
}

const ChildCapture = struct {
    arena: std.mem.Allocator = undefined,
    final_text: std.ArrayList(u8) = .empty,
    tool_calls: u32 = 0,
    iterations: u32 = 0,

    fn cast(ctx: ?*anyopaque) *ChildCapture {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = cast(ctx);
        try self.final_text.appendSlice(self.arena, text);
    }
    fn onToolCall(ctx: ?*anyopaque, _: []const u8, _: []const u8) anyerror!void {
        const self = cast(ctx);
        self.tool_calls +|= 1;
        // A new tool call means the previous "final text" was just
        // intermediate prose — clear it so we end with the truly
        // final assistant text.
        self.final_text.clearRetainingCapacity();
    }
    fn onToolResult(_: ?*anyopaque, _: []const u8, _: bool) anyerror!void {
        return;
    }
    fn onTurnEnd(ctx: ?*anyopaque, _: provider_mod.Usage) anyerror!void {
        const self = cast(ctx);
        self.iterations +|= 1;
    }
};

// ───────── team (parallel coordinator) ─────────

const team_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "tasks":{"type":"array","description":"Independent sub-tasks to run in parallel. Each item has a `prompt` and optional `tools` allowlist.",
    \\     "items":{"type":"object",
    \\       "properties":{
    \\         "prompt":{"type":"string"},
    \\         "label":{"type":"string","description":"Optional human label to identify the task in the result. Defaults to 'task-N'."},
    \\         "tools":{"type":"array","items":{"type":"string"}}
    \\       },
    \\       "required":["prompt"]}}
    \\ },
    \\ "required":["tasks"]}
;

pub fn buildTeam(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, team_schema_json, .{});
    return .{
        .name = "team",
        .description = "Fan out work to multiple sub-agents in parallel. Pass `tasks` as an array of `{prompt, label?, tools?}`; each runs as an isolated child agent (same provider/model) and the results are aggregated under their labels. Children share the parent registry minus `task` and `team` (no nesting in v1). Use this when N sub-tasks are independent and you want them to overlap rather than running serially via repeated `task` calls.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = teamExecute,
    };
}

const TeamChild = struct {
    label: []const u8,
    prompt: []const u8,
    /// Per-child arena. Allocated on the parent gpa (NOT the parent
    /// turn arena) so concurrent allocations from different threads
    /// don't race the shared parent allocator. Owned by `teamExecute`
    /// — deinited at the end of the call.
    arena: *std.heap.ArenaAllocator,
    capture: ChildCapture,
    err: ?anyerror = null,
};

fn teamExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const sub = settings.sub_agent orelse return errorOutput(arena, "team: no sub-agent runtime configured", .{});

    const arr_v = switch (input) {
        .object => |o| o.get("tasks") orelse return errorOutput(arena, "team: missing 'tasks'", .{}),
        else => return errorOutput(arena, "team: input must be an object", .{}),
    };
    const arr = switch (arr_v) {
        .array => |a| a,
        else => return errorOutput(arena, "team: 'tasks' must be an array", .{}),
    };
    if (arr.items.len == 0) return errorOutput(arena, "team: 'tasks' must be non-empty", .{});
    if (arr.items.len > 8) return errorOutput(arena, "team: at most 8 parallel tasks supported", .{});

    // Build per-task state up front so we have stable pointers for
    // the futures to write into. Each child owns a private arena
    // (gpa-backed) so concurrent allocations don't race a shared
    // parent allocator.
    var children = try arena.alloc(TeamChild, arr.items.len);
    var per_task_tools = try arena.alloc([]const tool.Tool, arr.items.len);
    defer for (children) |c| {
        c.arena.deinit();
        settings.gpa.destroy(c.arena);
    };
    for (arr.items, 0..) |item, idx| {
        const obj = switch (item) {
            .object => |o| o,
            else => return errorOutput(arena, "team: tasks[{d}] must be an object", .{idx}),
        };
        const prompt_v = obj.get("prompt") orelse return errorOutput(arena, "team: tasks[{d}].prompt missing", .{idx});
        const prompt = switch (prompt_v) {
            .string => |s| s,
            else => return errorOutput(arena, "team: tasks[{d}].prompt must be a string", .{idx}),
        };
        const label: []const u8 = blk: {
            const v = obj.get("label") orelse break :blk try std.fmt.allocPrint(arena, "task-{d}", .{idx + 1});
            break :blk switch (v) {
                .string => |s| s,
                else => return errorOutput(arena, "team: tasks[{d}].label must be a string", .{idx}),
            };
        };

        // Per-task tools allowlist filter — same rules as `task`,
        // plus we exclude `team` itself to prevent recursion.
        var allow: ?[]const []const u8 = null;
        if (obj.get("tools")) |tv| switch (tv) {
            .array => |a| {
                var names = try arena.alloc([]const u8, a.items.len);
                for (a.items, 0..) |item2, j| {
                    names[j] = switch (item2) {
                        .string => |s| s,
                        else => return errorOutput(arena, "team: tasks[{d}].tools[{d}] must be a string", .{ idx, j }),
                    };
                }
                allow = names;
            },
            else => return errorOutput(arena, "team: tasks[{d}].tools must be an array", .{idx}),
        };

        var tlist: std.ArrayList(tool.Tool) = .empty;
        for (sub.tools) |t| {
            if (std.mem.eql(u8, t.name, "task")) continue;
            if (std.mem.eql(u8, t.name, "team")) continue;
            if (allow) |names| {
                var matched = false;
                for (names) |n| if (std.mem.eql(u8, t.name, n)) {
                    matched = true;
                    break;
                };
                if (!matched) continue;
            }
            try tlist.append(arena, t);
        }
        per_task_tools[idx] = tlist.items;

        const child_arena = try settings.gpa.create(std.heap.ArenaAllocator);
        child_arena.* = .init(settings.gpa);
        children[idx] = .{
            .label = label,
            .prompt = prompt,
            .arena = child_arena,
            .capture = .{ .arena = child_arena.allocator() },
        };
    }

    // Spawn each child concurrently and collect futures. We unwind
    // properly even on partial-spawn failure.
    var futures: std.ArrayList(Io.Future(anyerror!void)) = .empty;
    defer for (futures.items) |*f| {
        _ = f.await(settings.io) catch {};
    };
    for (children, per_task_tools) |*child, child_tools| {
        const f = try Io.concurrent(settings.io, runTeamChild, .{ sub, child, child_tools, settings.gpa });
        try futures.append(arena, f);
    }
    // Now drain — the defer above also awaits, but we want to
    // capture per-child errors on the happy path here.
    for (futures.items, 0..) |*f, i| {
        const r = f.await(settings.io);
        if (r) |_| {} else |e| {
            children[i].err = e;
        }
    }
    futures.clearRetainingCapacity();

    // Aggregate results into a labelled markdown report.
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "team complete ({d} task(s)):\n\n", .{children.len});
    for (children) |c| {
        try out.print(arena, "## {s}\n", .{c.label});
        if (c.err) |e| {
            try out.print(arena, "_failed: {s}_\n\n", .{@errorName(e)});
            continue;
        }
        try out.print(
            arena,
            "_({d} tool call(s) across {d} iteration(s))_\n\n",
            .{ c.capture.tool_calls, c.capture.iterations },
        );
        if (c.capture.final_text.items.len > 0) {
            try out.appendSlice(arena, c.capture.final_text.items);
        } else {
            try out.appendSlice(arena, "_(no final text produced)_");
        }
        try out.appendSlice(arena, "\n\n");
    }
    return .{ .text = out.items };
}

fn runTeamChild(
    sub: *const SubAgent,
    child: *TeamChild,
    child_tools: []const tool.Tool,
    gpa: std.mem.Allocator,
) anyerror!void {
    const sink: agent_mod.Sink = .{
        .ctx = &child.capture,
        .onText = ChildCapture.onText,
        .onToolCall = ChildCapture.onToolCall,
        .onToolResult = ChildCapture.onToolResult,
        .onTurnEnd = ChildCapture.onTurnEnd,
    };
    // Use the child's private arena so agent.run's per-turn
    // allocations (messages, tool defs, deltas) don't race other
    // children allocating off a shared parent allocator.
    _ = try agent_mod.run(child.arena.allocator(), sub.provider, sink, .{
        .model = sub.model,
        .max_tokens = sub.max_tokens,
        .system = sub.system,
        .prompt = child.prompt,
        .tools = child_tools,
        .max_iterations = sub.max_iterations,
        .hook_engine = sub.hook_engine,
        .hook_gpa = gpa,
        .hook_io = sub.hook_io,
    });
}

// ───────── ask_user_question ─────────

const ask_user_question_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "question":{"type":"string","description":"The question to put to the user. One short sentence."},
    \\   "options":{"type":"array","description":"Numbered choices. The user picks one by number (1-9). Up to 9.",
    \\     "items":{"type":"string"}}
    \\ },
    \\ "required":["question","options"]}
;

pub fn buildAskUserQuestion(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, ask_user_question_schema_json, .{});
    return .{
        .name = "ask_user_question",
        .description = "Ask the user a structured multiple-choice question. Pass a question and a list of options (max 9). Blocks until the user picks one. Returns the selected option text. Use sparingly — only when you genuinely cannot proceed without the user's input.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = askUserQuestionExecute,
    };
}

fn askUserQuestionExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const gate = settings.ask orelse return errorOutput(arena, "ask_user_question: no UI gate (TUI-only)", .{});

    const question = (try getString(input, "question")) orelse return errorOutput(arena, "ask_user_question: missing 'question'", .{});

    const arr_v = switch (input) {
        .object => |o| o.get("options") orelse return errorOutput(arena, "ask_user_question: missing 'options'", .{}),
        else => return errorOutput(arena, "ask_user_question: input must be an object", .{}),
    };
    const arr = switch (arr_v) {
        .array => |a| a,
        else => return errorOutput(arena, "ask_user_question: 'options' must be an array", .{}),
    };
    if (arr.items.len == 0) return errorOutput(arena, "ask_user_question: 'options' must be non-empty", .{});
    if (arr.items.len > 9) return errorOutput(arena, "ask_user_question: at most 9 options supported", .{});

    // Strings handed to the gate live on `gpa` because the TUI
    // outlives this arena turn (Block.text takes a copy when we
    // pushBlock, but the gate-side Request is held until deliver).
    const q_dup = try settings.gpa.dupe(u8, question);
    const opts = try settings.gpa.alloc([]const u8, arr.items.len);
    var built: usize = 0;
    errdefer {
        settings.gpa.free(@constCast(q_dup));
        for (opts[0..built]) |o| settings.gpa.free(@constCast(o));
        settings.gpa.free(opts);
    }
    for (arr.items, 0..) |item, i| {
        const s = switch (item) {
            .string => |x| x,
            else => return errorOutput(arena, "ask_user_question: options[{d}] must be a string", .{i}),
        };
        opts[i] = try settings.gpa.dupe(u8, s);
        built = i + 1;
    }

    const r = try gate.ask(q_dup, opts);
    switch (r) {
        .selected => |idx| {
            // The gate has freed the request; we have only the
            // arena-borrowed copy of the input options.
            const choice = switch (arr.items[idx]) {
                .string => |s| s,
                else => "?",
            };
            const text = try std.fmt.allocPrint(arena, "user selected: {s}", .{choice});
            return .{ .text = text };
        },
        .canceled => return errorOutput(arena, "ask_user_question: canceled by user", .{}),
    }
}

// ───────── shared input helpers ─────────

fn getString(value: std.json.Value, field: []const u8) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(value: std.json.Value, field: []const u8) !?i64 {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

// ───────── view_image ─────────

const view_image_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "path":{"type":"string","description":"Path to an image file (PNG, JPEG, GIF, or WebP). Must be inside CWD unless --unsafe."}
    \\ },
    \\ "required":["path"]}
;

pub fn buildViewImage(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, view_image_schema_json, .{});
    return .{
        .name = "view_image",
        .description = "Read an image file and attach it to your next message as a vision input. Use this when you need to see what's in a PNG/JPEG/GIF/WebP file (chess boards, diagrams, screenshots, charts, etc.). The model receives the image alongside the text response and can analyze it directly.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = viewImageExecute,
    };
}

fn viewImageExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const path = (try getString(input, "path")) orelse return errorOutput(arena, "view_image: missing 'path'", .{});

    _ = validatePath(settings, path) catch {
        return errorOutput(arena, "view_image: refused — path '{s}' is outside CWD (use --unsafe to override)", .{path});
    };

    const max_image_bytes: usize = 5 * 1024 * 1024; // 5 MiB
    const cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(settings.io, path, arena, .limited(max_image_bytes)) catch |e| switch (e) {
        error.FileNotFound => return errorOutput(arena, "view_image: '{s}' not found", .{path}),
        error.StreamTooLong => return errorOutput(arena, "view_image: '{s}' larger than 5 MiB cap", .{path}),
        else => return errorOutput(arena, "view_image: read failed: {s}", .{@errorName(e)}),
    };

    // Sniff the media type from the file's magic bytes. Falling back
    // to the file extension would be wrong for files with the wrong
    // suffix, and Anthropic / OpenAI care about the right media_type.
    const media_type = sniffImageMediaType(bytes) orelse
        return errorOutput(arena, "view_image: '{s}' isn't a recognized image (PNG/JPEG/GIF/WebP)", .{path});

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(bytes.len);
    const buf = try arena.alloc(u8, encoded_len);
    _ = encoder.encode(buf, bytes);

    const text = try std.fmt.allocPrint(arena, "Attached {s} ({d} bytes) from {s}", .{ media_type, bytes.len, path });
    return .{
        .text = text,
        .image = .{ .media_type = media_type, .base64_data = buf },
        .is_error = false,
    };
}

/// Returns the IANA media type for a recognized image, or null when
/// the bytes don't look like a supported format. Both Anthropic and
/// OpenAI accept the four formats below.
fn sniffImageMediaType(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff")) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

// ───────── lsp_diagnostics ─────────

const lsp_mod = @import("lsp.zig");

const lsp_diagnostics_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "file":{"type":"string","description":"Path to a source file in the project. The LSP server is selected by file extension via settings.json `lsp.servers`."},
    \\   "timeout_ms":{"type":"integer","description":"Optional. How long to wait for the server's first publishDiagnostics. Default 5000."}
    \\ },
    \\ "required":["file"]}
;

pub fn buildLspDiagnostics(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, lsp_diagnostics_schema_json, .{});
    return .{
        .name = "lsp_diagnostics",
        .description = "Get LSP-reported diagnostics (errors, warnings, hints) for a source file. Spawns the project's configured LSP server (settings.json `lsp.servers[<ext>]`), opens the file, and waits for the first publishDiagnostics. Use to surface real compile/lint errors instead of guessing.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = lspDiagnosticsExecute,
    };
}

fn lspDiagnosticsExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const file = (try getString(input, "file")) orelse return errorOutput(arena, "lsp_diagnostics: missing 'file'", .{});
    const timeout_ms: u64 = @intCast(@as(i64, (try getInt(input, "timeout_ms")) orelse 5000));

    // Path safety: same lexical check the other file tools use.
    _ = validatePath(settings, file) catch {
        return errorOutput(arena, "lsp_diagnostics: refused — path '{s}' is outside CWD (use --unsafe to override)", .{file});
    };

    // Find the configured server by extension.
    const ext = std.fs.path.extension(file);
    if (ext.len == 0) return errorOutput(arena, "lsp_diagnostics: file '{s}' has no extension", .{file});
    const server: LspServerConfig = blk: {
        for (settings.lsp_servers) |s| {
            if (std.mem.eql(u8, s.extension, ext)) break :blk s;
        }
        return errorOutput(arena, "lsp_diagnostics: no LSP server configured for '{s}' — add `lsp.servers` entry to settings.json", .{ext});
    };

    // Read the file body so we can send it in didOpen (avoids the
    // server doing its own disk read of a path it might not be able
    // to find e.g. under sandboxed CI).
    const cwd = std.Io.Dir.cwd();
    const body = cwd.readFileAlloc(settings.io, file, arena, .limited(max_file_bytes)) catch |e|
        return errorOutput(arena, "lsp_diagnostics: read failed: {s}", .{@errorName(e)});

    // Resolve workspace root to an absolute path. Std 0.16 lacks an
    // Io.Dir.realpathAlloc / process.getCwdAlloc; libc getcwd is the
    // shortest path. LSP servers use this for project-wide config
    // discovery.
    const root_abs = blk: {
        var buf: [4096]u8 = undefined;
        const ptr = std.c.getcwd(&buf, buf.len) orelse
            return errorOutput(arena, "lsp_diagnostics: getcwd failed", .{});
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        _ = ptr;
        break :blk try arena.dupe(u8, buf[0..len]);
    };

    // The file URI must be absolute. If the user passed an absolute
    // path, use it directly; otherwise join CWD + file.
    const file_abs: []const u8 = if (std.fs.path.isAbsolute(file))
        file
    else
        try std.fs.path.join(arena, &.{ root_abs, file });

    // Tokenize the configured command on whitespace. The same
    // limitation the bash + custom-tool wrappers have: no quoted
    // args, no env-substitution. Surrounding shell still strips
    // outer quotes.
    var argv: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeAny(u8, server.command, " \t");
    while (iter.next()) |part| try argv.append(arena, part);
    if (argv.items.len == 0) return errorOutput(arena, "lsp_diagnostics: empty command for '{s}'", .{ext});

    const gpa = settings.gpa;
    const client = lsp_mod.Client.start(gpa, settings.io, argv.items, root_abs) catch |e|
        return errorOutput(arena, "lsp_diagnostics: spawn '{s}' failed: {s}", .{ server.command, @errorName(e) });
    defer client.deinit();

    const diags = client.diagnostics(arena, file_abs, server.language_id, body, timeout_ms) catch |e| switch (e) {
        error.Timeout => return errorOutput(arena, "lsp_diagnostics: timed out after {d}ms waiting for diagnostics", .{timeout_ms}),
        else => return errorOutput(arena, "lsp_diagnostics: query failed: {s}", .{@errorName(e)}),
    };

    if (diags.len == 0) {
        return .{ .text = "(no diagnostics reported)", .is_error = false };
    }

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{d} diagnostic(s) for {s}:\n", .{ diags.len, file });
    for (diags) |d| {
        try out.print(arena, "  [{s}] {s}:{d}:{d}: {s}\n", .{ d.severity, file, d.line + 1, d.col + 1, d.message });
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return .{ .text = out.items, .is_error = false };
}

// ───────── memory (memdir) ─────────

const memory = @import("memory.zig");

const read_memory_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "topic":{"type":"string","description":"Slug of the topic to read. Omit to get a list of all stored topics with sizes."}
    \\ }}
;

const write_memory_schema_json: []const u8 =
    \\{"type":"object",
    \\ "properties":{
    \\   "topic":{"type":"string","description":"Topic name. Will be slugified to filename-safe form."},
    \\   "content":{"type":"string","description":"Markdown body to store. Overwrites any prior content under this topic."}
    \\ },
    \\ "required":["topic","content"]}
;

pub fn buildReadMemory(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, read_memory_schema_json, .{});
    return .{
        .name = "read_memory",
        .description = "Read persistent memory across velk sessions. With no `topic`, returns a catalog of all stored topics; with one, returns that topic's body. Memory lives at $XDG_DATA_HOME/velk/memdir/<topic>.md.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = readMemoryExecute,
    };
}

fn readMemoryExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    const topic_in = try getString(input, "topic");
    if (topic_in) |raw| {
        const env = settings.env_map orelse return errorOutput(arena, "read_memory: env_map not wired", .{});
        const slug = memory.slugify(arena, raw) catch
            return errorOutput(arena, "read_memory: topic '{s}' contains nothing storable", .{raw});
        const body = memory.read(arena, settings.io, env, slug) catch |e|
            return errorOutput(arena, "read_memory: read failed: {s}", .{@errorName(e)});
        if (body == null) {
            return .{
                .text = try std.fmt.allocPrint(arena, "(no memory stored under '{s}')", .{slug}),
                .is_error = false,
            };
        }
        return .{ .text = body.?, .is_error = false };
    }
    const env2 = settings.env_map orelse return errorOutput(arena, "read_memory: env_map not wired", .{});
    const entries = memory.list(arena, settings.io, env2) catch |e|
        return errorOutput(arena, "read_memory: list failed: {s}", .{@errorName(e)});
    if (entries.len == 0) {
        return .{ .text = "(no memory stored yet — call write_memory to start)", .is_error = false };
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "{d} stored topic(s):\n", .{entries.len});
    for (entries) |e| {
        try buf.print(arena, "  {s} ({d} bytes)\n", .{ e.topic, e.bytes });
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') _ = buf.pop();
    return .{ .text = buf.items, .is_error = false };
}

pub fn buildWriteMemory(arena: std.mem.Allocator, settings: *const Settings) !tool.Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, write_memory_schema_json, .{});
    return .{
        .name = "write_memory",
        .description = "Persist a markdown note across velk sessions. Stored at $XDG_DATA_HOME/velk/memdir/<topic>.md; overwrites any prior content under this topic. Use for facts, decisions, or context that should survive `/clear` and process restarts.",
        .input_schema = schema,
        .context = @constCast(@ptrCast(settings)),
        .execute = writeMemoryExecute,
    };
}

fn writeMemoryExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const settings = settingsFromCtx(ctx);
    if (settings.mode.refusesWrites()) {
        return errorOutput(arena, "write_memory: refused — velk is in plan mode (read-only)", .{});
    }
    const raw_topic = (try getString(input, "topic")) orelse return errorOutput(arena, "write_memory: missing 'topic'", .{});
    const content = (try getString(input, "content")) orelse return errorOutput(arena, "write_memory: missing 'content'", .{});
    const slug = memory.slugify(arena, raw_topic) catch
        return errorOutput(arena, "write_memory: topic '{s}' contains nothing storable", .{raw_topic});
    const env = settings.env_map orelse return errorOutput(arena, "write_memory: env_map not wired", .{});
    memory.write(arena, settings.io, env, slug, content) catch |e|
        return errorOutput(arena, "write_memory: write failed: {s}", .{@errorName(e)});
    return .{
        .text = try std.fmt.allocPrint(arena, "wrote {d} byte(s) to memory topic '{s}'", .{ content.len, slug }),
        .is_error = false,
    };
}

// ───────── custom shell tool ─────────

/// Spec for a user-declared shell tool. A new `tool.Tool` is built
/// per spec at startup; the tool's input schema is empty (v1 has no
/// argument substitution). Refused under plan mode like `bash`.
pub const CustomToolDef = struct {
    name: []const u8,
    description: []const u8,
    command: []const u8,
};

/// Per-tool context — the registry's tool slot points at this. It
/// outlives the call so the closure-captured fields stay valid.
const CustomToolCtx = struct {
    settings: *const Settings,
    spec: CustomToolDef,
};

const custom_schema_json: []const u8 =
    \\{"type":"object","properties":{},"additionalProperties":false}
;

pub fn buildCustom(
    arena: std.mem.Allocator,
    settings: *const Settings,
    spec: CustomToolDef,
) !tool.Tool {
    const ctx = try arena.create(CustomToolCtx);
    ctx.* = .{ .settings = settings, .spec = spec };
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, custom_schema_json, .{});
    return .{
        .name = spec.name,
        .description = spec.description,
        .input_schema = schema,
        .context = ctx,
        .execute = customExecute,
    };
}

fn customExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, _: std.json.Value) anyerror!tool.Output {
    const c: *const CustomToolCtx = @ptrCast(@alignCast(ctx.?));
    if (c.settings.mode.refusesWrites()) {
        return errorOutput(arena, "{s}: refused — velk is in plan mode (read-only)", .{c.spec.name});
    }
    const result = runBash(arena, c.settings.io, c.spec.command, default_bash_timeout_ms) catch |e| switch (e) {
        error.Timeout => return errorOutput(arena, "{s}: timed out after {d}ms", .{ c.spec.name, default_bash_timeout_ms }),
        error.Canceled => return errorOutput(arena, "{s}: aborted", .{c.spec.name}),
        else => return errorOutput(arena, "{s}: spawn failed: {s}", .{ c.spec.name, @errorName(e) }),
    };
    const exit_code: i32 = switch (result.term) {
        .exited => |code| @intCast(code),
        .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
        else => -1,
    };
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "exit: {d}\n", .{exit_code});
    if (result.stdout.len > 0) try out.print(arena, "--- stdout ---\n{s}", .{result.stdout});
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0 and !std.mem.endsWith(u8, result.stdout, "\n")) try out.append(arena, '\n');
        try out.print(arena, "--- stderr ---\n{s}", .{result.stderr});
    }
    return .{ .text = out.items, .is_error = exit_code != 0 };
}

// ───────── tests ─────────

const testing = std.testing;

fn jsonObj(a: std.mem.Allocator, kv: anytype) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    inline for (std.meta.fields(@TypeOf(kv))) |f| {
        const v = @field(kv, f.name);
        const json_v: std.json.Value = switch (@TypeOf(v)) {
            []const u8 => .{ .string = v },
            comptime_int => .{ .integer = v },
            else => @compileError("unsupported test arg type for " ++ f.name),
        };
        try obj.put(a, f.name, json_v);
    }
    return .{ .object = obj };
}

fn testSettings() Settings {
    return .{ .io = testing.io, .unsafe = true };
}

test "validatePath: refuses absolute path in safe mode" {
    const settings: Settings = .{ .io = testing.io, .unsafe = false };
    try testing.expectError(Error.PathOutsideCwd, validatePath(&settings, "/etc/passwd"));
}

test "validatePath: refuses .. that escapes" {
    const settings: Settings = .{ .io = testing.io, .unsafe = false };
    try testing.expectError(Error.PathOutsideCwd, validatePath(&settings, "../etc/passwd"));
    try testing.expectError(Error.PathOutsideCwd, validatePath(&settings, "a/../../b"));
}

test "validatePath: allows .. that stays inside" {
    const settings: Settings = .{ .io = testing.io, .unsafe = false };
    _ = try validatePath(&settings, "a/b/../c");
}

test "validatePath: allows anything in unsafe mode" {
    const settings: Settings = .{ .io = testing.io, .unsafe = true };
    _ = try validatePath(&settings, "/etc/passwd");
    _ = try validatePath(&settings, "../../../escape");
}

test "read_file + write_file roundtrip in tmp dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fs.path.join(a, &.{ tmp_path, "hello.txt" });

    const wf = try buildWriteFile(a, &settings);
    const rf = try buildReadFile(a, &settings);

    const wf_input = try jsonObj(a, .{ .path = @as([]const u8, file_path), .content = @as([]const u8, "hello world\n") });
    const wf_out = try wf.execute(@constCast(@ptrCast(&settings)), a, wf_input);
    try testing.expect(!wf_out.is_error);

    const rf_input = try jsonObj(a, .{ .path = @as([]const u8, file_path) });
    const rf_out = try rf.execute(@constCast(@ptrCast(&settings)), a, rf_input);
    try testing.expectEqualStrings("hello world\n", rf_out.text);
}

test "edit: replaces unique match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fs.path.join(a, &.{ tmp_path, "edit.txt" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "edit.txt", .data = "before middle after\n" });

    const ed = try buildEdit(a, &settings);
    const input = try jsonObj(a, .{
        .path = @as([]const u8, file_path),
        .old_string = @as([]const u8, "middle"),
        .new_string = @as([]const u8, "MIDDLE"),
    });
    const out = try ed.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);

    const after = try tmp.dir.readFileAlloc(testing.io, "edit.txt", a, .limited(1024));
    try testing.expectEqualStrings("before MIDDLE after\n", after);
}

test "edit: errors when match is non-unique" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fs.path.join(a, &.{ tmp_path, "dup.txt" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dup.txt", .data = "x x\n" });

    const ed = try buildEdit(a, &settings);
    const input = try jsonObj(a, .{
        .path = @as([]const u8, file_path),
        .old_string = @as([]const u8, "x"),
        .new_string = @as([]const u8, "y"),
    });
    const out = try ed.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "more than once") != null);
}

test "bash: captures stdout and exit code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const b = try buildBash(a, &settings);
    const input = try jsonObj(a, .{ .command = @as([]const u8, "echo hi") });
    const out = try b.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "exit: 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "hi") != null);
}

test "custom: shells out to its configured command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const t = try buildCustom(a, &settings, .{
        .name = "say-hi",
        .description = "echoes a known marker",
        .command = "echo custom-tool-marker",
    });
    const empty: std.json.ObjectMap = .empty;
    const out = try t.execute(t.context, a, .{ .object = empty });
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "exit: 0") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "custom-tool-marker") != null);
}

test "custom: refused under plan mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings = testSettings();
    settings.mode = .plan;
    const t = try buildCustom(a, &settings, .{
        .name = "writes-something",
        .description = "would write but plan mode refuses",
        .command = "echo should-not-run",
    });
    const empty: std.json.ObjectMap = .empty;
    const out = try t.execute(t.context, a, .{ .object = empty });
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "plan mode") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "writes-something") != null);
}

test "view_image: missing path is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildViewImage(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'path'") != null);
}

test "view_image: non-image bytes rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "fake.png", .data = "not an image" });

    var settings = testSettings();
    settings.unsafe = true;
    const t = try buildViewImage(a, &settings);
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fmt.allocPrint(a, "{s}/fake.png", .{tmp_abs});
    const input = try jsonObj(a, .{ .path = file_path });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "isn't a recognized image") != null);
}

test "view_image: PNG magic bytes detected and base64-encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Minimal PNG: signature + IHDR (1x1 RGBA) + IDAT + IEND. We
    // don't need a valid image, just one that passes our magic-byte
    // check.
    const png_bytes = "\x89PNG\r\n\x1a\n" ++ ("data" ** 4);
    try tmp.dir.writeFile(.{ .sub_path = "tiny.png", .data = png_bytes });

    var settings = testSettings();
    settings.unsafe = true;
    const t = try buildViewImage(a, &settings);
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fmt.allocPrint(a, "{s}/tiny.png", .{tmp_abs});
    const input = try jsonObj(a, .{ .path = file_path });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "image/png") != null);
    try testing.expect(out.image != null);
    try testing.expectEqualStrings("image/png", out.image.?.media_type);
    // Round-trip the base64 to verify it encodes cleanly.
    const decoded = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(out.image.?.base64_data) catch unreachable);
    try std.base64.standard.Decoder.decode(decoded, out.image.?.base64_data);
    try testing.expectEqualSlices(u8, png_bytes, decoded);
}

test "sniffImageMediaType: detects all four supported formats" {
    try testing.expectEqualStrings("image/png", sniffImageMediaType("\x89PNG\r\n\x1a\nrest").?);
    try testing.expectEqualStrings("image/jpeg", sniffImageMediaType("\xff\xd8\xff\xe0blob").?);
    try testing.expectEqualStrings("image/gif", sniffImageMediaType("GIF89a...").?);
    try testing.expectEqualStrings("image/gif", sniffImageMediaType("GIF87a...").?);
    try testing.expectEqualStrings("image/webp", sniffImageMediaType("RIFF\x00\x00\x00\x00WEBPVP8X").?);
    try testing.expectEqual(@as(?[]const u8, null), sniffImageMediaType("not magic"));
    try testing.expectEqual(@as(?[]const u8, null), sniffImageMediaType(""));
}

test "lsp_diagnostics: missing file is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildLspDiagnostics(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'file'") != null);
}

test "lsp_diagnostics: file without extension is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildLspDiagnostics(a, &settings);
    const input = try jsonObj(a, .{ .file = @as([]const u8, "Makefile") });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "no extension") != null);
}

test "lsp_diagnostics: end-to-end against a fake server" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Skip if python3 isn't available or the fake server file is
    // missing — the test harness shouldn't fail in those envs.
    const fake = "scripts/fake-lsp.py";
    std.fs.cwd().access(fake, .{}) catch return;

    // Touch a target source file inside CWD so the path safety
    // check passes and the file actually exists for didOpen's
    // contents harvest.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "lsp-target.zig", .data = "test diag here" });
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");

    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.unsafe = true; // tmp is outside CWD; opt out of the safety check
    const fake_cmd = try std.fmt.allocPrint(a, "python3 {s}/{s}", .{ try std.fs.cwd().realpathAlloc(a, "."), fake });
    settings.lsp_servers = &.{
        .{ .extension = ".zig", .command = fake_cmd, .language_id = "zig" },
    };
    const t = try buildLspDiagnostics(a, &settings);
    const file_path = try std.fmt.allocPrint(a, "{s}/lsp-target.zig", .{tmp_path});
    const input = try jsonObj(a, .{ .file = file_path, .timeout_ms = @as(i64, 3000) });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "fake-lsp-marker") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "[error]") != null);
}

test "lsp_diagnostics: unconfigured extension surfaces a clear message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings(); // lsp_servers = empty
    const t = try buildLspDiagnostics(a, &settings);
    const input = try jsonObj(a, .{ .file = @as([]const u8, "src/main.zig") });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "no LSP server configured") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, ".zig") != null);
}

test "custom: nonzero exit marks is_error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const t = try buildCustom(a, &settings, .{
        .name = "always-fails",
        .description = "exits 7",
        .command = "exit 7",
    });
    const empty: std.json.ObjectMap = .empty;
    const out = try t.execute(t.context, a, .{ .object = empty });
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "exit: 7") != null);
}

test "bash: timeout kills a long-running command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const b = try buildBash(a, &settings);
    const input = try jsonObj(a, .{
        .command = @as([]const u8, "sleep 5"),
        .timeout_ms = 100,
    });
    const out = try b.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "timed out") != null);
}

test "grep: regex metacharacters match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fs.path.join(a, &.{ tmp_path, "grep.txt" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "grep.txt",
        .data = "apple 123\nbanana ABC\ncherry 456\n",
    });

    const g = try buildGrep(a, &settings);
    const input = try jsonObj(a, .{
        .pattern = @as([]const u8, "[0-9]+"),
        .path = @as([]const u8, file_path),
    });
    const out = try g.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "apple 123") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "cherry 456") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "banana") == null);
}

test "grep: invalid regex returns is_error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const g = try buildGrep(a, &settings);
    const input = try jsonObj(a, .{
        .pattern = @as([]const u8, "["),
        .path = @as([]const u8, "."),
    });
    const out = try g.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "invalid regex") != null);
}

test "bash: nonzero exit marked is_error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = testSettings();
    const b = try buildBash(a, &settings);
    const input = try jsonObj(a, .{ .command = @as([]const u8, "exit 7") });
    const out = try b.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "exit: 7") != null);
}

// ───────── todo_write validation ─────────

test "todo_write: refuses without a store" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings(); // todos = null
    const t = try buildTodoWrite(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "no store wired") != null);
}

test "todo_write: missing 'todos' field is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: todos_mod.Store = .init(testing.allocator);
    defer store.deinit(testing.io);
    var settings = testSettings();
    settings.todos = &store;
    const t = try buildTodoWrite(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'todos'") != null);
}

test "todo_write: rejects bad status enum" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: todos_mod.Store = .init(testing.allocator);
    defer store.deinit(testing.io);
    var settings = testSettings();
    settings.todos = &store;
    const t = try buildTodoWrite(a, &settings);
    const json =
        \\{"todos":[{"content":"x","status":"banana"}]}
    ;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "status invalid") != null);
}

test "todo_write: rejects non-array todos" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: todos_mod.Store = .init(testing.allocator);
    defer store.deinit(testing.io);
    var settings = testSettings();
    settings.todos = &store;
    const t = try buildTodoWrite(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"todos\":\"oops\"}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "must be an array") != null);
}

test "todo_write: empty list is valid and clears the store" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: todos_mod.Store = .init(testing.allocator);
    defer store.deinit(testing.io);
    try store.set(testing.io, &.{.{ .content = "stale", .status = .pending }});
    var settings = testSettings();
    settings.todos = &store;
    const t = try buildTodoWrite(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"todos\":[]}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expectEqual(@as(usize, 0), store.len(testing.io));
    try testing.expect(std.mem.indexOf(u8, out.text, "cleared") != null);
}

test "todo_write: full happy path mutates the store" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: todos_mod.Store = .init(testing.allocator);
    defer store.deinit(testing.io);
    var settings = testSettings();
    settings.todos = &store;
    const t = try buildTodoWrite(a, &settings);
    const json =
        \\{"todos":[
        \\  {"content":"draft","status":"in_progress"},
        \\  {"content":"ship","status":"pending"}
        \\]}
    ;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expectEqual(@as(usize, 2), store.len(testing.io));
    try testing.expect(std.mem.indexOf(u8, out.text, "[~] draft") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "[ ] ship") != null);
}

// ───────── ask_user_question validation ─────────

test "ask_user_question: refuses without a gate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings(); // ask = null
    const t = try buildAskUserQuestion(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "no UI gate") != null);
}

test "ask_user_question: missing 'question' is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var gate: ask_mod.AskGate = .init(testing.allocator, hookTestIo());
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.ask = &gate;
    const t = try buildAskUserQuestion(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'question'") != null);
}

test "ask_user_question: zero options is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var gate: ask_mod.AskGate = .init(testing.allocator, hookTestIo());
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.ask = &gate;
    const t = try buildAskUserQuestion(a, &settings);
    const json = "{\"question\":\"hi?\",\"options\":[]}";
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "non-empty") != null);
}

test "ask_user_question: more than 9 options rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var gate: ask_mod.AskGate = .init(testing.allocator, hookTestIo());
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.ask = &gate;
    const t = try buildAskUserQuestion(a, &settings);
    const json = "{\"question\":\"q\",\"options\":[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\",\"10\"]}";
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "at most 9") != null);
}

test "ask_user_question: non-string option rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var gate: ask_mod.AskGate = .init(testing.allocator, hookTestIo());
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.ask = &gate;
    const t = try buildAskUserQuestion(a, &settings);
    const json = "{\"question\":\"q\",\"options\":[\"a\",42]}";
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "must be a string") != null);
}

test "ask_user_question: headless gate cancels the call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var gate: ask_mod.AskGate = .init(testing.allocator, hookTestIo());
    // No post_fn → headless. The tool should return an is_error
    // result with "canceled by user" rather than block forever.
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.ask = &gate;
    const t = try buildAskUserQuestion(a, &settings);
    const json = "{\"question\":\"q\",\"options\":[\"a\",\"b\"]}";
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "canceled") != null);
}

// ───────── task (sub-agent) validation ─────────

test "task: refuses when no sub-agent runtime is wired" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings(); // sub_agent = null
    const t = try buildTask(a, &settings);
    const input = try jsonObj(a, .{ .prompt = @as([]const u8, "x") });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "no sub-agent runtime") != null);
}

test "task: missing 'prompt' is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub: SubAgent = .{
        .provider = .{
            .ctx = null,
            .streamFn = stubStream,
            .lastErrorBodyFn = stubLastBody,
        },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTask(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'prompt'") != null);
}

test "task: 'tools' must be an array" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub: SubAgent = .{
        .provider = .{ .ctx = null, .streamFn = stubStream, .lastErrorBodyFn = stubLastBody },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTask(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"prompt\":\"x\",\"tools\":\"not-array\"}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "must be an array") != null);
}

test "team: refuses without runtime" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildTeam(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tasks\":[{\"prompt\":\"x\"}]}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "no sub-agent runtime") != null);
}

test "team: missing 'tasks' is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub: SubAgent = .{
        .provider = .{ .ctx = null, .streamFn = stubStream, .lastErrorBodyFn = stubLastBody },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTeam(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'tasks'") != null);
}

test "team: empty tasks array is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub: SubAgent = .{
        .provider = .{ .ctx = null, .streamFn = stubStream, .lastErrorBodyFn = stubLastBody },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTeam(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tasks\":[]}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "non-empty") != null);
}

test "team: more than 8 tasks rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub: SubAgent = .{
        .provider = .{ .ctx = null, .streamFn = stubStream, .lastErrorBodyFn = stubLastBody },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTeam(a, &settings);
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(a, "{\"tasks\":[");
    for (0..9) |i| {
        if (i > 0) try json.append(a, ',');
        try json.print(a, "{{\"prompt\":\"p{d}\"}}", .{i});
    }
    try json.appendSlice(a, "]}");
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json.items, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "at most 8") != null);
}

test "team: aggregates each child's final text under its label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Per-prompt scripted-text provider. `onText` emits a tagged
    // string echoing the prompt; the aggregator should land both
    // children's text under their labels.
    const Echo = struct {
        fn stream(_: ?*anyopaque, req: provider_mod.Request, s: provider_mod.Stream) anyerror!void {
            // Find the user message text and echo it back.
            for (req.messages) |m| {
                for (m.content) |c| switch (c) {
                    .text => |t| {
                        const out = std.fmt.allocPrint(std.heap.page_allocator, "echo:{s}", .{t}) catch return;
                        defer std.heap.page_allocator.free(out);
                        try s.onText(s.ctx, out);
                    },
                    else => {},
                };
            }
            try s.onStop(s.ctx, "end_turn");
        }
    };

    const sub: SubAgent = .{
        .provider = .{ .ctx = null, .streamFn = Echo.stream, .lastErrorBodyFn = stubLastBody },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTeam(a, &settings);
    const json =
        \\{"tasks":[
        \\  {"label":"alpha","prompt":"first-prompt"},
        \\  {"label":"beta","prompt":"second-prompt"}
        \\]}
    ;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "## alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "echo:first-prompt") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "## beta") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "echo:second-prompt") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "team complete (2 task(s))") != null);
}

test "team: each task missing prompt is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub: SubAgent = .{
        .provider = .{ .ctx = null, .streamFn = stubStream, .lastErrorBodyFn = stubLastBody },
        .model = "m",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTeam(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tasks\":[{\"label\":\"x\"}]}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "prompt missing") != null);
}

test "task: child registry filters out `task` and respects allowlist" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Hand-crafted parent registry with three tools; the allowlist
    // restricts the child to "echo".
    var captured_filter: ChildFilterCapture = .{};
    const parent_tools = [_]tool.Tool{
        .{ .name = "echo", .description = "", .input_schema = .{ .null = {} }, .execute = stubExecute },
        .{ .name = "edit", .description = "", .input_schema = .{ .null = {} }, .execute = stubExecute },
        .{ .name = "task", .description = "", .input_schema = .{ .null = {} }, .execute = stubExecute },
    };
    const sub: SubAgent = .{
        .provider = .{
            .ctx = &captured_filter,
            .streamFn = ChildFilterCapture.streamCapture,
            .lastErrorBodyFn = stubLastBody,
        },
        .model = "m",
        .tools = &parent_tools,
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTask(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"prompt\":\"x\",\"tools\":[\"echo\",\"task\"]}", .{});
    _ = try t.execute(@constCast(@ptrCast(&settings)), a, input);

    // The provider was called once with the child's tool defs;
    // we verify the registry was filtered to ONLY "echo": "task"
    // is excluded by the runtime even though it's in the allowlist,
    // and "edit" is excluded because the allowlist blocks it.
    try testing.expectEqual(@as(usize, 1), captured_filter.tool_count);
    try testing.expectEqualStrings("echo", captured_filter.first_tool_name);
}

const ChildFilterCapture = struct {
    tool_count: usize = 0,
    first_tool_name: []const u8 = "",
    model: []const u8 = "",

    fn streamCapture(ctx: ?*anyopaque, req: provider_mod.Request, s: provider_mod.Stream) anyerror!void {
        const self: *ChildFilterCapture = @ptrCast(@alignCast(ctx.?));
        self.tool_count = req.tools.len;
        if (req.tools.len > 0) self.first_tool_name = req.tools[0].name;
        self.model = req.model;
        // Emit an immediate end_turn so the agent loop unwinds.
        try s.onStop(s.ctx, "end_turn");
    }
};

test "task: per-call `model` override wins over sub-agent default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var captured: ChildFilterCapture = .{};
    const sub: SubAgent = .{
        .provider = .{
            .ctx = &captured,
            .streamFn = ChildFilterCapture.streamCapture,
            .lastErrorBodyFn = stubLastBody,
        },
        .model = "default-model-from-startup",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTask(a, &settings);
    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"prompt\":\"plan this\",\"model\":\"claude-opus-4-7\"}",
        .{},
    );
    _ = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expectEqualStrings("claude-opus-4-7", captured.model);
}

test "task: omitted `model` falls back to sub-agent default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var captured: ChildFilterCapture = .{};
    const sub: SubAgent = .{
        .provider = .{
            .ctx = &captured,
            .streamFn = ChildFilterCapture.streamCapture,
            .lastErrorBodyFn = stubLastBody,
        },
        .model = "planner-from-cli",
    };
    var settings = testSettings();
    settings.gpa = testing.allocator;
    settings.sub_agent = &sub;
    const t = try buildTask(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"prompt\":\"x\"}", .{});
    _ = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expectEqualStrings("planner-from-cli", captured.model);
}

fn stubStream(_: ?*anyopaque, _: provider_mod.Request, s: provider_mod.Stream) anyerror!void {
    try s.onStop(s.ctx, "end_turn");
}

fn stubLastBody(_: ?*anyopaque) ?[]const u8 {
    return null;
}

fn stubExecute(_: ?*anyopaque, _: std.mem.Allocator, _: std.json.Value) anyerror!tool.Output {
    return .{ .text = "" };
}

fn hookTestIo() Io {
    const Threaded = std.Io.Threaded;
    const Static = struct {
        var t: Threaded = undefined;
        var initialised: bool = false;
    };
    if (!Static.initialised) {
        Static.t = Threaded.init(std.heap.page_allocator, .{});
        Static.initialised = true;
    }
    return Static.t.io();
}

// ───────── worktree validation ─────────

test "worktree: missing 'action' is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildWorktree(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'action'") != null);
}

test "worktree: unknown action is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildWorktree(a, &settings);
    const input = try jsonObj(a, .{ .action = @as([]const u8, "frobnicate") });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "unknown action") != null);
}

test "worktree: add without 'path' is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildWorktree(a, &settings);
    const input = try jsonObj(a, .{ .action = @as([]const u8, "add") });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "'path' required") != null);
}

test "worktree: refused in plan mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var settings = testSettings();
    settings.mode = .plan;
    const t = try buildWorktree(a, &settings);
    const input = try jsonObj(a, .{ .action = @as([]const u8, "list") });
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "plan mode") != null);
}

// ───────── write_plan validation ─────────

test "write_plan: missing 'steps' is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildWritePlan(a, &settings);
    const input = try jsonObj(a, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "missing 'steps'") != null);
}

test "write_plan: empty steps is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildWritePlan(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"steps\":[]}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "non-empty") != null);
}

test "write_plan: steps must be strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = testSettings();
    const t = try buildWritePlan(a, &settings);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"steps\":[\"a\",42]}", .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "must be a string") != null);
}

test "write_plan: writes PLAN.md and is exempt from plan mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    // Run under a CWD swap so PLAN.md ends up in the tmp dir.
    var save_cwd: std.fs.Dir = try std.fs.cwd().openDir(".", .{});
    defer save_cwd.close();
    try std.posix.chdir(tmp_abs);
    defer std.posix.fchdir(save_cwd.fd) catch {};

    var settings = testSettings();
    settings.mode = .plan; // <- key check: write_plan must run anyway
    const t = try buildWritePlan(a, &settings);

    const json =
        \\{"summary":"unit test plan","steps":["draft","review","ship"]}
    ;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try t.execute(@constCast(@ptrCast(&settings)), a, input);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "wrote PLAN.md") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "3 step") != null);

    const written = try Io.Dir.cwd().readFileAlloc(testing.io, "PLAN.md", a, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, written, "# Plan") != null);
    try testing.expect(std.mem.indexOf(u8, written, "unit test plan") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- [ ] draft") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- [ ] ship") != null);
}
