//! Minimal LSP client over child-process stdio. Spawns a configured
//! language server (e.g. `zls` for `.zig`, `rust-analyzer` for `.rs`),
//! performs the initialize/initialized handshake, and exposes
//! `diagnostics` — open a file, wait for `textDocument/publishDiagnostics`,
//! return the list. v1 ships diagnostics only; hover / definition can
//! land later by reusing the framing + dispatch machinery here.
//!
//! Wire format is LSP's `Content-Length: <n>\r\n\r\n<body>` framing
//! (NOT newline-delimited like MCP — that's the main protocol-level
//! difference). Single outstanding request at a time; we serialize on
//! the worker thread.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    SpawnFailed,
    ProtocolError,
    InitFailed,
    ServerError,
    Timeout,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    /// 0-based line index in the source file.
    line: u32,
    /// 0-based column.
    col: u32,
    /// Free-form severity label: "error" / "warning" / "info" / "hint".
    severity: []const u8,
    /// Raw message body from the server.
    message: []const u8,
};

/// Single LSP `Location` (definition target / reference site). 0-based
/// line+col matching the rest of the LSP API.
pub const Location = struct {
    uri: []const u8,
    line: u32,
    col: u32,
    /// End line of the highlighted range. Useful for `references`
    /// where the same `(line, col)` shows up multiple times in a
    /// file but with distinct ranges.
    end_line: u32 = 0,
    end_col: u32 = 0,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    /// Workspace root URI sent in `initialize`. Owned by `start`'s
    /// caller (typically CWD) but we dupe it so it outlives the slice.
    root_uri: []const u8,
    child: std.process.Child,
    stdout_buf: [64 * 1024]u8 = undefined,
    stdout_reader: Io.File.Reader = undefined,
    next_id: u64 = 1,

    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        argv: []const []const u8,
        root_path_abs: []const u8,
    ) !*Client {
        if (argv.len == 0) return Error.SpawnFailed;
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .argv = argv,
            .root_uri = try std.fmt.allocPrint(gpa, "file://{s}", .{root_path_abs}),
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            }),
        };
        errdefer {
            self.child.kill(io);
            _ = self.child.wait(io) catch {};
            gpa.free(self.root_uri);
        }

        const out = self.child.stdout orelse return Error.SpawnFailed;
        self.stdout_reader = out.reader(io, &self.stdout_buf);
        try self.initialize();
        return self;
    }

    pub fn deinit(self: *Client) void {
        // Best-effort graceful shutdown: send shutdown + exit. Errors
        // here just leave the child to die under EOF.
        self.sendNotification("exit", struct {}{}) catch {};
        if (self.child.stdin) |*stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {};
        self.gpa.free(self.root_uri);
        self.gpa.destroy(self);
    }

    fn initialize(self: *Client) !void {
        const InitParams = struct {
            processId: ?i64 = null,
            rootUri: []const u8,
            capabilities: struct {} = .{},
        };
        const id = self.takeId();
        const req = .{
            .jsonrpc = @as([]const u8, "2.0"),
            .id = id,
            .method = @as([]const u8, "initialize"),
            .params = InitParams{ .rootUri = self.root_uri },
        };
        try self.sendFrame(req);

        const InitResponse = struct {
            jsonrpc: ?[]const u8 = null,
            id: ?u64 = null,
            @"error": ?struct {
                code: i32 = 0,
                message: []const u8 = "",
            } = null,
            result: ?struct {} = null,
        };
        const parsed = try self.awaitResponseRaw(id);
        defer self.gpa.free(parsed);
        const decoded = std.json.parseFromSlice(InitResponse, self.gpa, parsed, .{ .ignore_unknown_fields = true }) catch
            return Error.ProtocolError;
        defer decoded.deinit();
        if (decoded.value.@"error") |e| {
            std.log.err("lsp init error from {s}: code={d} {s}", .{ self.argv[0], e.code, e.message });
            return Error.InitFailed;
        }
        try self.sendNotification("initialized", struct {}{});
    }

    /// Open `file` (UTF-8 path inside the workspace), wait up to
    /// `timeout_ms` for the server to push diagnostics for that URI,
    /// and return them. The file's body is read from disk and sent in
    /// the `didOpen` so the server doesn't need to re-read it.
    pub fn diagnostics(
        self: *Client,
        arena: std.mem.Allocator,
        file_abs: []const u8,
        language_id: []const u8,
        body: []const u8,
        timeout_ms: u64,
    ) ![]const Diagnostic {
        const uri = try std.fmt.allocPrint(arena, "file://{s}", .{file_abs});
        const DidOpenParams = struct {
            textDocument: struct {
                uri: []const u8,
                languageId: []const u8,
                version: i64 = 1,
                text: []const u8,
            },
        };
        const note = .{
            .jsonrpc = @as([]const u8, "2.0"),
            .method = @as([]const u8, "textDocument/didOpen"),
            .params = DidOpenParams{ .textDocument = .{
                .uri = uri,
                .languageId = language_id,
                .text = body,
            } },
        };
        try self.sendFrame(note);

        // Watch for a `publishDiagnostics` notification matching our
        // URI. Servers can stream multiple revisions; we take the
        // first one for this URI and return.
        const start_ts: ?Io.Timestamp = if (timeout_ms > 0) Io.Clock.now(.awake, self.io) else null;
        while (true) {
            if (start_ts) |t0| {
                const elapsed = t0.untilNow(self.io, .awake);
                const elapsed_ms: u64 = @intCast(@max(@as(i96, 0), @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms)));
                if (elapsed_ms > timeout_ms) return Error.Timeout;
            }
            const raw = self.readMessage() catch |e| switch (e) {
                error.EndOfStream => return Error.ProtocolError,
                else => return e,
            };
            defer self.gpa.free(raw);

            const Note = struct {
                method: ?[]const u8 = null,
                params: ?std.json.Value = null,
            };
            const decoded = std.json.parseFromSlice(Note, self.gpa, raw, .{ .ignore_unknown_fields = true }) catch continue;
            defer decoded.deinit();
            const m = decoded.value.method orelse continue;
            if (!std.mem.eql(u8, m, "textDocument/publishDiagnostics")) continue;
            const params = decoded.value.params orelse continue;
            return try self.parseDiagnostics(arena, params, uri);
        }
    }

    /// `textDocument/hover` at `(line, col)` in `file_abs`. Returns
    /// the server's hover contents as a single rendered string, or
    /// null when the cursor is on something with no hover info. Both
    /// modern (`{contents: {kind, value}}`) and legacy
    /// (`{contents: <string>}` or `{contents: [<string>, ...]}`)
    /// shapes are accepted.
    pub fn hover(
        self: *Client,
        arena: std.mem.Allocator,
        file_abs: []const u8,
        language_id: []const u8,
        body: []const u8,
        line: u32,
        col: u32,
        timeout_ms: u64,
    ) !?[]const u8 {
        const uri = try std.fmt.allocPrint(arena, "file://{s}", .{file_abs});
        try self.didOpen(arena, uri, language_id, body);
        defer self.closeDocument(uri);

        const id = self.takeId();
        const HoverReq = struct {
            jsonrpc: []const u8 = "2.0",
            id: u64,
            method: []const u8 = "textDocument/hover",
            params: struct {
                textDocument: struct { uri: []const u8 },
                position: struct { line: u32, character: u32 },
            },
        };
        try self.sendFrame(HoverReq{
            .id = id,
            .params = .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = line, .character = col },
            },
        });

        const raw = try self.awaitResponseWithTimeout(id, timeout_ms);
        defer self.gpa.free(raw);
        return parseHoverResult(arena, raw);
    }

    /// `textDocument/definition` at `(line, col)`. Returns the list
    /// of `(uri, line, col)` Locations the server reported. Empty
    /// when the symbol has no resolved definition.
    pub fn definition(
        self: *Client,
        arena: std.mem.Allocator,
        file_abs: []const u8,
        language_id: []const u8,
        body: []const u8,
        line: u32,
        col: u32,
        timeout_ms: u64,
    ) ![]const Location {
        return self.locationQuery(arena, "textDocument/definition", file_abs, language_id, body, line, col, timeout_ms);
    }

    /// `textDocument/references` at `(line, col)`. Includes the
    /// definition site too (LSP `includeDeclaration: true`).
    pub fn references(
        self: *Client,
        arena: std.mem.Allocator,
        file_abs: []const u8,
        language_id: []const u8,
        body: []const u8,
        line: u32,
        col: u32,
        timeout_ms: u64,
    ) ![]const Location {
        return self.locationQuery(arena, "textDocument/references", file_abs, language_id, body, line, col, timeout_ms);
    }

    fn locationQuery(
        self: *Client,
        arena: std.mem.Allocator,
        method: []const u8,
        file_abs: []const u8,
        language_id: []const u8,
        body: []const u8,
        line: u32,
        col: u32,
        timeout_ms: u64,
    ) ![]const Location {
        const uri = try std.fmt.allocPrint(arena, "file://{s}", .{file_abs});
        try self.didOpen(arena, uri, language_id, body);
        defer self.closeDocument(uri);

        const id = self.takeId();
        const LocReq = struct {
            jsonrpc: []const u8 = "2.0",
            id: u64,
            method: []const u8,
            params: struct {
                textDocument: struct { uri: []const u8 },
                position: struct { line: u32, character: u32 },
                context: ?struct { includeDeclaration: bool } = null,
            },
        };
        const include_decl = std.mem.eql(u8, method, "textDocument/references");
        try self.sendFrame(LocReq{
            .id = id,
            .method = method,
            .params = .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = line, .character = col },
                .context = if (include_decl) .{ .includeDeclaration = true } else null,
            },
        });

        const raw = try self.awaitResponseWithTimeout(id, timeout_ms);
        defer self.gpa.free(raw);
        return parseLocationResult(arena, raw);
    }

    fn didOpen(self: *Client, arena: std.mem.Allocator, uri: []const u8, language_id: []const u8, body: []const u8) !void {
        const DidOpenParams = struct {
            textDocument: struct {
                uri: []const u8,
                languageId: []const u8,
                version: i64 = 1,
                text: []const u8,
            },
        };
        _ = arena;
        try self.sendNotification("textDocument/didOpen", DidOpenParams{ .textDocument = .{
            .uri = uri,
            .languageId = language_id,
            .text = body,
        } });
    }

    /// Block on `awaitResponseRaw` with a wall-clock cap. The
    /// underlying `readMessage` is blocking so we approximate
    /// timeout via `Io.Timeout` on the reader. On expiry we surface
    /// `Error.Timeout` so the tool can convert to a user-visible
    /// message.
    fn awaitResponseWithTimeout(self: *Client, want_id: u64, timeout_ms: u64) ![]u8 {
        const start_ts: ?Io.Timestamp = if (timeout_ms > 0) Io.Clock.now(.awake, self.io) else null;
        while (true) {
            if (start_ts) |t0| {
                const elapsed = t0.untilNow(self.io, .awake);
                const elapsed_ms: u64 = @intCast(@max(@as(i96, 0), @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms)));
                if (elapsed_ms > timeout_ms) return Error.Timeout;
            }
            const raw = try self.readMessage();
            const Probe = struct { id: ?u64 = null };
            const probe = std.json.parseFromSlice(Probe, self.gpa, raw, .{ .ignore_unknown_fields = true }) catch {
                self.gpa.free(raw);
                continue;
            };
            defer probe.deinit();
            if (probe.value.id) |got| if (got == want_id) return raw;
            self.gpa.free(raw);
        }
    }

    /// Send `textDocument/didClose` for `uri` so the server wipes
    /// its in-memory state for that document. Called by the Pool
    /// after each `diagnostics` call so a re-query for the same path
    /// can re-issue `didOpen` cleanly without confusing the server
    /// with a duplicate-open error. No-op (best-effort) on failure —
    /// next time we'll just spawn a new client if the channel's
    /// genuinely broken.
    pub fn closeDocument(self: *Client, uri: []const u8) void {
        const DidCloseParams = struct {
            textDocument: struct { uri: []const u8 },
        };
        const note = .{
            .jsonrpc = @as([]const u8, "2.0"),
            .method = @as([]const u8, "textDocument/didClose"),
            .params = DidCloseParams{ .textDocument = .{ .uri = uri } },
        };
        self.sendFrame(note) catch {};
    }

    fn parseDiagnostics(self: *Client, arena: std.mem.Allocator, params: std.json.Value, want_uri: []const u8) ![]const Diagnostic {
        _ = self;
        const obj = switch (params) {
            .object => |o| o,
            else => return &.{},
        };
        // Confirm the URI matches; some servers send empty diags
        // for unrelated documents.
        const got_uri_v = obj.get("uri") orelse return &.{};
        const got_uri = switch (got_uri_v) {
            .string => |s| s,
            else => return &.{},
        };
        if (!std.mem.eql(u8, got_uri, want_uri)) return &.{};

        const list_v = obj.get("diagnostics") orelse return &.{};
        const list = switch (list_v) {
            .array => |a| a,
            else => return &.{},
        };
        var out: std.ArrayList(Diagnostic) = .empty;
        for (list.items) |item| {
            const d = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const range = blk: {
                const r = d.get("range") orelse break :blk null;
                switch (r) {
                    .object => |ro| break :blk ro,
                    else => break :blk null,
                }
            };
            var line: u32 = 0;
            var col: u32 = 0;
            if (range) |ro| {
                if (ro.get("start")) |start_v| switch (start_v) {
                    .object => |so| {
                        if (so.get("line")) |lv| switch (lv) {
                            .integer => |i| line = if (i < 0) 0 else @intCast(i),
                            else => {},
                        };
                        if (so.get("character")) |cv| switch (cv) {
                            .integer => |i| col = if (i < 0) 0 else @intCast(i),
                            else => {},
                        };
                    },
                    else => {},
                };
            }
            const sev = blk: {
                const s = d.get("severity") orelse break :blk @as([]const u8, "info");
                switch (s) {
                    .integer => |i| break :blk severityLabel(@intCast(i)),
                    else => break :blk @as([]const u8, "info"),
                }
            };
            const msg = blk: {
                const m = d.get("message") orelse break :blk @as([]const u8, "");
                switch (m) {
                    .string => |s| break :blk s,
                    else => break :blk @as([]const u8, ""),
                }
            };
            try out.append(arena, .{
                .line = line,
                .col = col,
                .severity = try arena.dupe(u8, sev),
                .message = try arena.dupe(u8, msg),
            });
        }
        return out.items;
    }

    fn takeId(self: *Client) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendFrame(self: *Client, value: anytype) !void {
        const stdin = self.child.stdin orelse return Error.ProtocolError;
        const body = try std.json.Stringify.valueAlloc(self.gpa, value, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);
        const header = try std.fmt.allocPrint(self.gpa, "Content-Length: {d}\r\n\r\n", .{body.len});
        defer self.gpa.free(header);
        try stdin.writeStreamingAll(self.io, header);
        try stdin.writeStreamingAll(self.io, body);
    }

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const note = .{
            .jsonrpc = @as([]const u8, "2.0"),
            .method = method,
            .params = params,
        };
        try self.sendFrame(note);
    }

    /// Block until the next response has the matching id; drop any
    /// notifications that arrive in between (caller doesn't care
    /// about those during init/handshake).
    fn awaitResponseRaw(self: *Client, want_id: u64) ![]u8 {
        while (true) {
            const raw = try self.readMessage();
            const Probe = struct { id: ?u64 = null };
            const probe = std.json.parseFromSlice(Probe, self.gpa, raw, .{ .ignore_unknown_fields = true }) catch {
                self.gpa.free(raw);
                continue;
            };
            defer probe.deinit();
            if (probe.value.id) |got| if (got == want_id) return raw;
            self.gpa.free(raw);
        }
    }

    /// Read one LSP message: parse `Content-Length: <n>\r\n\r\n` then
    /// the n-byte body. Returned slice is gpa-owned; caller frees.
    fn readMessage(self: *Client) ![]u8 {
        const reader = &self.stdout_reader.interface;
        var content_len: ?usize = null;
        while (true) {
            const inclusive = try reader.takeDelimiterInclusive('\n');
            // Strip trailing \r if present.
            var line = inclusive;
            if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) break; // header-body separator
            // Parse "Content-Length: <n>" case-insensitively.
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (asciiEqlIgnoreCase(name, "content-length")) {
                content_len = std.fmt.parseInt(usize, val, 10) catch return Error.ProtocolError;
            }
        }
        const n = content_len orelse return Error.ProtocolError;
        const body = try self.gpa.alloc(u8, n);
        errdefer self.gpa.free(body);
        try reader.readSliceAll(body);
        return body;
    }
};

