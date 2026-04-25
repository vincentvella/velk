//! Bridge between the MCP client and velk's local tool registry.
//! `bridge` spawns one or more MCP servers, lists their tools, and
//! returns a slice of `tool.Tool` whose `execute` callback proxies
//! through `client.callTool`.

const std = @import("std");
const Io = std.Io;
const tool = @import("tool.zig");

pub const types = @import("mcp/types.zig");
pub const client = @import("mcp/client.zig");

pub const Client = client.Client;

/// Per-tool bridge context: the MCP client to talk to + the tool name
/// to invoke. Stashed in the `tool.Tool.context` opaque pointer.
const Bridge = struct {
    client: *Client,
    name: []const u8,
};

fn bridgeExecute(ctx: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!tool.Output {
    const self: *Bridge = @ptrCast(@alignCast(ctx.?));
    const result = try self.client.callTool(arena, self.name, input);
    return .{ .text = result.text, .is_error = result.is_error };
}

/// Spawn each server in `server_argvs`, list its tools, and return a
/// flat slice of `tool.Tool` ready to feed into the agent registry.
/// Servers are owned by the returned `Servers` and shut down on
/// `Servers.deinit`.
pub const Servers = struct {
    arena: std.mem.Allocator,
    clients: std.ArrayList(*Client),
    tools: []const tool.Tool,

    pub fn deinit(self: *Servers, io: Io) void {
        for (self.clients.items) |c| {
            _ = io;
            c.deinit();
        }
    }
};

pub fn start(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    server_argvs: []const []const []const u8,
) !Servers {
    var clients: std.ArrayList(*Client) = .empty;
    var tools: std.ArrayList(tool.Tool) = .empty;

    for (server_argvs, 0..) |argv, server_idx| {
        const c = Client.start(gpa, io, argv) catch |err| {
            std.log.err("velk: mcp server {s} failed to start: {s}", .{ argv[0], @errorName(err) });
            continue;
        };
        try clients.append(arena, c);

        const listed = c.listTools(arena) catch |err| {
            std.log.err("velk: mcp tools/list on {s}: {s}", .{ argv[0], @errorName(err) });
            continue;
        };

        for (listed) |t| {
            const bridge = try arena.create(Bridge);
            // Bridge needs the *original* name to send back to the
            // server; only the name we expose to the model is prefixed.
            bridge.* = .{ .client = c, .name = t.name };
            const prefixed = try std.fmt.allocPrint(arena, "mcp{d}_{s}", .{ server_idx, t.name });
            try tools.append(arena, .{
                .name = prefixed,
                .description = t.description orelse "",
                .input_schema = t.inputSchema,
                .context = bridge,
                .execute = bridgeExecute,
            });
        }
    }

    return .{ .arena = arena, .clients = clients, .tools = tools.items };
}

test {
    _ = client;
    _ = types;
}
