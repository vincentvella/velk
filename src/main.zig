const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");
const anthropic = @import("anthropic.zig");
const tool = @import("tool.zig");
const agent = @import("agent.zig");

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

            const tools: []const tool.Tool = &.{try tool.buildEcho(arena)};

            agent.run(arena, &client, w, errw, .{
                .model = opts.model,
                .max_tokens = opts.max_tokens,
                .system = opts.system,
                .prompt = opts.prompt,
                .tools = tools,
            }) catch |err| {
                try renderClientError(errw, err, &client);
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