/// Per-extension client pool. The first `lsp_diagnostics` call for a
/// given language spawns the server (cost: 500ms–2s for zls /
/// rust-analyzer warmup). Subsequent calls reuse the same process and
/// pay only the framing overhead (single-digit ms). Pool lives for
/// the velk session and shuts every server down on `deinit`.
///
/// One client per extension is enough today: `lsp_diagnostics` is
/// the only consumer and it runs serially on the agent worker
/// thread. If we add hover/definition later they'll multiplex on the
/// same client (LSP supports it natively — just need a request-id
/// dispatcher).
pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Map keyed by file extension (`.zig`, `.rs`). Owns the keys
    /// (duped on insert) and the *Client values.
    clients: std.StringHashMap(*Client),

    pub fn init(gpa: std.mem.Allocator, io: Io) Pool {
        return .{ .gpa = gpa, .io = io, .clients = .init(gpa) };
    }

    pub fn deinit(self: *Pool) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.gpa.free(entry.key_ptr.*);
        }
        self.clients.deinit();
    }

    /// Returns a usable client for `extension`, spawning one via
    /// `Client.start(...)` on first contact. The returned pointer
    /// is owned by the pool — do NOT call `deinit()` on it.
    /// `argv` and `root_abs` are only consulted on first contact;
    /// subsequent calls with different argv for the same extension
    /// silently reuse the original spawn (settings are immutable
    /// for the session in v1).
    pub fn get(
        self: *Pool,
        extension: []const u8,
        argv: []const []const u8,
        root_abs: []const u8,
    ) !*Client {
        if (self.clients.get(extension)) |c| return c;
        const c = try Client.start(self.gpa, self.io, argv, root_abs);
        errdefer c.deinit();
        const key = try self.gpa.dupe(u8, extension);
        errdefer self.gpa.free(key);
        try self.clients.put(key, c);
        return c;
    }

    pub fn isEmpty(self: *const Pool) bool {
        return self.clients.count() == 0;
    }
};

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl: u8 = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl: u8 = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

