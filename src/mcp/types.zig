//! JSON-RPC 2.0 envelope types and the slice of MCP-specific result
//! shapes velk actually uses (initialize, tools/list, tools/call).
//! The full MCP spec is much wider — we ignore notifications,
//! resources, prompts, sampling. Add as needed.

const std = @import("std");

pub const protocol_version = "2024-11-05";

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

pub const ClientCapabilities = struct {
    /// We don't expose any client-side capabilities yet (no roots, no
    /// sampling). Empty object satisfies servers that check for the
    /// field.
    roots: ?struct {} = null,
};

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: Implementation,
};

pub const ListedTool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
};

pub const ListToolsResult = struct {
    tools: []const ListedTool,
    nextCursor: ?[]const u8 = null,
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

pub const CallToolResult = struct {
    content: []const ContentBlock = &.{},
    isError: bool = false,
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
};

/// JSON-RPC 2.0 request envelope. `params` is left as raw JSON so each
/// caller can stringify the right shape.
pub fn Request(comptime Params: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: u64,
        method: []const u8,
        params: Params,
    };
}

/// Response envelope parameterized over the result type. Either
/// `result` or `error` is non-null.
pub fn Response(comptime Result: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: ?u64 = null,
        result: ?Result = null,
        @"error": ?RpcError = null,
    };
}
