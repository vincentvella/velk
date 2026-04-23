//! A multi-turn conversation. Holds the running message history and
//! reuses one Anthropic client across turns. Each `ask` runs the full
//! agent loop until `end_turn` and persists the resulting messages.

const std = @import("std");
const anthropic = @import("anthropic.zig");
const types = anthropic.types;
const tool = @import("tool.zig");
const agent = @import("agent.zig");

pub const Config = struct {
    model: []const u8,
    max_tokens: u32,
    system: ?[]const u8 = null,
    tools: []const tool.Tool = &.{},
    max_iterations: u32 = 10,
};

pub const Session = struct {
    arena: std.mem.Allocator,
    client: *anthropic.Client,
    config: Config,
    messages: std.ArrayList(types.Message) = .empty,

    pub fn init(arena: std.mem.Allocator, client: *anthropic.Client, config: Config) Session {
        return .{ .arena = arena, .client = client, .config = config };
    }

    /// Run one turn (user prompt → assistant end_turn). Updates the
    /// internal message list with everything the turn produced.
    pub fn ask(self: *Session, prompt: []const u8, sink: agent.Sink) !void {
        const final = try agent.run(self.arena, self.client, sink, .{
            .model = self.config.model,
            .max_tokens = self.config.max_tokens,
            .system = self.config.system,
            .prompt = prompt,
            .tools = self.config.tools,
            .max_iterations = self.config.max_iterations,
            .history = self.messages.items,
        });
        // Replace messages with the post-turn list (agent.run gave us the
        // copy that includes the user prompt, all assistant turns, and tool
        // results). It's the same arena, so this is essentially free.
        self.messages.clearRetainingCapacity();
        try self.messages.appendSlice(self.arena, final);
    }
};
