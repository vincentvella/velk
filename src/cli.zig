const std = @import("std");

pub const default_model = "claude-opus-4-7";
pub const default_openai_model = "gpt-5";
pub const default_max_tokens: u32 = 4096;

pub const Provider = enum { anthropic, openai, openrouter };
pub const default_provider: Provider = .anthropic;

pub const Options = struct {
    /// Optional one-shot prompt. When null, the agent is launched in
    /// REPL mode (TUI if stdin is a TTY).
    prompt: ?[]const u8 = null,
    /// Model id. If null, the provider's default is used.
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    max_tokens: u32 = default_max_tokens,
    provider: Provider = default_provider,
    /// Drop path-safety checks in built-in tools.
    unsafe: bool = false,
    /// Force plain (non-TUI) output even when stdin is a TTY.
    no_tui: bool = false,
    /// Optional session name. When set, message history is loaded from
    /// (and saved back to) ~/.local/share/velk/sessions/<name>.json.
    session: ?[]const u8 = null,
    /// Repeatable: each entry is a shell command line for an MCP
    /// server to spawn. Parsed at the call site (split on whitespace).
    mcp_servers: []const []const u8 = &.{},
    /// Dump request envelopes (model, sys/tool counts, body length) to
    /// stderr per turn. Useful for cache-window and prompt debugging.
    debug: bool = false,
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

/// Static storage for repeated `--mcp` values. Module-scope so the
/// returned slice on `Options.mcp_servers` outlives the parser's
/// stack frame (slices into a function-local array would dangle the
/// moment `parse` returns). 16 is overkill for any reasonable user.
var mcp_storage: [16][]const u8 = undefined;

pub fn parse(args: []const []const u8) Action {
    if (args.len == 0) {
        return errAction("missing argv[0]", null);
    }

    var opts: Options = .{};
    var prompt: ?[]const u8 = null;
    var mcp_count: usize = 0;

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
        if (eql(arg, "--unsafe")) {
            opts.unsafe = true;
            continue;
        }
        if (eql(arg, "--debug")) {
            opts.debug = true;
            continue;
        }
        if (eql(arg, "--no-tui")) {
            opts.no_tui = true;
            continue;
        }
        if (eql(arg, "--session") or eql(arg, "-S")) {
            const v = nextValue(args, &i) orelse return errAction("missing value for", arg);
            opts.session = v;
            continue;
        }
        if (eql(arg, "--mcp")) {
            const v = nextValue(args, &i) orelse return errAction("missing value for", arg);
            if (mcp_count >= mcp_storage.len) return errAction("too many --mcp servers (max 16)", null);
            mcp_storage[mcp_count] = v;
            mcp_count += 1;
            continue;
        }
        if (eql(arg, "--provider") or eql(arg, "-p")) {
            const v = nextValue(args, &i) orelse return errAction("missing value for", arg);
            if (eql(v, "anthropic")) opts.provider = .anthropic
            else if (eql(v, "openai")) opts.provider = .openai
            else if (eql(v, "openrouter")) opts.provider = .openrouter
            else return errAction("unknown provider (expected anthropic|openai|openrouter)", v);
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            return errAction("unknown flag", arg);
        }

        if (prompt != null) return errAction("unexpected extra positional", arg);
        prompt = arg;
    }

    if (prompt) |p| opts.prompt = p;
    if (mcp_count > 0) opts.mcp_servers = mcp_storage[0..mcp_count];
    return .{ .run = opts };
}

