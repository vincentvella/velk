const std = @import("std");
const Io = std.Io;
const velk = @import("velk");
const cli = @import("cli.zig");
const provider_mod = @import("provider.zig");
const anthropic = @import("anthropic.zig");
const openai = @import("openai.zig");
const tool = @import("tool.zig");
const tools = @import("tools.zig");
const approval_mod = @import("approval.zig");
const settings_mod = @import("settings.zig");
const permissions_mod = @import("permissions.zig");
const workspace_mod = @import("workspace.zig");
const mentions_mod = @import("mentions.zig");
const repo_map_mod = @import("repo_map.zig");
const hooks_mod = @import("hooks.zig");
const todos_mod = @import("todos.zig");
const ask_mod = @import("ask.zig");
const skills_mod = @import("skills.zig");
const memory_mod = @import("memory.zig");
const styles_mod = @import("styles.zig");
const ignore_mod = @import("ignore.zig");
const lockfile = @import("lockfile.zig");
const watch_mod = @import("watch.zig");
const system_prompts = @import("system_prompts.zig");
const agent = @import("agent.zig");
const session = @import("session.zig");
const persist = @import("persist.zig");
const cost = @import("cost.zig");
const mcp = @import("mcp.zig");
const tui = @import("tui.zig");

/// Sink that mirrors the original plain-CLI behavior: assistant text to
/// stdout (flushed per delta), tool calls/results to stderr.
const PlainSink = struct {
    text_out: *Io.Writer,
    progress_out: *Io.Writer,
    arena: std.mem.Allocator,
    model: []const u8,
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
        if (cost.turnCost(self.model, usage)) |c| {
            try self.progress_out.print(" · ${d:.4}", .{c});
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
        .run => |raw_opts| {
            // Layer settings.json defaults underneath the CLI flags.
            // CLI flags WIN — overlaySettings only fills fields the
            // user didn't explicitly set on the command line.
            var file_settings = settings_mod.loadAndMerge(arena, init.io, init.environ_map) catch |err| settings: {
                try errw.print("velk: settings file: {s}\n", .{@errorName(err)});
                try errw.flush();
                break :settings settings_mod.Settings{};
            };
            // Profile overlay: a `-P review` rolls the named profile's
            // Defaults onto the merged settings.defaults BEFORE we
            // apply settings → CLI. Order: profile beats file
            // defaults; CLI flags still win over both.
            var active_profile_tools: []const []const u8 = &.{};
            if (raw_opts.profile) |pname| {
                if (file_settings.findProfileFull(pname)) |prof| {
                    file_settings.applyDefaults(prof.defaults);
                    active_profile_tools = prof.tools;
                    try errw.print("velk: profile '{s}' applied\n", .{pname});
                    try errw.flush();
                } else {
                    try errw.print("velk: profile '{s}' not found in settings.json — using base defaults\n", .{pname});
                    try errw.flush();
                }
            }
            const opts = applySettingsToOptions(arena, raw_opts, file_settings);

            const holder = setupProvider(arena, init, errw, opts) catch |err| {
                try errw.print("velk: {s}\n", .{@errorName(err)});
                try errw.flush();
                std.process.exit(1);
            };
            defer holder.deinit();
            const provider = holder.provider();

            // Approval gate: shared between the agent worker thread and
            // the TUI main thread. The TUI plugs `post_fn` into it; the
            // worker calls `requestApproval` from inside the edit /
            // write_file tools and blocks until the user decides.
            // Headless when post_fn is null (one-shot CLI / --no-tui).
            const approval_gate = try arena.create(approval_mod.ApprovalGate);
            approval_gate.* = approval_mod.ApprovalGate.init(init.gpa, init.io);

            // Resolve permissions mode: CLI flag wins, then
            // settings.json `permissions.mode`, else default.
            const mode_str: ?[]const u8 = opts.mode orelse file_settings.mode;
            const mode: permissions_mod.Mode = if (mode_str) |s| (permissions_mod.Mode.fromString(s) orelse blk: {
                try errw.print("velk: unknown --mode '{s}', falling back to default\n", .{s});
                try errw.flush();
                break :blk .default;
            }) else .default;
            // Trust modes auto-apply via the gate's bypass.
            if (mode.bypassesPrompts()) approval_gate.bypass = true;

            // Todo store. Lives only when running interactively — a
            // one-shot prompt has no surface to show the list, so the
            // tool would just be a black hole. Allocated once in the
            // arena; the worker mutates it and the TUI snapshots.
            const todos_store: ?*todos_mod.Store = if (opts.no_tui or opts.prompt != null) null else blk: {
                const s = try arena.create(todos_mod.Store);
                s.* = todos_mod.Store.init(init.gpa);
                break :blk s;
            };
            // Ask gate. Same restriction as todos — only meaningful
            // when there's a TUI to render the picker.
            const ask_gate: ?*ask_mod.AskGate = if (opts.no_tui or opts.prompt != null) null else blk: {
                const g = try arena.create(ask_mod.AskGate);
                g.* = ask_mod.AskGate.init(init.gpa, init.io);
                break :blk g;
            };

            // Sub-agent runtime. Allocated up-front so the `task`
            // tool can carry a stable back-pointer to it; `tools`,
            // `system`, and `hook_engine` are filled in below once
            // the parent registry and system prompt are settled.
            // Architect/coder split: the sub-agent's default model
            // is `--planner-model` if set, else the parent model.
            // The parent's model is `--model` (winning), or
            // `--coder-model`, or the provider default. Per-call
            // override on the `task` tool still wins over both.
            const parent_model = opts.model orelse opts.coder_model orelse defaultModelFor(opts.provider);
            const sub_default_model = opts.planner_model orelse parent_model;

            const sub_agent = try arena.create(tools.SubAgent);
            sub_agent.* = .{
                .provider = provider,
                .model = sub_default_model,
                .max_tokens = opts.max_tokens,
                .hook_io = init.io,
                .max_iterations = if (opts.max_iterations > 0) opts.max_iterations else 5,
            };

            // Optional .gitignore — read once at startup. Failures
            // (no file, parse error) silently fall back to the
            // hardcoded common-ignore set.
            const gitignore_matcher = ignore_mod.Matcher.fromGitignore(arena, init.io, ".") catch ignore_mod.Matcher.empty();

            // Translate file-settings LSP servers into the
            // tools-runtime mirror (the duplication keeps tools.zig
            // free of a cyclic settings.zig dependency).
            const lsp_runtime: []tools.LspServerConfig = blk: {
                if (file_settings.lsp_servers.len == 0) break :blk &[_]tools.LspServerConfig{};
                const lr = try arena.alloc(tools.LspServerConfig, file_settings.lsp_servers.len);
                for (file_settings.lsp_servers, 0..) |s, i| {
                    lr[i] = .{
                        .extension = s.extension,
                        .command = s.command,
                        .language_id = s.language_id,
                    };
                }
                break :blk lr;
            };

            const settings = try arena.create(tools.Settings);
            settings.* = .{
                .io = init.io,
                .gpa = init.gpa,
                .unsafe = opts.unsafe,
                .approval = approval_gate,
                .mode = mode,
                .include_ignored = opts.include_ignored,
                .env_map = init.environ_map,
                .todos = todos_store,
                .ask = ask_gate,
                .sub_agent = sub_agent,
                .gitignore_matcher = gitignore_matcher,
                .lsp_servers = lsp_runtime,
            };
            const builtin_tools = try tools.buildAll(arena, settings);

            // User-declared shell tools from settings.json. Append
            // after built-ins; refuse on name collision so users
            // can't accidentally shadow `bash` or `read_file`. Each
            // collision surfaces as a startup notice and the offender
            // is dropped, not registered.
            const custom_tools = blk: {
                if (file_settings.custom_tools.len == 0) break :blk &[_]tool.Tool{};
                var ct: std.ArrayList(tool.Tool) = .empty;
                outer: for (file_settings.custom_tools) |spec| {
                    for (builtin_tools) |bt| {
                        if (std.mem.eql(u8, bt.name, spec.name)) {
                            try errw.print("velk: custom tool '{s}' shadows a built-in — skipping\n", .{spec.name});
                            try errw.flush();
                            continue :outer;
                        }
                    }
                    const args_buf = try arena.alloc(tools.CustomToolArg, spec.args.len);
                    for (spec.args, 0..) |a, i| args_buf[i] = .{
                        .name = a.name,
                        .description = a.description,
                        .required = a.required,
                    };
                    const t = tools.buildCustom(arena, settings, .{
                        .name = spec.name,
                        .description = spec.description,
                        .command = spec.command,
                        .args = args_buf,
                        .timeout_ms = spec.timeout_ms,
                        .cwd = spec.cwd,
                    }) catch |e| {
                        try errw.print("velk: custom tool '{s}' build failed: {s}\n", .{ spec.name, @errorName(e) });
                        try errw.flush();
                        continue :outer;
                    };
                    try ct.append(arena, t);
                }
                break :blk ct.items;
            };
            if (custom_tools.len > 0) {
                try errw.print("velk: custom · {d} tool(s) added from settings.json\n", .{custom_tools.len});
                try errw.flush();
            }

            // Spawn any MCP servers the user passed via --mcp <cmd>;
            // their tools merge into the registry alongside built-ins.
            // Copy the cli's mcp_servers into the arena first (the cli
            // parser hands us a slice into its now-dead stack frame).
            var mcp_servers: ?mcp.Servers = null;
            defer if (mcp_servers) |*s| s.deinit(init.io);

            var tool_set: []const tool.Tool = builtin_tools;
            if (custom_tools.len > 0) {
                const merged = try arena.alloc(tool.Tool, tool_set.len + custom_tools.len);
                @memcpy(merged[0..tool_set.len], tool_set);
                @memcpy(merged[tool_set.len..], custom_tools);
                tool_set = merged;
            }
            if (opts.mcp_servers.len > 0) {
                const argvs = try arena.alloc([]const []const u8, opts.mcp_servers.len);
                for (opts.mcp_servers, 0..) |cmd, i| {
                    const owned_cmd = try arena.dupe(u8, cmd);
                    argvs[i] = try splitWhitespace(arena, owned_cmd);
                }

                const servers = try mcp.start(arena, init.gpa, init.io, argvs);
                mcp_servers = servers;

                if (servers.tools.len > 0) {
                    const merged = try arena.alloc(tool.Tool, tool_set.len + servers.tools.len);
                    @memcpy(merged[0..tool_set.len], tool_set);
                    @memcpy(merged[tool_set.len..], servers.tools);
                    tool_set = merged;
                }

                try errw.print("velk: mcp · {d} server(s) · {d} tool(s) added\n", .{ servers.clients.items.len, servers.tools.len });
                try errw.flush();
            }

            // Profile tool allowlist: filter the registry to just the
            // names the active profile permits. Skips silently when
            // the active profile has no `tools:` field — only an
            // explicit, non-empty list is treated as a constraint.
            // Names that don't match anything in the registry are
            // surfaced as a warning so a typoed entry doesn't silently
            // narrow the toolset to the empty set.
            if (active_profile_tools.len > 0) {
                const before = tool_set.len;
                var filtered: std.ArrayList(tool.Tool) = .empty;
                for (active_profile_tools) |allowed| {
                    var matched = false;
                    for (tool_set) |t| {
                        if (std.mem.eql(u8, t.name, allowed)) {
                            try filtered.append(arena, t);
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        try errw.print("velk: profile tool '{s}' not registered — ignoring\n", .{allowed});
                        try errw.flush();
                    }
                }
                tool_set = filtered.items;
                try errw.print("velk: profile tools · {d} → {d}\n", .{ before, tool_set.len });
                try errw.flush();
            }

            const model = parent_model;

            try printProviderBanner(errw, init.environ_map, opts.provider, model);

            // Surface the architect/coder split if the user asked
            // for two models. Banner reports both so the user can
            // sanity-check which side is which.
            if (opts.planner_model != null or opts.coder_model != null) {
                try errw.print(
                    "velk: architect/coder split · coder={s} · planner={s} (used by `task` tool)\n",
                    .{ parent_model, sub_default_model },
                );
                try errw.flush();
            }

            // Resolve the *base* system prompt before layering on
            // project context / skills / repo-map. Precedence:
            //   1. `--system <text>`     replaces everything
            //   2. `--no-system-prompt`  drops the default
            //   3. otherwise             velk's built-in default
            const base_system: ?[]const u8 = if (opts.system) |s|
                s
            else if (opts.no_system_prompt)
                null
            else
                system_prompts.default;

            // Project-context auto-load: walk up from CWD looking
            // for a git repo root, then look for AGENTS.md /
            // VELK.md / CLAUDE.md in either CWD or root and prepend
            // the contents to the system prompt. Failures here are
            // non-fatal — we just run with the base prompt as-is.
            const repo_root = workspace_mod.findRepoRoot(arena, init.io) catch null;
            const ctx_loaded = workspace_mod.findContextFile(arena, init.io, repo_root) catch null;
            var final_system: ?[]const u8 = if (ctx_loaded) |loaded| blk: {
                try errw.print("velk: auto-loaded {s} ({d} bytes)\n", .{ loaded.path, loaded.contents.len });
                try errw.flush();
                break :blk try workspace_mod.buildSystemPrompt(arena, base_system, loaded.contents, loaded.path);
            } else base_system;

            // Skills catalog: walk the discovery roots, prepend a
            // catalog summary so the model knows what's available.
            // Bodies stay on disk; the model reads via `read_file`
            // when it picks one. Failures are silent — a typo'd
            // SKILL.md in someone's home shouldn't break a session.
            const skill_list = skills_mod.loadAll(arena, init.io, init.environ_map) catch &.{};
            if (skill_list.len > 0) {
                const catalog = skills_mod.formatCatalog(arena, skill_list) catch "";
                if (catalog.len > 0) {
                    final_system = try workspace_mod.buildSystemPrompt(arena, final_system, catalog, "skills");
                    try errw.print("velk: {d} skill(s) loaded\n", .{skill_list.len});
                    try errw.flush();
                }
            }

            // Memdir index: surface every long-term-memory topic +
            // size at the top of the prompt so the model knows what
            // it has stored before the first turn. Bodies stay on
            // disk; the model fetches via `read_memory` when needed.
            // Failures are silent — a bad XDG path shouldn't break
            // the session.
            const mem_entries = memory_mod.list(arena, init.io, init.environ_map) catch &.{};
            if (mem_entries.len > 0) {
                const mem_index = memory_mod.formatIndex(arena, mem_entries) catch "";
                if (mem_index.len > 0) {
                    final_system = try workspace_mod.buildSystemPrompt(arena, final_system, mem_index, "memdir");
                    try errw.print("velk: {d} memory topic(s) indexed\n", .{mem_entries.len});
                    try errw.flush();
                }
            }

            // Repo map (opt-in): prepend a cached filtered tree
            // listing so the model has the project shape without
            // having to ls everything itself. Cache invalidates on
            // `git status --porcelain` hash change.
            if (opts.repo_map) {
                const cwd_key = try std.fmt.allocPrint(arena, "{x:0>16}", .{
                    std.hash.Wyhash.hash(0, repo_root orelse "."),
                });
                const map = repo_map_mod.cachedOrGenerate(arena, init.io, init.gpa, init.environ_map, cwd_key) catch "";
                if (map.len > 0) {
                    final_system = try workspace_mod.buildSystemPrompt(arena, final_system, map, "repo-map");
                    try errw.print("velk: repo-map prepended ({d} bytes)\n", .{map.len});
                    try errw.flush();
                }
            }

            // Architect/coder auto-route: when both halves of the
            // split are configured, append a directive telling the
            // coder to consult the planner via `task` on the very
            // first non-trivial turn. Soft-routing — the model is
            // expected to comply, not enforced. We rely on the
            // recursion-depth cap to keep things bounded.
            if (opts.planner_model != null) {
                const route_block = try system_prompts.formatAutoRoute(arena, sub_default_model);
                final_system = try workspace_mod.buildSystemPrompt(arena, final_system, route_block, "auto-route");
                try errw.print("velk: auto-route enabled (planner={s})\n", .{sub_default_model});
                try errw.flush();
            }

            // `--system-append`: tack a session-specific block onto
            // the very end so it's the last thing the model reads
            // before user content. We wrap it with a header so the
            // model can tell it's not part of the default scaffold.
            if (opts.system_append) |extra| {
                final_system = try system_prompts.formatAppend(arena, final_system orelse "", extra);
            }

            // Now that tool_set + final_system are settled, finish
            // wiring the sub-agent runtime so the `task` tool has
            // the parent registry to filter against.
            sub_agent.tools = tool_set;
            sub_agent.system = final_system;
            sub_agent.hook_engine = if (file_settings.hook_engine.isEmpty()) null else &file_settings.hook_engine;

            var sess: session.Session = .init(arena, provider, .{
                .model = model,
                .max_tokens = opts.max_tokens,
                .system = final_system,
                .tools = tool_set,
                .hook_engine = if (file_settings.hook_engine.isEmpty()) null else &file_settings.hook_engine,
                .hook_gpa = init.gpa,
                .hook_io = init.io,
                .max_wall_ms = opts.max_turn_ms,
                .max_total_tokens = opts.max_turn_tokens,
                .max_iterations = if (opts.max_iterations > 0) opts.max_iterations else 10,
            });

            if (opts.session) |name| {
                const path = persist.sessionPath(arena, init.environ_map, name) catch |err| {
                    try errw.print("velk: bad --session name: {s}\n", .{@errorName(err)});
                    try errw.flush();
                    std.process.exit(2);
                };
                sess.save_path = path;
                sess.io = init.io;
                if (try persist.load(arena, init.io, path)) |loaded| {
                    try sess.messages.appendSlice(arena, loaded);
                    try errw.print("velk: resumed session '{s}' ({d} messages)\n", .{ name, loaded.len });
                    try errw.flush();
                } else {
                    try errw.print("velk: starting new session '{s}'\n", .{name});
                    try errw.flush();
                }
            }

            // --watch requires a prompt — it's the thing we re-run.
            if (opts.watch and opts.prompt == null) {
                try errw.print("velk: --watch requires a positional prompt to re-run\n", .{});
                try errw.flush();
                std.process.exit(2);
            }

            if (opts.prompt) |p| {
                var plain: PlainSink = .{ .text_out = w, .progress_out = errw, .arena = arena, .model = model };
                const expanded = mentions_mod.expand(arena, init.io, p, opts.unsafe) catch p;

                // UserPromptSubmit hook for the one-shot path. Exit-2
                // blocks (we print the reason and exit 1); successful
                // hooks prepend stdout / `prompt`-body as a context
                // block ahead of the user's prompt.
                var prompt_with_hook: []const u8 = expanded;
                if (!file_settings.hook_engine.isEmpty()) {
                    const outcome = file_settings.hook_engine.dispatch(init.gpa, init.io, .user_prompt_submit, .{
                        .prompt = p,
                    }) catch |e| blk: {
                        try errw.print("velk: hook UserPromptSubmit dispatch failed: {s}\n", .{@errorName(e)});
                        try errw.flush();
                        break :blk hooks_mod.Outcome{};
                    };
                    if (outcome.notice) |n| {
                        defer init.gpa.free(n);
                        try errw.print("velk: [hook] {s}\n", .{n});
                        try errw.flush();
                    }
                    if (outcome.blocked) |b| {
                        defer init.gpa.free(b);
                        try errw.print("velk: prompt blocked by UserPromptSubmit hook: {s}\n", .{b});
                        try errw.flush();
                        std.process.exit(1);
                    }
                    if (outcome.inject) |inj| {
                        defer init.gpa.free(inj);
                        prompt_with_hook = try std.fmt.allocPrint(
                            arena,
                            "<context source=\"hook\">\n{s}\n</context>\n\n{s}",
                            .{ inj, expanded },
                        );
                    }
                }
                sess.ask(prompt_with_hook, plain.sink()) catch |err| {
                    try renderProviderError(errw, err, provider);
                    try errw.flush();
                    std.process.exit(1);
                };

                // --watch: poll the working tree and re-run the
                // prompt every time the fingerprint changes. The
                // session's message history persists across re-runs
                // so the model can see what it produced last time
                // and react to the diff. Ctrl-C exits via the
                // installed SIGINT handler.
                if (opts.watch) {
                    const watch_root = ".";
                    var prev = watch_mod.fingerprint(arena, init.io, watch_root) catch 0;
                    try errw.print("velk: --watch · polling every {d}ms · Ctrl-C to exit\n", .{watch_mod.default_poll_ms});
                    try errw.flush();
                    while (true) {
                        prev = watch_mod.waitForChange(arena, init.io, watch_root, prev, watch_mod.default_poll_ms) catch |e| {
                            try errw.print("velk: --watch poll failed: {s}\n", .{@errorName(e)});
                            try errw.flush();
                            std.process.exit(1);
                        };
                        try errw.print("\nvelk: --watch · change detected, re-running prompt\n", .{});
                        try errw.flush();
                        sess.ask(prompt_with_hook, plain.sink()) catch |err| {
                            try renderProviderError(errw, err, provider);
                            try errw.flush();
                            // Keep watching even on error — the
                            // user might fix the issue; exiting
                            // here forces a re-launch.
                        };
                    }
                }
                return;
            }

            const stdin_is_tty = (std.Io.File.stdin().isTty(init.io)) catch false;
            if (opts.no_tui or !stdin_is_tty) {
                try cli.printHelp(w);
                try w.flush();
                return;
            }

            const mcp_count: u8 = if (mcp_servers) |s| @intCast(@min(255, s.clients.items.len)) else 0;
            const hook_engine_ptr: ?*const hooks_mod.Engine = if (file_settings.hook_engine.isEmpty()) null else &file_settings.hook_engine;

            // Lockfile-based unclean-shutdown detection. If the
            // previous run didn't clean up, surface a notice so the
            // user can /resume. Always release on clean exit.
            const had_stale_lock = lockfile.touchAndCheckStale(arena, init.io, init.environ_map) catch false;
            defer lockfile.release(init.io, arena, init.environ_map);

            // Resolve the persisted output style (`.velk/settings.json` →
            // `defaults.style`) so the TUI starts in the user's last
            // selection. Unknown style names are ignored with a warning.
            const initial_style: ?styles_mod.Style = if (file_settings.defaults.style) |sn| blk: {
                if (styles_mod.find(sn)) |s| break :blk s;
                try errw.print("velk: settings.json defaults.style '{s}' not in catalog — ignoring\n", .{sn});
                try errw.flush();
                break :blk null;
            } else null;

            tui.run(arena, init.io, init.gpa, init.environ_map, &sess, model, mcp_count, approval_gate, opts.auto_commit, hook_engine_ptr, todos_store, ask_gate, settings, had_stale_lock, opts.max_cost, opts.max_context_pct, initial_style) catch |err| {
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
            const base = init.environ_map.get("ANTHROPIC_BASE_URL");
            holder.* = .{ .anthropic = .{
                .client = anthropic.Client.init(init.gpa, init.io, key, base),
                .adapter = undefined,
            } };
            holder.anthropic.client.debug = opts.debug;
            // Fixture recording: when VELK_RECORD_FIXTURES_DIR is
            // set, every streamed Anthropic response is captured to
            // <dir>/<turn>.sse so it can be replayed via
            // scripts/mock-server.py for CI integration tests.
            if (init.environ_map.get("VELK_RECORD_FIXTURES_DIR")) |dir| {
                holder.anthropic.client.record_dir = dir;
                try errw.print("velk: recording fixtures to {s}\n", .{dir});
                try errw.flush();
            }
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
            holder.openai.client.debug = opts.debug;
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
            holder.openai.client.debug = opts.debug;
            holder.openai.adapter = openai.Adapter.init(arena, &holder.openai.client);
        },
    }
    return holder;
}

/// CLI flags take precedence; only fields the user didn't set on
/// the command line are filled from `s.defaults`. `mcp_servers`
/// from settings is concatenated with whatever the user passed via
/// `--mcp` so users get both sources.
fn applySettingsToOptions(
    arena: std.mem.Allocator,
    base: cli.Options,
    s: settings_mod.Settings,
) cli.Options {
    var out = base;
    // CLI defaults are sentinel-detected: provider == default_provider
    // is ambiguous (could be either "user picked anthropic" or "user
    // didn't pass --provider"). To keep things simple we treat the
    // default as "unset" and let the file override it. If a user
    // explicitly passes `--provider anthropic` and the file says
    // openai, this is wrong — but that's a corner case we can
    // revisit when CLI gains a "was-set" flag.
    if (s.defaults.provider) |p| out.provider = p;
    if (out.model == null) {
        if (s.defaults.model) |m| out.model = m;
    }
    if (out.system == null) {
        if (s.defaults.system) |sp| out.system = sp;
    }
    if (out.max_tokens == cli.default_max_tokens) {
        if (s.defaults.max_tokens) |t| out.max_tokens = t;
    }
    if (s.mcp_servers.len > 0) {
        const merged = arena.alloc([]const u8, out.mcp_servers.len + s.mcp_servers.len) catch return out;
        @memcpy(merged[0..out.mcp_servers.len], out.mcp_servers);
        @memcpy(merged[out.mcp_servers.len..], s.mcp_servers);
        out.mcp_servers = merged;
    }
    return out;
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

/// Split a shell-style command string on whitespace runs. Quoting is
/// not interpreted — pass shell-escaped commands without quotes for
/// now (e.g. `--mcp 'npx @modelcontextprotocol/server-filesystem /tmp'`
/// works because the surrounding shell already strips the quotes).
fn splitWhitespace(arena: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeAny(u8, cmd, " \t");
    while (iter.next()) |part| try parts.append(arena, part);
    return parts.items;
}

fn renderProviderError(errw: *Io.Writer, err: anyerror, provider: provider_mod.Provider) !void {
    switch (err) {
        agent.Error.IterationBudgetExceeded => {
            try errw.print("velk: hit iteration budget without end_turn\n", .{});
            return;
        },
        agent.Error.TurnBudgetExceeded => {
            try errw.print("velk: TurnBudgetExceeded — wall-clock or token cap hit\n", .{});
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
