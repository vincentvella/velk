const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");
const anthropic = @import("anthropic.zig");
const tool = @import("tool.zig");
const tools = @import("tools.zig");
const agent = @import("agent.zig");
const session = @import("session.zig");
const tui = @import("tui.zig");

/// Sink that mirrors the original plain-CLI behavior: assistant text to
/// stdout (flushed per delta), tool calls/results to stderr.
const PlainSink = struct {
    text_out: *Io.Writer,
    progress_out: *Io.Writer,
    arena: std.mem.Allocator,
    printed_text: bool = false,

    fn sink(self: *PlainSink) agent.Sink {
        return .{
            .ctx = self,
            .onText = onText,
            .onToolCall = onToolCall,
            .onToolResult = onToolResult,
            .onTurnEnd = onTurnEnd,
        };
    }

    fn cast(ctx: ?*anyopaque) *PlainSink {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = cast(ctx);
        try self.text_out.writeAll(text);
        try self.text_out.flush();
        self.printed_text = true;
    }

    fn onToolCall(ctx: ?*anyopaque, name: []const u8, input_json: []const u8) anyerror!void {
        const self = cast(ctx);
        var preview = input_json;
        if (preview.len > 200) preview = preview[0..200];
        try self.progress_out.print("→ {s}({s})\n", .{ name, preview });
        try self.progress_out.flush();
    }

    fn onToolResult(ctx: ?*anyopaque, text: []const u8, is_error: bool) anyerror!void {
        const self = cast(ctx);
        var preview = text;
        if (preview.len > 200) preview = preview[0..200];
        const ellipsis: []const u8 = if (text.len > 200) "…" else "";
        const prefix: []const u8 = if (is_error) "← (error) " else "← ";
        try self.progress_out.print("{s}{s}{s}\n", .{ prefix, preview, ellipsis });
        try self.progress_out.flush();
    }

    fn onTurnEnd(ctx: ?*anyopaque) anyerror!void {
        const self = cast(ctx);
        if (self.printed_text) {
            try self.text_out.writeAll("\n");
            try self.text_out.flush();
        }
        self.printed_text = false;
    }
};

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    // Signal-safe only: write a final newline so the shell prompt lands on a
    // fresh line, then _exit (NOT std.process.exit, which runs cleanup that
    // is not async-safe). 130 = 128 + SIGINT, the conventional shell code.
    _ = std.c.write(1, "\n", 1);
    std.c._exit(130);
}

fn installSigIntHandler() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
}

pub fn main(init: std.process.Init) !void {
    installSigIntHandler();

    var stdout_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const w = &stdout.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const errw = &stderr.interface;

    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |a, i| argv[i] = a;

    switch (cli.parse(argv)) {
        .help => {
            try cli.printHelp(w);
            try w.flush();
        },
        .version => {
            try cli.printVersion(w, velk.version);
            try w.flush();
        },
        .parse_error => |e| {
            try cli.printParseError(errw, e);
            try errw.flush();
            std.process.exit(2);
        },
        .run => |opts| {
            const api_key = init.environ_map.get("ANTHROPIC_API_KEY") orelse {
                try errw.print("velk: ANTHROPIC_API_KEY environment variable is not set.\n", .{});
                try errw.flush();
                std.process.exit(1);
            };

            var client: anthropic.Client = .init(init.gpa, init.io, api_key);
            defer client.deinit();

            const settings = try arena.create(tools.Settings);
            settings.* = .{ .io = init.io, .unsafe = opts.unsafe };
            const tool_set = try tools.buildAll(arena, settings);

            var sess: session.Session = .init(arena, &client, .{
                .model = opts.model,
                .max_tokens = opts.max_tokens,
                .system = opts.system,
                .tools = tool_set,
            });

            if (opts.prompt) |p| {
                // One-shot mode: run a single turn and exit.
                var plain: PlainSink = .{ .text_out = w, .progress_out = errw, .arena = arena };
                sess.ask(p, plain.sink()) catch |err| {
                    try renderClientError(errw, err, &client);
                    try errw.flush();
                    std.process.exit(1);
                };
                return;
            }

            // No prompt: launch the interactive REPL unless explicitly
            // disabled or not connected to a TTY.
            const stdin_is_tty = (std.Io.File.stdin().isTty(init.io)) catch false;
            if (opts.no_tui or !stdin_is_tty) {
                try cli.printHelp(w);
                try w.flush();
                return;
            }

            tui.run(arena, init.io, init.gpa, init.environ_map, &sess) catch |err| {
                try errw.print("velk: {s}\n", .{@errorName(err)});
                try errw.flush();
                std.process.exit(1);
            };
        },
    }
}

fn renderClientError(errw: *Io.Writer, err: anyerror, client: *const anthropic.Client) !void {
    switch (err) {
        anthropic.Error.ApiError => {
            const body = client.last_error_body orelse "";
            const parsed = std.json.parseFromSlice(
                anthropic.ApiError,
                client.gpa,
                body,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try errw.print("velk: API error\n{s}\n", .{body});
                return;
            };
            defer parsed.deinit();
            try errw.print("velk: API error ({s}): {s}\n", .{
                parsed.value.@"error".type,
                parsed.value.@"error".message,
            });
        },
        anthropic.Error.ResponseParseFailure => {
            try errw.print("velk: could not parse API response\n{s}\n", .{client.last_error_body orelse ""});
        },
        agent.Error.IterationBudgetExceeded => {
            try errw.print("velk: hit iteration budget without end_turn\n", .{});
        },
        else => try errw.print("velk: request failed: {s}\n", .{@errorName(err)}),
    }
}