pub fn printHelp(w: anytype) !void {
    try w.print(
        \\velk — terminal AI harness
        \\
        \\Usage: velk [options] [prompt]
        \\
        \\Without a prompt, velk launches an interactive REPL (TUI).
        \\With a prompt, velk runs one turn and exits.
        \\
        \\Options:
        \\  -p, --provider <id>   anthropic (default), openai, openrouter
        \\  -m, --model <id>      model id (provider-default if omitted)
        \\  -s, --system <text>   system prompt
        \\      --max-tokens <n>  max tokens to generate (default: {d})
        \\      --unsafe          allow tools to access paths outside CWD
        \\      --no-tui          force plain output (no TUI)
        \\      --debug           dump request envelope per turn to stderr
        \\  -S, --session <name>  load/save chat history under
        \\                        $XDG_DATA_HOME/velk/sessions/<name>.json
        \\      --mcp <command>   spawn an MCP server (repeatable);
        \\                        e.g. --mcp 'npx @modelcontextprotocol/server-filesystem /tmp'
        \\  -h, --help            show this help
        \\  -V, --version         show version
        \\
        \\Environment:
        \\  ANTHROPIC_API_KEY     required for --provider anthropic (default: {s})
        \\  OPENAI_API_KEY        required for --provider openai
        \\  OPENROUTER_API_KEY    required for --provider openrouter
        \\  ANTHROPIC_BASE_URL    optional override for anthropic base URL (e.g. mock server)
        \\  OPENAI_BASE_URL       optional override for openai/openrouter base URL
        \\
    , .{ default_max_tokens, default_model });
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

test "parse: no args returns run with null prompt (REPL intent)" {
    const o = try expectRun(parse(&.{"velk"}));
    try testing.expect(o.prompt == null);
}

test "parse: positional prompt with defaults" {
    const o = try expectRun(parse(&.{ "velk", "hello world" }));
    try testing.expectEqualStrings("hello world", o.prompt.?);
    try testing.expectEqual(@as(?[]const u8, null), o.model);
    try testing.expectEqual(default_max_tokens, o.max_tokens);
    try testing.expectEqual(@as(?[]const u8, null), o.system);
    try testing.expectEqual(default_provider, o.provider);
    try testing.expect(!o.no_tui);
    try testing.expect(!o.unsafe);
}

test "parse: --model overrides default" {
    const o = try expectRun(parse(&.{ "velk", "--model", "claude-sonnet-4-6", "hi" }));
    try testing.expectEqualStrings("claude-sonnet-4-6", o.model.?);
    try testing.expectEqualStrings("hi", o.prompt.?);
}

test "parse: -m short form" {
    const o = try expectRun(parse(&.{ "velk", "-m", "claude-haiku-4-5", "hi" }));
    try testing.expectEqualStrings("claude-haiku-4-5", o.model.?);
}

test "parse: --provider openai" {
    const o = try expectRun(parse(&.{ "velk", "--provider", "openai", "hi" }));
    try testing.expectEqual(Provider.openai, o.provider);
}

test "parse: -p short form for provider" {
    const o = try expectRun(parse(&.{ "velk", "-p", "openrouter", "hi" }));
    try testing.expectEqual(Provider.openrouter, o.provider);
}

test "parse: unknown provider errors" {
    const e = try expectParseError(parse(&.{ "velk", "--provider", "googly", "hi" }));
    try testing.expect(std.mem.indexOf(u8, e.message, "unknown provider") != null);
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

test "parse: --no-tui flag" {
    const o = try expectRun(parse(&.{ "velk", "--no-tui" }));
    try testing.expect(o.no_tui);
    try testing.expect(o.prompt == null);
}

test "parse: --unsafe flag" {
    const o = try expectRun(parse(&.{ "velk", "--unsafe", "hi" }));
    try testing.expect(o.unsafe);
}

test "parse: --debug flag" {
    const o = try expectRun(parse(&.{ "velk", "--debug", "hi" }));
    try testing.expect(o.debug);
}

test "parse: flags in any order before positional" {
    const o = try expectRun(parse(&.{ "velk", "-m", "x", "--max-tokens", "10", "-s", "sys", "p" }));
    try testing.expectEqualStrings("x", o.model.?);
    try testing.expectEqual(@as(u32, 10), o.max_tokens);
    try testing.expectEqualStrings("sys", o.system.?);
    try testing.expectEqualStrings("p", o.prompt.?);
}

test "parse: positional before flags" {
    const o = try expectRun(parse(&.{ "velk", "p", "-m", "x" }));
    try testing.expectEqualStrings("p", o.prompt.?);
    try testing.expectEqualStrings("x", o.model.?);
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
