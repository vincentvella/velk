//! Hook system: settings-driven shell commands fired at well-known
//! lifecycle points. v1 supports four events:
//!
//!   PreToolUse        before a tool runs (exit 2 = block, stdout/stderr = reason)
//!   PostToolUse       after a tool runs (notification only)
//!   UserPromptSubmit  on prompt submit (stdout = extra context to prepend)
//!   Stop              after a turn finishes (notification only)
//!
//! Two hook types ship in v1:
//!   command  shell command, JSON event passed via stdin, exit code = decision
//!   prompt   literal text used as injected context (UserPromptSubmit only)
//!
//! Out of scope for v1: agent + http hook types, PostSampling event,
//! per-hook timeout enforcement (the field is parsed but currently
//! advisory). The `agent`, `http`, and `subagent_stop` plumbing lands
//! once the sub-agent runtime exists in Phase 12 part 2.

const std = @import("std");
const Io = std.Io;
const mvzr = @import("mvzr");

pub const Event = enum {
    pre_tool_use,
    post_tool_use,
    user_prompt_submit,
    stop,

    pub fn fromString(s: []const u8) ?Event {
        if (std.mem.eql(u8, s, "PreToolUse")) return .pre_tool_use;
        if (std.mem.eql(u8, s, "PostToolUse")) return .post_tool_use;
        if (std.mem.eql(u8, s, "UserPromptSubmit")) return .user_prompt_submit;
        if (std.mem.eql(u8, s, "Stop")) return .stop;
        return null;
    }

    pub fn toString(self: Event) []const u8 {
        return switch (self) {
            .pre_tool_use => "PreToolUse",
            .post_tool_use => "PostToolUse",
            .user_prompt_submit => "UserPromptSubmit",
            .stop => "Stop",
        };
    }
};

pub const HookKind = enum { command, prompt };

pub const Hook = struct {
    event: Event,
    /// Optional regex matched against `tool_name` for tool events. An
    /// unset matcher means "fire for every tool". Ignored for events
    /// that don't carry a tool name (UserPromptSubmit, Stop).
    matcher: ?[]const u8 = null,
    kind: HookKind,
    /// Shell command for `.command` hooks; literal text for `.prompt`
    /// hooks (which only make sense on UserPromptSubmit).
    body: []const u8,
    /// Advisory in v1: parsed but not yet enforced. Future: kill child
    /// when wall-clock exceeds.
    timeout_ms: u32 = 30_000,
};

/// Outcome of dispatching all hooks for one event.
pub const Outcome = struct {
    /// Set on PreToolUse when at least one `command` hook exited with
    /// status 2. Caller must short-circuit and surface this as a
    /// tool-error result back to the model.
    blocked: ?[]const u8 = null,
    /// Set on UserPromptSubmit. Concatenation of every successful
    /// hook's stdout / `prompt` body, separated by blank lines.
    /// Caller prepends to the user prompt the worker sees.
    inject: ?[]const u8 = null,
    /// Set when a hook exited with a non-zero, non-2 status. Caller
    /// surfaces as a non-fatal notice (stderr-style).
    notice: ?[]const u8 = null,
};

