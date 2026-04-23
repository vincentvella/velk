const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");

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
            _ = api_key; // phase 2 will use this for the request

            try w.print("(phase 2 will send the request)\n", .{});
            try w.print("  model:      {s}\n", .{opts.model});
            try w.print("  max_tokens: {d}\n", .{opts.max_tokens});
            if (opts.system) |s| try w.print("  system:     {s}\n", .{s});
            try w.print("  prompt:     {s}\n", .{opts.prompt});
            try w.flush();
        },
    }
}