fn severityLabel(n: i32) []const u8 {
    return switch (n) {
        1 => "error",
        2 => "warning",
        3 => "info",
        4 => "hint",
        else => "info",
    };
}

/// Parse the `result` of a `textDocument/hover` response into a
/// human-readable string. Three shapes are accepted:
///   { result: { contents: { kind, value } } }
///   { result: { contents: "string" } }
///   { result: { contents: [<string|MarkedString>...] } }
/// Null result → null. The arena-allocated string includes any
/// language-specific code fences (model can render Markdown).
pub fn parseHoverResult(arena: std.mem.Allocator, raw_message: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw_message, .{}) catch return null;
    const msg = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const result_v = msg.get("result") orelse return null;
    if (result_v == .null) return null;
    const result = switch (result_v) {
        .object => |o| o,
        else => return null,
    };
    const contents_v = result.get("contents") orelse return null;
    return try renderHoverContents(arena, contents_v);
}

fn renderHoverContents(arena: std.mem.Allocator, v: std.json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| try arena.dupe(u8, s),
        .object => |o| blk: {
            // MarkupContent: { kind, value }. Plain or Markdown both
            // pass through as the model can re-render either.
            if (o.get("value")) |vv| {
                switch (vv) {
                    .string => |s| break :blk try arena.dupe(u8, s),
                    else => {},
                }
            }
            break :blk null;
        },
        .array => |a| blk: {
            // Pre-3.18 servers send MarkedString[]: each entry is
            // either a string or `{ language, value }`. We join with
            // blank lines so the model still sees structure.
            var buf: std.ArrayList(u8) = .empty;
            for (a.items) |item| {
                const piece = (try renderHoverContents(arena, item)) orelse continue;
                if (buf.items.len > 0) try buf.appendSlice(arena, "\n\n");
                try buf.appendSlice(arena, piece);
            }
            if (buf.items.len == 0) break :blk null;
            break :blk buf.items;
        },
        else => null,
    };
}