pub const Context = struct {
    tool_name: ?[]const u8 = null,
    tool_input: ?std.json.Value = null,
    tool_output: ?[]const u8 = null,
    tool_error: bool = false,
    prompt: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

pub const Engine = struct {
    hooks: []const Hook = &.{},

    pub fn empty() Engine {
        return .{};
    }

    pub fn isEmpty(self: *const Engine) bool {
        return self.hooks.len == 0;
    }

    /// Walk the parsed JSON `hooks` field from settings.json. Shape:
    ///
    /// ```json
    /// { "PreToolUse": [ { "matcher": "bash", "type": "command", "command": "...", "timeout_ms": 5000 } ],
    ///   "Stop":       [ { "type": "command", "command": "say done" } ] }
    /// ```
    ///
    /// Unknown event names and malformed entries are skipped silently
    /// — settings parsing should not fail loudly on a typo'd hook.
    pub fn parse(arena: std.mem.Allocator, value: std.json.Value) !Engine {
        const obj = switch (value) {
            .object => |o| o,
            else => return Engine.empty(),
        };

        var list: std.ArrayList(Hook) = .empty;
        var it = obj.iterator();
        while (it.next()) |entry| {
            const event = Event.fromString(entry.key_ptr.*) orelse continue;
            const arr = switch (entry.value_ptr.*) {
                .array => |a| a,
                else => continue,
            };
            for (arr.items) |item| {
                const ho = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const kind_str = stringField(ho, "type") orelse "command";
                const kind: HookKind = if (std.mem.eql(u8, kind_str, "prompt"))
                    .prompt
                else if (std.mem.eql(u8, kind_str, "command"))
                    .command
                else
                    continue;

                const body = switch (kind) {
                    .command => stringField(ho, "command") orelse continue,
                    .prompt => stringField(ho, "prompt") orelse continue,
                };

                const matcher = stringField(ho, "matcher");
                const timeout_ms: u32 = blk: {
                    const v = ho.get("timeout_ms") orelse break :blk 30_000;
                    break :blk switch (v) {
                        .integer => |n| if (n > 0 and n < @as(i64, std.math.maxInt(u32))) @intCast(n) else 30_000,
                        else => 30_000,
                    };
                };

                try list.append(arena, .{
                    .event = event,
                    .matcher = if (matcher) |m| try arena.dupe(u8, m) else null,
                    .kind = kind,
                    .body = try arena.dupe(u8, body),
                    .timeout_ms = timeout_ms,
                });
            }
        }
        return .{ .hooks = list.items };
    }

    /// Fire every hook registered for `event` whose matcher accepts
    /// `ctx.tool_name`. Hooks run sequentially in registration order;
    /// the first PreToolUse hook to return exit-2 wins (later hooks
    /// for the same event are skipped). UserPromptSubmit accumulates
    /// stdout from every successful hook.
    pub fn dispatch(
        self: *const Engine,
        gpa: std.mem.Allocator,
        io: Io,
        event: Event,
        ctx: Context,
    ) !Outcome {
        var out: Outcome = .{};
        if (self.hooks.len == 0) return out;

        var inject_buf: std.ArrayList(u8) = .empty;
        defer inject_buf.deinit(gpa);
        var notice_buf: std.ArrayList(u8) = .empty;
        defer notice_buf.deinit(gpa);

        for (self.hooks) |h| {
            if (h.event != event) continue;
            if (!matcherAccepts(h.matcher, ctx.tool_name)) continue;

            switch (h.kind) {
                .prompt => {
                    if (event != .user_prompt_submit) continue;
                    if (inject_buf.items.len > 0) try inject_buf.appendSlice(gpa, "\n\n");
                    try inject_buf.appendSlice(gpa, h.body);
                },
                .command => {
                    const r = runCommand(gpa, io, h, event, ctx) catch |e| {
                        if (notice_buf.items.len > 0) try notice_buf.append(gpa, '\n');
                        const msg = try std.fmt.allocPrint(gpa, "hook spawn failed: {s}", .{@errorName(e)});
                        defer gpa.free(msg);
                        try notice_buf.appendSlice(gpa, msg);
                        continue;
                    };
                    defer gpa.free(r.stdout);
                    defer gpa.free(r.stderr);

                    if (r.exit_code == 2) {
                        // Blocked. Prefer stderr for the reason, fall
                        // back to stdout.
                        const reason_src = if (r.stderr.len > 0) r.stderr else r.stdout;
                        const reason = std.mem.trim(u8, reason_src, " \t\r\n");
                        out.blocked = try gpa.dupe(u8, if (reason.len > 0) reason else "blocked by hook");
                        if (inject_buf.items.len > 0) out.inject = try inject_buf.toOwnedSlice(gpa);
                        if (notice_buf.items.len > 0) out.notice = try notice_buf.toOwnedSlice(gpa);
                        return out;
                    } else if (r.exit_code != 0) {
                        if (notice_buf.items.len > 0) try notice_buf.append(gpa, '\n');
                        const stderr_trimmed = std.mem.trim(u8, r.stderr, " \t\r\n");
                        const msg = try std.fmt.allocPrint(
                            gpa,
                            "hook exit {d}: {s}",
                            .{ r.exit_code, if (stderr_trimmed.len > 0) stderr_trimmed else "(no stderr)" },
                        );
                        defer gpa.free(msg);
                        try notice_buf.appendSlice(gpa, msg);
                        continue;
                    }

                    // Successful run. UserPromptSubmit stdout is
                    // injected; other events ignore stdout.
                    if (event == .user_prompt_submit) {
                        const text = std.mem.trim(u8, r.stdout, " \t\r\n");
                        if (text.len > 0) {
                            if (inject_buf.items.len > 0) try inject_buf.appendSlice(gpa, "\n\n");
                            try inject_buf.appendSlice(gpa, text);
                        }
                    }
                },
            }
        }

        if (inject_buf.items.len > 0) out.inject = try inject_buf.toOwnedSlice(gpa);
        if (notice_buf.items.len > 0) out.notice = try notice_buf.toOwnedSlice(gpa);
        return out;
    }
};

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn matcherAccepts(matcher: ?[]const u8, tool_name: ?[]const u8) bool {
    const pat = matcher orelse return true;
    const name = tool_name orelse return true; // non-tool events ignore matcher
    var rx = mvzr.compile(pat) orelse return false;
    return rx.isMatch(name);
}

const RunResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
};

