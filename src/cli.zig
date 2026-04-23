const std = @import("std");

pub const default_model = "claude-opus-4-7";
pub const default_max_tokens: u32 = 4096;

pub const Options = struct {
    prompt: []const u8,
    model: []const u8 = default_model,
    system: ?[]const u8 = null,
    max_tokens: u32 = default_max_tokens,
};

pub const ParseError = struct {
    message: []const u8,
    arg: ?[]const u8 = null,
};

pub const Action = union(enum) {
    help,
    version,
    run: Options,
    parse_error: ParseError,
};

pub fn parse(args: []const []const u8) Action {
    if (args.len == 0) {
        return errAction("missing argv[0]", null);
    }

    var opts: Options = .{ .prompt = "" };
    var prompt: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (eql(arg, "--help") or eql(arg, "-h")) return .help;
        if (eql(arg, "--version") or eql(arg, "-V")) return .version;

        if (eql(arg, "--model") or eql(arg, "-m")) {
            const v = nextValue(args, &i) orelse return errAction("missing value for", arg);
            opts.model = v;
            continue;
        }
        if (eql(arg, "--system") or eql(arg, "-s")) {
            const v = nextValue(args, &i) orelse return errAction("missing value for", arg);
            opts.system = v;
            continue;
        }
        if (eql(arg, "--max-tokens")) {
            const v = nextValue(args, &i) orelse return errAction("missing value for", arg);
            opts.max_tokens = std.fmt.parseInt(u32, v, 10) catch
                return errAction("invalid integer for --max-tokens", v);
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            return errAction("unknown flag", arg);
        }

        if (prompt != null) return errAction("unexpected extra positional", arg);
        prompt = arg;
    }

    if (prompt) |p| {
        opts.prompt = p;
        return .{ .run = opts };
    }
    // No flags and no prompt: bare `velk` shows help.
    // Flags but no prompt: user intent was clear, surface a real error.
    if (args.len <= 1) return .help;
    return errAction("missing prompt", null);
}

pub fn printHelp(w: anytype) !void {
    try w.print(
        \\velk — terminal AI harness
        \\
        \\Usage: velk [options] <prompt>
        \\
        \\Options:
        \\  -m, --model <id>      model id (default: {s})
        \\  -s, --system <text>   system prompt
        \\      --max-tokens <n>  max tokens to generate (default: {d})
        \\  -h, --help            show this help
        \\  -V, --version         show version
        \\
        \\Environment:
        \\  ANTHROPIC_API_KEY     required to make API calls
        \\
    , .{ default_model, default_max_tokens });
}

pub fn printVersion(w: anytype, version: []const u8) !void {
    try w.print("velk {s}\n", .{version});
}