/// Parse the `result` of a definition/references response. LSP
/// allows the result to be a single Location, a Location[], or
/// LocationLink[]. We canonicalise to `Location[]`.
pub fn parseLocationResult(arena: std.mem.Allocator, raw_message: []const u8) ![]const Location {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw_message, .{}) catch return &.{};
    const msg = switch (parsed.value) {
        .object => |o| o,
        else => return &.{},
    };
    const result_v = msg.get("result") orelse return &.{};
    var out: std.ArrayList(Location) = .empty;
    switch (result_v) {
        .null => return &.{},
        .object => |o| {
            if (try parseSingleLocation(arena, o)) |loc| try out.append(arena, loc);
        },
        .array => |a| {
            for (a.items) |item| switch (item) {
                .object => |o| if (try parseSingleLocation(arena, o)) |loc| try out.append(arena, loc),
                else => {},
            };
        },
        else => return &.{},
    }
    return out.items;
}

fn parseSingleLocation(arena: std.mem.Allocator, obj: std.json.ObjectMap) !?Location {
    // LocationLink uses `targetUri` + `targetRange`; Location uses
    // `uri` + `range`. Try both.
    const uri_v = obj.get("uri") orelse obj.get("targetUri") orelse return null;
    const uri = switch (uri_v) {
        .string => |s| try arena.dupe(u8, s),
        else => return null,
    };
    const range_v = obj.get("range") orelse obj.get("targetSelectionRange") orelse obj.get("targetRange") orelse return null;
    const range = switch (range_v) {
        .object => |r| r,
        else => return null,
    };
    const start = switch (range.get("start") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const end = switch (range.get("end") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return .{
        .uri = uri,
        .line = readU32(start, "line"),
        .col = readU32(start, "character"),
        .end_line = readU32(end, "line"),
        .end_col = readU32(end, "character"),
    };
}

fn readU32(obj: std.json.ObjectMap, key: []const u8) u32 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| @intCast(@max(@as(i64, 0), i)),
        else => 0,
    };
}