fn runCommand(
    gpa: std.mem.Allocator,
    io: Io,
    h: Hook,
    event: Event,
    ctx: Context,
) !RunResult {
    const payload = try buildPayload(gpa, event, ctx);
    defer gpa.free(payload);

    const argv = &[_][]const u8{ "/bin/sh", "-c", h.body };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer {
        child.kill(io);
        _ = child.wait(io) catch {};
    }

    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, payload) catch {};
        stdin.close(io);
        child.stdin = null;
    }

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(gpa);
    errdefer stderr_buf.deinit(gpa);

    if (child.stdout) |*so| {
        var buf: [4096]u8 = undefined;
        var reader = so.reader(io, &buf);
        while (true) {
            const data = reader.interface.peekGreedy(1) catch break;
            if (data.len == 0) break;
            try stdout_buf.appendSlice(gpa, data);
            reader.interface.toss(data.len);
        }
    }
    if (child.stderr) |*se| {
        var buf: [4096]u8 = undefined;
        var reader = se.reader(io, &buf);
        while (true) {
            const data = reader.interface.peekGreedy(1) catch break;
            if (data.len == 0) break;
            try stderr_buf.appendSlice(gpa, data);
            reader.interface.toss(data.len);
        }
    }

    const term = try child.wait(io);
    const code: i32 = switch (term) {
        .exited => |c| @intCast(c),
        .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
        else => -1,
    };

    return .{
        .exit_code = code,
        .stdout = try stdout_buf.toOwnedSlice(gpa),
        .stderr = try stderr_buf.toOwnedSlice(gpa),
    };
}

fn buildPayload(gpa: std.mem.Allocator, event: Event, ctx: Context) ![]u8 {
    const Payload = struct {
        event: []const u8,
        cwd: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
        tool_input: ?std.json.Value = null,
        tool_output: ?[]const u8 = null,
        tool_error: ?bool = null,
        prompt: ?[]const u8 = null,
    };
    const has_tool = ctx.tool_name != null or ctx.tool_output != null;
    const p: Payload = .{
        .event = event.toString(),
        .cwd = ctx.cwd,
        .tool_name = ctx.tool_name,
        .tool_input = ctx.tool_input,
        .tool_output = ctx.tool_output,
        .tool_error = if (has_tool) ctx.tool_error else null,
        .prompt = ctx.prompt,
    };
    return try std.json.Stringify.valueAlloc(gpa, p, .{ .emit_null_optional_fields = false });
}

