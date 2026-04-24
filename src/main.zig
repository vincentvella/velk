const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");
const provider_mod = @import("provider.zig");
const anthropic = @import("anthropic.zig");
const openai = @import("openai.zig");
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

    fn onTurnEnd(ctx: ?*anyopaque, usage: provider_mod.Usage) anyerror!void {
        const self = cast(ctx);
        if (self.printed_text) {
            try self.text_out.writeAll("\n");
            try self.text_out.flush();
        }
        self.printed_text = false;
        if (usage.input_tokens == 0 and usage.output_tokens == 0) return;
        try self.progress_out.print("[tokens: {d} in / {d} out", .{ usage.input_tokens, usage.output_tokens });
        if (usage.cache_read_tokens > 0 or usage.cache_creation_tokens > 0) {
            try self.progress_out.print(" · cache {d} read / {d} write", .{ usage.cache_read_tokens, usage.cache_creation_tokens });
        }
        try self.progress_out.writeAll("]\n");
        try self.progress_out.flush();
    }
};

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
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

/// Backing storage for whichever provider's client we instantiate. Only
/// one variant is live per process; the unused one stays undefined.
const ProviderHolder = union(enum) {
    anthropic: struct {
        client: anthropic.Client,
        adapter: anthropic.Adapter,
    },
    openai: struct {
        client: openai.Client,
        adapter: openai.Adapter,
    },

    fn provider(self: *ProviderHolder) provider_mod.Provider {
        return switch (self.*) {
            .anthropic => |*h| h.adapter.provider(),
            .openai => |*h| h.adapter.provider(),
        };
    }

    fn deinit(self: *ProviderHolder) void {
        switch (self.*) {
            .anthropic => |*h| h.client.deinit(),
            .openai => |*h| h.client.deinit(),
        }
    }
};

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
            const holder = setupProvider(arena, init, errw, opts) catch |err| {
                try errw.print("velk: {s}\n", .{@errorName(err)});
                try errw.flush();
                std.process.exit(1);
            };
            defer holder.deinit();
            const provider = holder.provider();

            const settings = try arena.create(tools.Settings);
            settings.* = .{ .io = init.io, .unsafe = opts.unsafe };
            const tool_set = try tools.buildAll(arena, settings);

            const model = opts.model orelse defaultModelFor(opts.provider);

            try printProviderBanner(errw, init.environ_map, opts.provider, model);

            var sess: session.Session = .init(arena, provider, .{
                .model = model,
                .max_tokens = opts.max_tokens,
                .system = opts.system,
                .tools = tool_set,
            });

            if (opts.prompt) |p| {
                var plain: PlainSink = .{ .text_out = w, .progress_out = errw, .arena = arena };
                sess.ask(p, plain.sink()) catch |err| {
                    try renderProviderError(errw, err, provider);
                    try errw.flush();
                    std.process.exit(1);
                };
                return;
            }

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

const SetupError = error{MissingApiKey} || std.mem.Allocator.Error;

fn setupProvider(
    arena: std.mem.Allocator,
    init: std.process.Init,
    errw: *Io.Writer,
    opts: cli.Options,
) !*ProviderHolder {
    const holder = try arena.create(ProviderHolder);
    switch (opts.provider) {
        .anthropic => {
            const key = init.environ_map.get("ANTHROPIC_API_KEY") orelse {
                try errw.print("velk: ANTHROPIC_API_KEY environment variable is not set.\n", .{});
                try errw.flush();
                return SetupError.MissingApiKey;
            };
            holder.* = .{ .anthropic = .{
                .client = anthropic.Client.init(init.gpa, init.io, key),
                .adapter = undefined,
            } };
            holder.anthropic.adapter = anthropic.Adapter.init(arena, &holder.anthropic.client);
        },
        .openai => {
            const key = init.environ_map.get("OPENAI_API_KEY") orelse {
                try errw.print("velk: OPENAI_API_KEY environment variable is not set.\n", .{});
                try errw.flush();
                return SetupError.MissingApiKey;
            };
            const base = init.environ_map.get("OPENAI_BASE_URL");
            holder.* = .{ .openai = .{
                .client = openai.Client.init(init.gpa, init.io, key, base),
                .adapter = undefined,
            } };
            holder.openai.adapter = openai.Adapter.init(arena, &holder.openai.client);
        },
        .openrouter => {
            const key = init.environ_map.get("OPENROUTER_API_KEY") orelse {
                try errw.print("velk: OPENROUTER_API_KEY environment variable is not set.\n", .{});
                try errw.flush();
                return SetupError.MissingApiKey;
            };
            const base = init.environ_map.get("OPENAI_BASE_URL") orelse "https://openrouter.ai/api/v1/chat/completions";
            holder.* = .{ .openai = .{
                .client = openai.Client.init(init.gpa, init.io, key, base),
                .adapter = undefined,
            } };
            holder.openai.adapter = openai.Adapter.init(arena, &holder.openai.client);
        },
    }
    return holder;
}