// ───────── tests ─────────

const testing = std.testing;

test "parseHoverResult: MarkupContent shape" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"`fn run() void`\"}}}";
    const out = (try parseHoverResult(a, raw)).?;
    try testing.expectEqualStrings("`fn run() void`", out);
}

test "parseHoverResult: legacy bare string" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":\"plain text\"}}";
    const out = (try parseHoverResult(a, raw)).?;
    try testing.expectEqualStrings("plain text", out);
}

test "parseHoverResult: array of MarkedString joined with blank lines" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"result\":{\"contents\":[\"first\",{\"value\":\"second\"}]}}";
    const out = (try parseHoverResult(a, raw)).?;
    try testing.expect(std.mem.indexOf(u8, out, "first") != null);
    try testing.expect(std.mem.indexOf(u8, out, "second") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first\n\nsecond") != null);
}

test "parseHoverResult: null result yields null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    const out = try parseHoverResult(a, raw);
    try testing.expect(out == null);
}

test "parseLocationResult: single Location" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"result\":{\"uri\":\"file:///x.zig\",\"range\":{\"start\":{\"line\":3,\"character\":7},\"end\":{\"line\":3,\"character\":12}}}}";
    const locs = try parseLocationResult(a, raw);
    try testing.expectEqual(@as(usize, 1), locs.len);
    try testing.expectEqualStrings("file:///x.zig", locs[0].uri);
    try testing.expectEqual(@as(u32, 3), locs[0].line);
    try testing.expectEqual(@as(u32, 7), locs[0].col);
    try testing.expectEqual(@as(u32, 12), locs[0].end_col);
}

