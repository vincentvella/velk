//! Slash-command framework. The TUI's input handler routes any line
//! starting with `/` here instead of sending it to the model.
//!
//! This module is deliberately decoupled from the TUI: it owns the
//! parser and a name→handler `Registry`, but handlers themselves are
//! plain `*const fn (ctx: *anyopaque, args: []const u8) anyerror!Action`
//! so the caller (TUI) can pass any context type it likes.

const std = @import("std");

pub const Action = enum {
    /// Command ran (or failed gracefully). Stay in the REPL.
    handled,
    /// User requested exit (e.g. `/exit`).
    exit,
};

pub const Handler = *const fn (ctx: *anyopaque, args: []const u8) anyerror!Action;

pub const Command = struct {
    /// Without the leading `/`.
    name: []const u8,
    description: []const u8,
    handler: Handler,
};

pub const Parsed = struct {
    /// Without the leading `/`.
    name: []const u8,
    /// Everything after the first whitespace run, with leading
    /// whitespace stripped. Empty when no args were supplied.
    args: []const u8,
};

/// Recognise a slash-command line. Returns null if `line` doesn't start
/// with `/` or is just `/` on its own. Trailing whitespace on the
/// command name is stripped; arg whitespace is preserved internally
/// (only the gap between name and args is collapsed).
pub fn parse(line: []const u8) ?Parsed {
    // Trim leading/trailing whitespace (spaces, tabs, newlines) so
    // shells that hand us "/clear\n" or "  /help" still parse.
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '/') return null;
    const rest = trimmed[1..];
    const space_idx = std.mem.indexOfAny(u8, rest, " \t") orelse {
        return .{ .name = rest, .args = "" };
    };
    var args_start: usize = space_idx + 1;
    while (args_start < rest.len and (rest[args_start] == ' ' or rest[args_start] == '\t'))
        args_start += 1;
    return .{ .name = rest[0..space_idx], .args = rest[args_start..] };
}

pub const Registry = struct {
    commands: []const Command,

    pub fn init(commands: []const Command) Registry {
        return .{ .commands = commands };
    }

    pub fn find(self: Registry, name: []const u8) ?Command {
        for (self.commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
        }
        return null;
    }
};

// ───────── tests ─────────

const testing = std.testing;

test "parse: returns null for non-slash" {
    try testing.expect(parse("hello world") == null);
    try testing.expect(parse("") == null);
    try testing.expect(parse("/") == null);
}

test "parse: bare command without args" {
    const p = parse("/help").?;
    try testing.expectEqualStrings("help", p.name);
    try testing.expectEqualStrings("", p.args);
}

test "parse: command with single arg" {
    const p = parse("/model claude-sonnet-4-6").?;
    try testing.expectEqualStrings("model", p.name);
    try testing.expectEqualStrings("claude-sonnet-4-6", p.args);
}

test "parse: command with multi-word args (preserves internal spacing)" {
    const p = parse("/system you are a tersa  bot").?;
    try testing.expectEqualStrings("system", p.name);
    try testing.expectEqualStrings("you are a tersa  bot", p.args);
}

test "parse: collapses whitespace between name and args" {
    const p = parse("/system    be terse").?;
    try testing.expectEqualStrings("system", p.name);
    try testing.expectEqualStrings("be terse", p.args);
}

test "parse: strips trailing whitespace" {
    const p = parse("/save myname   ").?;
    try testing.expectEqualStrings("save", p.name);
    try testing.expectEqualStrings("myname", p.args);
}

test "parse: strips trailing newline" {
    const p = parse("/clear\n").?;
    try testing.expectEqualStrings("clear", p.name);
    try testing.expectEqualStrings("", p.args);
}

test "parse: handles tab as separator" {
    const p = parse("/cost\textra").?;
    try testing.expectEqualStrings("cost", p.name);
    try testing.expectEqualStrings("extra", p.args);
}

fn dummyHandler(_: *anyopaque, _: []const u8) anyerror!Action {
    return .handled;
}

test "registry: find returns matching command" {
    const cmds = [_]Command{
        .{ .name = "help", .description = "show help", .handler = dummyHandler },
        .{ .name = "exit", .description = "leave repl", .handler = dummyHandler },
    };
    const reg = Registry.init(&cmds);
    try testing.expect(reg.find("help") != null);
    try testing.expect(reg.find("exit") != null);
    try testing.expect(reg.find("nope") == null);
}

test "registry: find is case-sensitive" {
    const cmds = [_]Command{
        .{ .name = "Help", .description = "", .handler = dummyHandler },
    };
    const reg = Registry.init(&cmds);
    try testing.expect(reg.find("help") == null);
    try testing.expect(reg.find("Help") != null);
}
