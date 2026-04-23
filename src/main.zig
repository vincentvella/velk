const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");
const anthropic = @import("anthropic.zig");

pub fn main(init: std.process.Init) !void {
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

            const req: anthropic.MessagesRequest = .{
                .model = opts.model,
                .max_tokens = opts.max_tokens,
                .system = opts.system,
                .messages = &.{.{ .role = "user", .content = opts.prompt }},
            };

            var result = client.createMessage(req) catch |err| {
                try renderClientError(errw, err, &client);
                try errw.flush();
                std.process.exit(1);
            };
            defer result.deinit();

            const resp = result.value();
            for (resp.content) |block| {
                if (block.text) |t| try w.writeAll(t);
            }
            try w.writeAll("\n");
            try w.flush();
        },
    }
}

fn renderClientError(errw: *Io.Writer, err: anyerror, client: *const anthropic.Client) !void {
    switch (err) {
        anthropic.Error.ApiError => {
            // Try to parse the captured body as a structured ApiError; if that
            // fails, dump it raw so the user still sees what happened.
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
        else => try errw.print("velk: request failed: {s}\n", .{@errorName(err)}),
    }
}