fn defaultModelFor(p: cli.Provider) []const u8 {
    return switch (p) {
        .anthropic => cli.default_model,
        .openai => cli.default_openai_model,
        .openrouter => "openai/gpt-5",
    };
}

fn envVarFor(p: cli.Provider) []const u8 {
    return switch (p) {
        .anthropic => "ANTHROPIC_API_KEY",
        .openai => "OPENAI_API_KEY",
        .openrouter => "OPENROUTER_API_KEY",
    };
}

/// Print one stderr line confirming what we're about to talk to. The
/// API key is redacted to first-4 + last-4 so the user can sanity-check
/// they picked up the right credential without leaking it on screen.
fn printProviderBanner(
    errw: *Io.Writer,
    env_map: *std.process.Environ.Map,
    p: cli.Provider,
    model: []const u8,
) !void {
    const var_name = envVarFor(p);
    const key = env_map.get(var_name) orelse "(missing)";
    const redacted = redactKey(key);
    try errw.print("velk: {s} · {s} · {s}={s}\n", .{ @tagName(p), model, var_name, redacted });
    try errw.flush();
}

fn redactKey(key: []const u8) []const u8 {
    // Keep the first 4 and last 4 chars; ellipsize the middle.
    if (key.len <= 12) return "***";
    var buf: [64]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{s}…{s}", .{ key[0..4], key[key.len - 4 ..] }) catch return "***";
    // bufPrint borrows our local buffer; copy onto a static buffer per
    // call. For a one-line banner this is fine to leak into a small
    // process-lifetime constant.
    const Static = struct {
        var slot: [64]u8 = undefined;
    };
    @memcpy(Static.slot[0..out.len], out);
    return Static.slot[0..out.len];
}

fn renderProviderError(errw: *Io.Writer, err: anyerror, provider: provider_mod.Provider) !void {
    switch (err) {
        agent.Error.IterationBudgetExceeded => {
            try errw.print("velk: hit iteration budget without end_turn\n", .{});
            return;
        },
        else => {},
    }

    const body = provider.lastErrorBody() orelse {
        try errw.print("velk: {s}\n", .{@errorName(err)});
        return;
    };

    // Both Anthropic and OpenAI nest the user-facing message at
    // `error.message`. Try to extract it for a one-line message; on
    // any parse failure fall back to dumping the raw body.
    const Shape = struct {
        @"error": struct {
            type: ?[]const u8 = null,
            message: ?[]const u8 = null,
        } = .{},
    };
    const parsed = std.json.parseFromSlice(Shape, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try errw.print("velk: API error\n{s}\n", .{body});
        return;
    };
    defer parsed.deinit();
    const msg = parsed.value.@"error".message orelse {
        try errw.print("velk: API error\n{s}\n", .{body});
        return;
    };
    if (parsed.value.@"error".type) |t| {
        try errw.print("velk: API error ({s}): {s}\n", .{ t, msg });
    } else {
        try errw.print("velk: API error: {s}\n", .{msg});
    }
}