pub fn printParseError(w: anytype, err: ParseError) !void {
    if (err.arg) |a| {
        try w.print("velk: {s}: {s}\n", .{ err.message, a });
    } else {
        try w.print("velk: {s}\n", .{err.message});
    }
    try w.print("\nRun 'velk --help' for usage.\n", .{});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nextValue(args: []const []const u8, i: *usize) ?[]const u8 {
    i.* += 1;
    if (i.* >= args.len) return null;
    return args[i.*];
}

fn errAction(message: []const u8, arg: ?[]const u8) Action {
    return .{ .parse_error = .{ .message = message, .arg = arg } };
}

// ───────── tests ─────────

const testing = std.testing;

fn expectRun(action: Action) !Options {
    return switch (action) {
        .run => |o| o,
        else => error.TestUnexpectedResult,
    };
}

fn expectParseError(action: Action) !ParseError {
    return switch (action) {
        .parse_error => |e| e,
        else => error.TestUnexpectedResult,
    };
}

test "parse: --help returns help" {
    try testing.expect(parse(&.{ "velk", "--help" }) == .help);
}

test "parse: -h returns help" {
    try testing.expect(parse(&.{ "velk", "-h" }) == .help);
}

test "parse: --version returns version" {
    try testing.expect(parse(&.{ "velk", "--version" }) == .version);
}

test "parse: -V returns version" {
    try testing.expect(parse(&.{ "velk", "-V" }) == .version);
}

test "parse: no args returns help" {
    try testing.expect(parse(&.{"velk"}) == .help);
}

test "parse: positional prompt with defaults" {
    const o = try expectRun(parse(&.{ "velk", "hello world" }));
    try testing.expectEqualStrings("hello world", o.prompt);
    try testing.expectEqualStrings(default_model, o.model);
    try testing.expectEqual(default_max_tokens, o.max_tokens);
    try testing.expectEqual(@as(?[]const u8, null), o.system);
}

test "parse: --model overrides default" {
    const o = try expectRun(parse(&.{ "velk", "--model", "claude-sonnet-4-6", "hi" }));
    try testing.expectEqualStrings("claude-sonnet-4-6", o.model);
    try testing.expectEqualStrings("hi", o.prompt);
}

test "parse: -m short form" {
    const o = try expectRun(parse(&.{ "velk", "-m", "claude-haiku-4-5", "hi" }));
    try testing.expectEqualStrings("claude-haiku-4-5", o.model);
}

test "parse: --system sets system prompt" {
    const o = try expectRun(parse(&.{ "velk", "--system", "be terse", "hi" }));
    try testing.expect(o.system != null);
    try testing.expectEqualStrings("be terse", o.system.?);
}

test "parse: -s short form" {
    const o = try expectRun(parse(&.{ "velk", "-s", "be helpful", "hi" }));
    try testing.expectEqualStrings("be helpful", o.system.?);
}

test "parse: --max-tokens parses integer" {
    const o = try expectRun(parse(&.{ "velk", "--max-tokens", "1024", "hi" }));
    try testing.expectEqual(@as(u32, 1024), o.max_tokens);
}

test "parse: flags in any order before positional" {
    const o = try expectRun(parse(&.{ "velk", "-m", "x", "--max-tokens", "10", "-s", "sys", "p" }));
    try testing.expectEqualStrings("x", o.model);
    try testing.expectEqual(@as(u32, 10), o.max_tokens);
    try testing.expectEqualStrings("sys", o.system.?);
    try testing.expectEqualStrings("p", o.prompt);
}

test "parse: positional before flags" {
    const o = try expectRun(parse(&.{ "velk", "p", "-m", "x" }));
    try testing.expectEqualStrings("p", o.prompt);
    try testing.expectEqualStrings("x", o.model);
}

test "parse: --max-tokens non-numeric errors" {
    const e = try expectParseError(parse(&.{ "velk", "--max-tokens", "abc", "hi" }));
    try testing.expect(std.mem.indexOf(u8, e.message, "invalid integer") != null);
}

test "parse: missing value for --model errors" {
    const e = try expectParseError(parse(&.{ "velk", "--model" }));
    try testing.expectEqualStrings("--model", e.arg.?);
}

test "parse: missing value for -s errors" {
    const e = try expectParseError(parse(&.{ "velk", "-s" }));
    try testing.expectEqualStrings("-s", e.arg.?);
}

test "parse: unknown flag errors" {
    const e = try expectParseError(parse(&.{ "velk", "--frobnicate", "hi" }));
    try testing.expectEqualStrings("--frobnicate", e.arg.?);
}

test "parse: extra positional errors" {
    const e = try expectParseError(parse(&.{ "velk", "first", "second" }));
    try testing.expectEqualStrings("second", e.arg.?);
}

test "parse: flags without prompt errors (not help)" {
    const e = try expectParseError(parse(&.{ "velk", "--max-tokens", "10000" }));
    try testing.expectEqualStrings("missing prompt", e.message);
}

test "parse: -m without prompt errors" {
    const e = try expectParseError(parse(&.{ "velk", "-m", "claude-sonnet-4-6" }));
    try testing.expectEqualStrings("missing prompt", e.message);
}
