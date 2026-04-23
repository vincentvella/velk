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

// ───────── built-in tools ─────────

const echo_schema_json: []const u8 =
    \\{"type":"object","properties":{"text":{"type":"string","description":"The text to echo back."}},"required":["text"]}
;

/// Build the `echo` tool. Parses its schema once into `arena`; the returned
/// Tool borrows from `arena` and is valid for that arena's lifetime.
/// Phase 5 will replace this with the real toolkit.
pub fn buildEcho(arena: std.mem.Allocator) !Tool {
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, echo_schema_json, .{});
    return .{
        .name = "echo",
        .description = "Echo back the provided text. Useful for testing.",
        .input_schema = schema,
        .execute = echoExecute,
    };
}

fn echoExecute(_: ?*anyopaque, arena: std.mem.Allocator, input: std.json.Value) anyerror!Output {
    const obj = switch (input) {
        .object => |o| o,
        else => return .{ .text = try arena.dupe(u8, "echo: expected object input"), .is_error = true },
    };
    const text_val = obj.get("text") orelse {
        return .{ .text = try arena.dupe(u8, "echo: missing 'text' field"), .is_error = true };
    };
    const text = switch (text_val) {
        .string => |s| s,
        else => return .{ .text = try arena.dupe(u8, "echo: 'text' must be a string"), .is_error = true },
    };
    return .{ .text = try arena.dupe(u8, text) };
}

// ───────── tests ─────────

const testing = std.testing;

test "Registry.find: locates a registered tool by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const echo = try buildEcho(arena.allocator());

    const reg: Registry = .{ .tools = &.{echo} };
    const found = reg.find("echo");
    try testing.expect(found != null);
    try testing.expectEqualStrings("echo", found.?.name);
}

test "Registry.find: returns null for unknown tool" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const echo = try buildEcho(arena.allocator());

    const reg: Registry = .{ .tools = &.{echo} };
    try testing.expect(reg.find("nonexistent") == null);
}

test "echo: returns the input text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const echo = try buildEcho(a);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "text", .{ .string = "hello world" });

    const result = try echo.execute(null, a, .{ .object = obj });
    try testing.expectEqualStrings("hello world", result.text);
    try testing.expect(!result.is_error);
}

test "echo: missing text returns is_error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const echo = try buildEcho(a);
    const obj: std.json.ObjectMap = .empty;
    const result = try echo.execute(null, a, .{ .object = obj });
    try testing.expect(result.is_error);
}