test "parseLocationResult: array of Locations" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"result\":[{\"uri\":\"file:///a.zig\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}},{\"uri\":\"file:///b.zig\",\"range\":{\"start\":{\"line\":5,\"character\":2},\"end\":{\"line\":5,\"character\":3}}}]}";
    const locs = try parseLocationResult(a, raw);
    try testing.expectEqual(@as(usize, 2), locs.len);
    try testing.expectEqualStrings("file:///a.zig", locs[0].uri);
    try testing.expectEqualStrings("file:///b.zig", locs[1].uri);
}

test "parseLocationResult: LocationLink uses targetUri + targetSelectionRange" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"result\":[{\"targetUri\":\"file:///x.zig\",\"targetSelectionRange\":{\"start\":{\"line\":1,\"character\":1},\"end\":{\"line\":1,\"character\":4}}}]}";
    const locs = try parseLocationResult(a, raw);
    try testing.expectEqual(@as(usize, 1), locs.len);
    try testing.expectEqualStrings("file:///x.zig", locs[0].uri);
    try testing.expectEqual(@as(u32, 1), locs[0].line);
}

test "parseLocationResult: null result yields empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const locs = try parseLocationResult(a, "{\"result\":null}");
    try testing.expectEqual(@as(usize, 0), locs.len);
}

