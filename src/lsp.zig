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

// ───────── tests ─────────

const testing = std.testing;

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
