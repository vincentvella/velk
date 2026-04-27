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
    /// match the common-ignore set (node_modules, .git, etc).
    include_ignored: bool = false,
    /// Process env (for XDG_CACHE_HOME etc). Nullable for tests.
    env_map: ?*std.process.Environ.Map = null,
    /// Optional todo store. When set, the `todo_write` tool is
    /// registered and writes here; the TUI renders from a snapshot.
    todos: ?*todos_mod.Store = null,
    /// Optional ask gate. When set, the `ask_user_question` tool is
    /// registered; calls block on the gate until the TUI delivers a
    /// selection (or Esc cancels).
    ask: ?*ask_mod.AskGate = null,
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
    if (settings.todos != null) try list.append(arena, try buildTodoWrite(arena, settings));
    if (settings.ask != null) try list.append(arena, try buildAskUserQuestion(arena, settings));
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
        if (!settings.include_ignored and ignore.isIgnored(entry.name)) {
            skipped += 1;
            continue;
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
                if (!settings.include_ignored and ignore.isIgnored(entry.path)) continue;
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
    const argv = &[_][]const u8{ "/bin/sh", "-c", command };
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

/// Send SIGKILL to a process group. Best-effort — silently ignores
/// errors so cleanup never panics.
fn killGroup(pid: ?std.posix.pid_t) void {
    const id = pid orelse return;
    if (id <= 0) return;
    // Negative PID means "this process group" in POSIX kill().
    _ = std.c.kill(-id, std.posix.SIG.KILL);
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
