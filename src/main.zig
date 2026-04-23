const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");
const anthropic = @import("anthropic.zig");

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

            const req: anthropic.MessagesRequest = .{
                .model = opts.model,
                .max_tokens = opts.max_tokens,
                .system = opts.system,
                .messages = &.{.{ .role = "user", .content = opts.prompt }},
            };

            var stream_ctx: StreamCtx = .{ .w = w, .gpa = init.gpa };
            client.streamMessage(req, &stream_ctx, StreamCtx.onEvent) catch |err| {
                if (stream_ctx.wrote_any) try w.writeAll("\n");
                try w.flush();
                try renderClientError(errw, err, &client);
                try errw.flush();
                std.process.exit(1);
            };

            if (stream_ctx.err) |e| return e;
            if (stream_ctx.wrote_any) try w.writeAll("\n");
            try w.flush();
        },
    }
}

const StreamCtx = struct {
    w: *Io.Writer,
    gpa: std.mem.Allocator,
    wrote_any: bool = false,
    err: ?anyerror = null,

    fn onEvent(self: *StreamCtx, ev: anthropic.sse.Event) anyerror!void {
        // Ignore events the user doesn't see; only text deltas reach stdout.
        // We swallow JSON parse errors per-event so a single malformed delta
        // doesn't tear down the stream — but we remember the first one to
        // surface after the stream completes.
        if (std.mem.eql(u8, ev.name, "content_block_delta")) {
            const parsed = std.json.parseFromSlice(
                anthropic.types.ContentBlockDelta,
                self.gpa,
                ev.data,
                .{ .ignore_unknown_fields = true },
            ) catch |e| {
                if (self.err == null) self.err = e;
                return;
            };
            defer parsed.deinit();
            if (parsed.value.delta.text) |t| {
                try self.w.writeAll(t);
                try self.w.flush();
                self.wrote_any = true;
            }
        } else if (std.mem.eql(u8, ev.name, "error")) {
            const parsed = std.json.parseFromSlice(
                anthropic.types.StreamError,
                self.gpa,
                ev.data,
                .{ .ignore_unknown_fields = true },
            ) catch return;
            defer parsed.deinit();
            // Stash via err so main can surface after teardown.
            self.err = error.StreamingApiError;
            // Best-effort: write the message so the user sees it inline.
            std.debug.print("\nvelk: API error ({s}): {s}\n", .{
                parsed.value.@"error".type,
                parsed.value.@"error".message,
            });
        }
    }
};

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