// ───────── tests ─────────

const testing = std.testing;

test "Event.fromString round-trip" {
    try testing.expectEqual(Event.pre_tool_use, Event.fromString("PreToolUse").?);
    try testing.expectEqual(Event.stop, Event.fromString("Stop").?);
    try testing.expect(Event.fromString("Bogus") == null);
    try testing.expectEqualStrings("UserPromptSubmit", Event.user_prompt_submit.toString());
}

test "parse: empty object yields empty engine" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{}", .{});
    const e = try Engine.parse(arena_state.allocator(), v);
    try testing.expect(e.isEmpty());
}

test "parse: unknown event names skipped, valid ones loaded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{
        \\  "Bogus":      [{"type":"command","command":"x"}],
        \\  "PreToolUse": [{"matcher":"bash","type":"command","command":"echo y"}],
        \\  "Stop":       [{"type":"command","command":"say done","timeout_ms":1000}]
        \\}
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
    const e = try Engine.parse(arena_state.allocator(), v);
    try testing.expectEqual(@as(usize, 2), e.hooks.len);
    try testing.expectEqual(Event.pre_tool_use, e.hooks[0].event);
    try testing.expectEqualStrings("bash", e.hooks[0].matcher.?);
    try testing.expectEqualStrings("echo y", e.hooks[0].body);
    try testing.expectEqual(Event.stop, e.hooks[1].event);
    try testing.expectEqual(@as(u32, 1000), e.hooks[1].timeout_ms);
}

test "parse: prompt-type hook requires `prompt` field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{ "UserPromptSubmit": [
        \\   {"type":"prompt","prompt":"Today is Monday."},
        \\   {"type":"prompt"}
        \\] }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
    const e = try Engine.parse(arena_state.allocator(), v);
    try testing.expectEqual(@as(usize, 1), e.hooks.len);
    try testing.expectEqual(HookKind.prompt, e.hooks[0].kind);
    try testing.expectEqualStrings("Today is Monday.", e.hooks[0].body);
}

test "matcherAccepts: regex match" {
    try testing.expect(matcherAccepts(null, "bash"));
    try testing.expect(matcherAccepts("bash|edit", "bash"));
    try testing.expect(matcherAccepts("bash|edit", "edit"));
    try testing.expect(!matcherAccepts("^bash$", "bash_extra"));
    try testing.expect(matcherAccepts("write_file", "write_file"));
}

test "dispatch: prompt hook injects literal text on UserPromptSubmit" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .user_prompt_submit,
        .kind = .prompt,
        .body = "extra context",
    }} };
    const out = try e.dispatch(arena, std.testing.io, .user_prompt_submit, .{ .prompt = "hi" });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    try testing.expect(out.blocked == null);
    try testing.expectEqualStrings("extra context", out.inject.?);
}

test "dispatch: empty engine returns empty outcome" {
    const arena = testing.allocator;
    const e = Engine.empty();
    const out = try e.dispatch(arena, std.testing.io, .pre_tool_use, .{ .tool_name = "bash" });
    try testing.expect(out.blocked == null);
    try testing.expect(out.inject == null);
    try testing.expect(out.notice == null);
}

test "buildPayload: includes tool_name and event" {
    const payload = try buildPayload(testing.allocator, .pre_tool_use, .{
        .tool_name = "bash",
        .cwd = "/tmp",
    });
    defer testing.allocator.free(payload);
    try testing.expect(std.mem.indexOf(u8, payload, "\"event\":\"PreToolUse\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"tool_name\":\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"cwd\":\"/tmp\"") != null);
}
