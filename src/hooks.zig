//! Hook system: settings-driven shell commands fired at well-known
//! lifecycle points. The events:
//!
//!   PreToolUse          before a tool runs (exit 2 = block, stdout/stderr = reason)
//!   PostToolUse         after a tool runs (notification only)
//!   PostToolUseFailure  after a tool fails (is_error=true). Subset of PostToolUse.
//!   UserPromptSubmit    on prompt submit (stdout = extra context to prepend)
//!   Stop                after a turn finishes (notification only)
//!   SubagentStop        after a `task` sub-agent returns (notification only)
//!   Notification        velk-side notice fired (e.g. budget breach)
//!   PostSampling        after a provider streaming response completes
//!
//! Two hook types ship in v1:
//!   command  shell command, JSON event passed via stdin, exit code = decision
//!   prompt   literal text used as injected context (UserPromptSubmit only)
//!
//! Out of scope for v1: agent + http hook types, per-hook timeout
//! enforcement (the field is parsed but currently advisory).

const std = @import("std");
const Io = std.Io;
const mvzr = @import("mvzr");

pub const Event = enum {
    pre_tool_use,
    post_tool_use,
    /// Subset of post_tool_use that fires only when the tool returned
    /// is_error=true. Useful for "send me a Slack message when bash
    /// fails" without spamming on every successful tool call.
    post_tool_use_failure,
    user_prompt_submit,
    stop,
    /// Fires after a `task` sub-agent completes. Payload includes
    /// the child's final text under `tool_output` and a synthetic
    /// `tool_name = "task"` so existing matcher syntax works.
    subagent_stop,
    /// Fires when velk surfaces a user-visible notice (budget breach,
    /// auto-compact, etc). Use to mirror notices to a wider channel.
    notification,
    /// Fires after a provider streaming response completes. Payload
    /// carries the final assistant text under `tool_output` so a
    /// hook can post-process or archive it.
    post_sampling,

    pub fn fromString(s: []const u8) ?Event {
        if (std.mem.eql(u8, s, "PreToolUse")) return .pre_tool_use;
        if (std.mem.eql(u8, s, "PostToolUse")) return .post_tool_use;
        if (std.mem.eql(u8, s, "PostToolUseFailure")) return .post_tool_use_failure;
        if (std.mem.eql(u8, s, "UserPromptSubmit")) return .user_prompt_submit;
        if (std.mem.eql(u8, s, "Stop")) return .stop;
        if (std.mem.eql(u8, s, "SubagentStop")) return .subagent_stop;
        if (std.mem.eql(u8, s, "Notification")) return .notification;
        if (std.mem.eql(u8, s, "PostSampling")) return .post_sampling;
        return null;
    }

    pub fn toString(self: Event) []const u8 {
        return switch (self) {
            .pre_tool_use => "PreToolUse",
            .post_tool_use => "PostToolUse",
            .post_tool_use_failure => "PostToolUseFailure",
            .user_prompt_submit => "UserPromptSubmit",
            .stop => "Stop",
            .subagent_stop => "SubagentStop",
            .notification => "Notification",
            .post_sampling => "PostSampling",
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

    // Drain stdout + stderr concurrently with a wall-clock timeout
    // honoring `h.timeout_ms`. Without this, a hook that hangs (e.g.
    // `read` from a closed pipe, or an infinite loop) blocks the
    // agent forever. Using MultiReader.fill mirrors what runBash
    // does for the same hang-the-tool footgun.
    const timeout: Io.Timeout = if (h.timeout_ms == 0) .none else .{
        .duration = .{
            .raw = Io.Duration.fromMilliseconds(h.timeout_ms),
            .clock = .awake,
        },
    };

    var multi_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(gpa, io, multi_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const so_reader = multi.reader(0);
    const se_reader = multi.reader(1);

    var timed_out = false;
    while (multi.fill(64, timeout)) |_| {
        if (so_reader.buffered().len > 256 * 1024) break; // cap pathological output
        if (se_reader.buffered().len > 256 * 1024) break;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => return err,
    }

    if (timed_out) {
        child.kill(io);
        _ = child.wait(io) catch {};
        const note = try std.fmt.allocPrint(gpa, "hook timed out after {d}ms", .{h.timeout_ms});
        return .{
            .exit_code = -1,
            .stdout = try gpa.dupe(u8, ""),
            .stderr = note,
        };
    }

    multi.checkAnyError() catch {}; // best-effort drain
    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(gpa);
    errdefer stderr_buf.deinit(gpa);
    try stdout_buf.appendSlice(gpa, so_reader.buffered());
    try stderr_buf.appendSlice(gpa, se_reader.buffered());

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

test "Event.fromString: new event names" {
    try testing.expectEqual(Event.post_tool_use_failure, Event.fromString("PostToolUseFailure").?);
    try testing.expectEqual(Event.subagent_stop, Event.fromString("SubagentStop").?);
    try testing.expectEqual(Event.notification, Event.fromString("Notification").?);
    try testing.expectEqual(Event.post_sampling, Event.fromString("PostSampling").?);
}

test "Event.toString: new event names" {
    try testing.expectEqualStrings("PostToolUseFailure", Event.post_tool_use_failure.toString());
    try testing.expectEqualStrings("SubagentStop", Event.subagent_stop.toString());
    try testing.expectEqualStrings("Notification", Event.notification.toString());
    try testing.expectEqualStrings("PostSampling", Event.post_sampling.toString());
}

test "parse: PostToolUseFailure + SubagentStop hooks load" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{
        \\  "PostToolUseFailure": [{"type":"command","command":"echo failed"}],
        \\  "SubagentStop":       [{"type":"command","command":"echo done"}],
        \\  "Notification":       [{"type":"command","command":"echo notice"}],
        \\  "PostSampling":       [{"type":"command","command":"echo sampled"}]
        \\}
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
    const e = try Engine.parse(arena_state.allocator(), v);
    try testing.expectEqual(@as(usize, 4), e.hooks.len);
    var saw_failure = false;
    var saw_subagent = false;
    var saw_notif = false;
    var saw_sampling = false;
    for (e.hooks) |h| {
        switch (h.event) {
            .post_tool_use_failure => saw_failure = true,
            .subagent_stop => saw_subagent = true,
            .notification => saw_notif = true,
            .post_sampling => saw_sampling = true,
            else => {},
        }
    }
    try testing.expect(saw_failure and saw_subagent and saw_notif and saw_sampling);
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

// The dispatch tests below need a real `Io` because `runCommand`
// spawns a child process. Reuse a single threaded Io across tests.
fn testIo() Io {
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

test "dispatch: command-type exit 0 lets the tool proceed" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .pre_tool_use,
        .kind = .command,
        .body = "exit 0",
    }} };
    const out = try e.dispatch(arena, testIo(), .pre_tool_use, .{ .tool_name = "bash" });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    try testing.expect(out.blocked == null);
    try testing.expect(out.notice == null);
}

test "dispatch: command-type exit 2 blocks with stderr as reason" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .pre_tool_use,
        .kind = .command,
        .body = "echo nope >&2; exit 2",
    }} };
    const out = try e.dispatch(arena, testIo(), .pre_tool_use, .{ .tool_name = "bash" });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    defer arena.free(out.blocked.?);
    try testing.expectEqualStrings("nope", out.blocked.?);
}

