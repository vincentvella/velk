//! A tool the model can call. The Anthropic API receives this as a
//! `tools[]` entry alongside the messages; when the model emits a
//! `tool_use` content block the agent loop matches by `name` and runs
//! `execute`, then sends the result back as a `tool_result` block.

const std = @import("std");

pub const Error = error{
    /// The tool name in a tool_use block didn't match any registered tool.
    UnknownTool,
};

pub const Output = struct {
    /// Caller takes ownership; the agent will free it.
    text: []const u8,
    is_error: bool = false,
};

pub const ExecuteFn = *const fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    input: std.json.Value,
) anyerror!Output;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema (object) describing the tool's input. Built once, owned
    /// by the caller, must outlive any request that references it.
    input_schema: std.json.Value,
    /// Per-tool context pointer, passed unchanged to `execute`.
    context: ?*anyopaque = null,
    execute: ExecuteFn,
};

pub const Registry = struct {
    tools: []const Tool,

    pub fn find(self: Registry, name: []const u8) ?Tool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn empty() Registry {
        return .{ .tools = &.{} };
    }
};

// ───────── tests ─────────

const testing = std.testing;

fn stubExecute(_: ?*anyopaque, _: std.mem.Allocator, _: std.json.Value) anyerror!Output {
    return .{ .text = "" };
}

test "Registry.find: locates a registered tool by name" {
    const stub: Tool = .{
        .name = "stub",
        .description = "",
        .input_schema = .{ .null = {} },
        .execute = stubExecute,
    };
    const reg: Registry = .{ .tools = &.{stub} };
    try testing.expect(reg.find("stub") != null);
    try testing.expect(reg.find("nonexistent") == null);
}
