//! MCP client over child-process stdio. Spawns a server (e.g.
//! `npx @modelcontextprotocol/server-filesystem /tmp`), exchanges
//! newline-delimited JSON-RPC messages on stdin/stdout, and exposes
//! `listTools` + `callTool` for the higher-level tool factory to use.
//!
//! Single-threaded: every `request` writes the body, then blocks on
//! the next response line. Tools are invoked sequentially from the
//! agent's worker thread; one outstanding request at a time.

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

pub const Error = error{
    SpawnFailed,
    ProtocolError,
    ServerError,
    InitFailed,
} || std.mem.Allocator.Error;

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Original argv kept around for diagnostics (`name` returns argv[0]).
    argv: []const []const u8,
    child: std.process.Child,
    stdout_buf: [16 * 1024]u8 = undefined,
    stdout_reader: Io.File.Reader = undefined,
    next_id: u64 = 1,
    /// Surfaced in the startup banner / error messages so the user can
    /// tell which server replied with what.
    server_name: []const u8 = "(unknown)",
    server_version: []const u8 = "(unknown)",

    /// Spawn the MCP server and run the JSON-RPC initialize handshake.
    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        argv: []const []const u8,
    ) !*Client {
        if (argv.len == 0) return Error.SpawnFailed;
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .argv = argv,
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            }),
        };
        errdefer {
            self.child.kill(io);
            _ = self.child.wait(io) catch {};
        }

        const out = self.child.stdout orelse return Error.SpawnFailed;
        self.stdout_reader = out.reader(io, &self.stdout_buf);

        try self.initialize();
        return self;
    }

    pub fn deinit(self: *Client) void {
        // Shutdown by closing stdin; server exits on EOF.
        if (self.child.stdin) |*stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {};
        if (!std.mem.eql(u8, self.server_name, "(unknown)")) self.gpa.free(self.server_name);
        if (!std.mem.eql(u8, self.server_version, "(unknown)")) self.gpa.free(self.server_version);
        self.gpa.destroy(self);
    }

    fn initialize(self: *Client) !void {
        const req: types.Request(types.InitializeParams) = .{
            .id = self.takeId(),
            .method = "initialize",
            .params = .{
                .protocolVersion = types.protocol_version,
                .capabilities = .{},
                .clientInfo = .{ .name = "velk", .version = "0.0.0" },
            },
        };

        const InitResult = struct {
            protocolVersion: []const u8,
            serverInfo: ?types.Implementation = null,
        };

        const parsed = try self.exchange(InitResult, req.id, req);
        defer parsed.deinit();
        if (parsed.value.@"error") |e| {
            std.log.err("mcp init error from {s}: code={d} {s}", .{ self.argv[0], e.code, e.message });
            return Error.InitFailed;
        }
        if (parsed.value.result) |r| {
            if (r.serverInfo) |si| {
                self.server_name = try self.gpa.dupe(u8, si.name);
                self.server_version = try self.gpa.dupe(u8, si.version);
            }
        }

        // Per spec, send `notifications/initialized` to tell the server
        // we're ready to start using its capabilities. No response.
        try self.sendNotification("notifications/initialized", struct {}{});
    }

    /// Fetch the server's tool catalog. Caller frees the returned
    /// `Parsed` when done with the data.
    pub fn listTools(self: *Client, arena: std.mem.Allocator) ![]const types.ListedTool {
        const req: types.Request(struct {}) = .{
            .id = self.takeId(),
            .method = "tools/list",
            .params = .{},
        };
        const parsed = try self.exchange(types.ListToolsResult, req.id, req);
        defer parsed.deinit();
        if (parsed.value.@"error") |e| {
            std.log.err("mcp tools/list error: code={d} {s}", .{ e.code, e.message });
            return Error.ServerError;
        }
        const result = parsed.value.result orelse return Error.ProtocolError;

        // Copy into the agent's arena so the returned slices outlive
        // the parsed envelope.
        const out = try arena.alloc(types.ListedTool, result.tools.len);
        for (result.tools, 0..) |t, i| {
            out[i] = .{
                .name = try arena.dupe(u8, t.name),
                .description = if (t.description) |d| try arena.dupe(u8, d) else null,
                .inputSchema = try cloneJson(arena, t.inputSchema),
            };
        }
        return out;
    }

    /// Invoke a tool with parsed JSON input. The result's text content
    /// is concatenated into `arena` and returned to the caller.
    pub fn callTool(
        self: *Client,
        arena: std.mem.Allocator,
        name: []const u8,
        input: std.json.Value,
    ) !struct { text: []const u8, is_error: bool } {
        const Params = struct {
            name: []const u8,
            arguments: std.json.Value,
        };
        const req: types.Request(Params) = .{
            .id = self.takeId(),
            .method = "tools/call",
            .params = .{ .name = name, .arguments = input },
        };
        const parsed = try self.exchange(types.CallToolResult, req.id, req);
        defer parsed.deinit();
        if (parsed.value.@"error") |e| {
            const msg = try std.fmt.allocPrint(arena, "mcp error {d}: {s}", .{ e.code, e.message });
            return .{ .text = msg, .is_error = true };
        }
        const result = parsed.value.result orelse return Error.ProtocolError;

        var buf: std.ArrayList(u8) = .empty;
        for (result.content) |block| {
            if (block.text) |t| try buf.appendSlice(arena, t);
        }
        return .{ .text = buf.items, .is_error = result.isError };
    }

    fn takeId(self: *Client) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Write a single JSON-RPC frame and read until the matching id.
    /// Server-pushed notifications and unrelated responses are
    /// discarded along the way.
    fn exchange(
        self: *Client,
        comptime Result: type,
        id: u64,
        req: anytype,
    ) !std.json.Parsed(types.Response(Result)) {
        try self.sendFrame(req);
        return self.awaitResponse(Result, id);
    }

    fn sendFrame(self: *Client, value: anytype) !void {
        const stdin = self.child.stdin orelse return Error.ProtocolError;
        const body = try std.json.Stringify.valueAlloc(self.gpa, value, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);
        try stdin.writeStreamingAll(self.io, body);
        try stdin.writeStreamingAll(self.io, "\n");
    }

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const note = .{
            .jsonrpc = @as([]const u8, "2.0"),
            .method = method,
            .params = params,
        };
        try self.sendFrame(note);
    }

    fn awaitResponse(
        self: *Client,
        comptime Result: type,
        id: u64,
    ) !std.json.Parsed(types.Response(Result)) {
        const reader = &self.stdout_reader.interface;
        while (true) {
            const inclusive = try reader.takeDelimiterInclusive('\n');
            const line = inclusive[0 .. inclusive.len - 1];
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(
                types.Response(Result),
                self.gpa,
                line,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch |e| {
                std.log.warn("mcp parse failure: {s} — line: {s}", .{ @errorName(e), line });
                continue;
            };
            // Notifications and id-mismatches: drop and keep reading.
            if (parsed.value.id == null or parsed.value.id.? != id) {
                parsed.deinit();
                continue;
            }
            return parsed;
        }
    }
};

/// Deep-copy a std.json.Value into a target arena. The input may
/// reference its parser's buffer, which goes away after we drop the
/// `Parsed` envelope; cloning lets the schema outlive the envelope.
fn cloneJson(arena: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null => .{ .null = {} },
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try arena.dupe(u8, s) },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |arr| blk: {
            var out: std.json.Array = .init(arena);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try cloneJson(arena, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                try out.put(arena, try arena.dupe(u8, entry.key_ptr.*), try cloneJson(arena, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}