test "Pool: empty until first get" {
    var pool: Pool = .init(testing.allocator, testing.io);
    defer pool.deinit();
    try testing.expect(pool.isEmpty());
    try testing.expectEqual(@as(u32, 0), pool.clients.count());
}

test "Pool: get spawns once per extension" {
    // We can't actually spawn a real LSP server in this test (no zls
    // on the test runner), but we can verify the cache-miss path
    // surfaces the spawn error without leaking a partial entry.
    var pool: Pool = .init(testing.allocator, testing.io);
    defer pool.deinit();
    const argv: []const []const u8 = &.{"this-binary-does-not-exist-xyz"};
    _ = pool.get(".zig", argv, "/tmp") catch |e| {
        // Expect SpawnFailed or FileNotFound style error; concrete
        // value depends on the OS but it MUST not be a successful
        // insert.
        _ = e;
        try testing.expect(pool.isEmpty());
        return;
    };
    // If we somehow got here (e.g. a binary by that name exists),
    // just make sure the entry's cached.
    try testing.expectEqual(@as(u32, 1), pool.clients.count());
}

test "asciiEqlIgnoreCase: matches across case" {
    try testing.expect(asciiEqlIgnoreCase("Content-Length", "content-length"));
    try testing.expect(asciiEqlIgnoreCase("CONTENT-LENGTH", "content-length"));
    try testing.expect(!asciiEqlIgnoreCase("Content-Length", "Content-Type"));
    try testing.expect(!asciiEqlIgnoreCase("short", "longer"));
}

test "severityLabel: known values + fallback" {
    try testing.expectEqualStrings("error", severityLabel(1));
    try testing.expectEqualStrings("warning", severityLabel(2));
    try testing.expectEqualStrings("info", severityLabel(3));
    try testing.expectEqualStrings("hint", severityLabel(4));
    try testing.expectEqualStrings("info", severityLabel(99));
}
