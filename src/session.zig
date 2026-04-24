//! A multi-turn conversation. Holds the running message history and
//! reuses one Provider across turns. Each `ask` runs the full agent
//! loop until end_turn and persists the resulting messages.

const std = @import("std");
const Io = std.Io;
const provider_mod = @import("provider.zig");
const tool = @import("tool.zig");
const agent = @import("agent.zig");
const persist = @import("persist.zig");

pub const Config = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    tools: []const tool.Tool = &.{},
    max_iterations: u32 = 10,
};

pub const Session = struct {
    arena: std.mem.Allocator,
    provider: provider_mod.Provider,
    config: Config,
    messages: std.ArrayList(provider_mod.Message) = .empty,
    /// When set, every successful `ask` writes the message list to this
    /// path so the conversation can be resumed in a future invocation.
    save_path: ?[]const u8 = null,
    /// Required if `save_path` is set.
    io: ?Io = null,

    pub fn init(arena: std.mem.Allocator, provider: provider_mod.Provider, config: Config) Session {
        return .{ .arena = arena, .provider = provider, .config = config };
    }

    pub fn ask(self: *Session, prompt: []const u8, sink: agent.Sink) !void {
        const final = try agent.run(self.arena, self.provider, sink, .{
            .model = self.config.model,
            .max_tokens = self.config.max_tokens,
            .system = self.config.system,
            .prompt = prompt,
            .tools = self.config.tools,
            .max_iterations = self.config.max_iterations,
            .history = self.messages.items,
        });
        self.messages.clearRetainingCapacity();
        try self.messages.appendSlice(self.arena, final);
        if (self.save_path) |path| {
            if (self.io) |io| persist.save(self.arena, io, path, self.messages.items) catch {};
        }
    }
};