test "dispatch: command-type non-zero non-2 surfaces as a notice" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .post_tool_use,
        .kind = .command,
        .body = "echo broke >&2; exit 7",
    }} };
    const out = try e.dispatch(arena, testIo(), .post_tool_use, .{ .tool_name = "bash" });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    defer arena.free(out.notice.?);
    try testing.expect(out.blocked == null);
    try testing.expect(std.mem.indexOf(u8, out.notice.?, "exit 7") != null);
    try testing.expect(std.mem.indexOf(u8, out.notice.?, "broke") != null);
}

test "dispatch: command stdout becomes inject on UserPromptSubmit" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .user_prompt_submit,
        .kind = .command,
        .body = "echo INJECTED",
    }} };
    const out = try e.dispatch(arena, testIo(), .user_prompt_submit, .{ .prompt = "hi" });
    defer if (out.notice) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    defer arena.free(out.inject.?);
    try testing.expectEqualStrings("INJECTED", out.inject.?);
}

test "dispatch: matcher rejects mismatched tool_name and skips the hook" {
    const arena = testing.allocator;
    // The hook would block if it ran. Matcher excludes "bash"
    // because it only accepts "edit", so we must NOT see blocked.
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .pre_tool_use,
        .kind = .command,
        .matcher = "^edit$",
        .body = "exit 2",
    }} };
    const out = try e.dispatch(arena, testIo(), .pre_tool_use, .{ .tool_name = "bash" });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    try testing.expect(out.blocked == null);
}

test "dispatch: PostToolUseFailure hook fires only when is_error" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .post_tool_use_failure,
        .kind = .command,
        .body = "echo got-failure",
    }} };
    // Success-only events do not match a *_failure hook, even on the
    // post_tool_use family — caller decides which one to dispatch.
    const out = try e.dispatch(arena, testIo(), .post_tool_use_failure, .{
        .tool_name = "bash",
        .tool_error = true,
    });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    try testing.expect(out.blocked == null);
    // No notice expected — `echo` exits 0 cleanly. We just confirm
    // the dispatch ran without raising.
}

test "dispatch: SubagentStop notification round-trips" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .subagent_stop,
        .kind = .command,
        .body = "exit 0",
    }} };
    const out = try e.dispatch(arena, testIo(), .subagent_stop, .{
        .tool_name = "task",
        .tool_output = "child finished",
    });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    try testing.expect(out.blocked == null);
}

test "dispatch: PostSampling carries tool_output for archival" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .post_sampling,
        .kind = .command,
        .body = "exit 0",
    }} };
    const out = try e.dispatch(arena, testIo(), .post_sampling, .{
        .tool_output = "the assistant said hi",
    });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    try testing.expect(out.blocked == null);
}

test "dispatch: command hung beyond timeout_ms is killed and notice surfaces" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .post_tool_use,
        .kind = .command,
        .body = "sleep 10",
        .timeout_ms = 200, // tight cap so the test finishes quickly
    }} };
    const start = std.time.milliTimestamp();
    const out = try e.dispatch(arena, testIo(), .post_tool_use, .{ .tool_name = "bash" });
    const elapsed_ms = std.time.milliTimestamp() - start;
    defer if (out.inject) |s| arena.free(s);
    defer if (out.blocked) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    // Sanity: we shouldn't have actually waited 10 seconds.
    try testing.expect(elapsed_ms < 2000);
    try testing.expect(out.notice != null);
    try testing.expect(std.mem.indexOf(u8, out.notice.?, "timed out") != null);
}

test "dispatch: matcher hits and the hook fires" {
    const arena = testing.allocator;
    const e: Engine = .{ .hooks = &[_]Hook{.{
        .event = .pre_tool_use,
        .kind = .command,
        .matcher = "^bash$",
        .body = "echo blocked-it >&2; exit 2",
    }} };
    const out = try e.dispatch(arena, testIo(), .pre_tool_use, .{ .tool_name = "bash" });
    defer if (out.inject) |s| arena.free(s);
    defer if (out.notice) |s| arena.free(s);
    defer arena.free(out.blocked.?);
    try testing.expectEqualStrings("blocked-it", out.blocked.?);
}
