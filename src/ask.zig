//! Cross-thread gate for the `ask_user_question` tool. Worker emits a
//! question + numbered options, blocks; the TUI surfaces a picker and
//! captures the user's selection (1..9 keys) or cancels (Esc).
//!
//! Same lifecycle as `approval.ApprovalGate`: headless callers leave
//! `post_fn` null and every request fast-paths to a canceled answer
//! (the model gets a "no UI to ask" error back so it falls through).

const std = @import("std");
const Io = std.Io;

/// Posted to the TUI's main thread via `post_fn`. Both strings are
/// gpa-owned and ownership transfers to the TUI on post — the TUI
/// frees them after rendering completes.
pub const Request = struct {
    question: []const u8,
    options: []const []const u8,
};

pub const Response = union(enum) {
    /// User picked option number `idx` (zero-based).
    selected: usize,
    /// User pressed Esc — tool returns an error to the model.
    canceled,
};

pub const PostFn = *const fn (ctx: ?*anyopaque, request: Request) anyerror!void;

pub const AskGate = struct {
    gpa: std.mem.Allocator,
    io: Io,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    response: ?Response = null,

    post_fn: ?PostFn = null,
    post_ctx: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator, io: Io) AskGate {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn isHeadless(self: *const AskGate) bool {
        return self.post_fn == null;
    }

    /// WORKER THREAD. Hands ownership of `question` + `options` (and
    /// each option string) to the gate. On the headless path we free
    /// them immediately and return `canceled`.
    pub fn ask(
        self: *AskGate,
        question: []const u8,
        options: []const []const u8,
    ) !Response {
        if (self.isHeadless()) {
            self.gpa.free(@constCast(question));
            for (options) |o| self.gpa.free(@constCast(o));
            self.gpa.free(@constCast(options));
            return .canceled;
        }

        try self.post_fn.?(self.post_ctx, .{ .question = question, .options = options });

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (self.response == null) {
            try self.cond.wait(self.io, &self.mutex);
        }
        const r = self.response.?;
        self.response = null;
        return r;
    }

    /// MAIN THREAD. Hand the user's choice back to the worker.
    pub fn deliver(self: *AskGate, response: Response) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.response = response;
        self.cond.signal(self.io);
    }
};

// ───────── tests ─────────

const testing = std.testing;

fn testIo() Io {
    const Threaded = std.Io.Threaded;
    const Static = struct {
        var t: Threaded = undefined;
        var initialised: bool = false;
    };
    if (!Static.initialised) {
        Static.t = Threaded.init(std.heap.page_allocator, .{});
        Static.initialised = true;
    }
    return Static.t.io();
}

test "headless ask gate cancels and frees inputs" {
    const q = try testing.allocator.dupe(u8, "Which one?");
    const opts = try testing.allocator.alloc([]const u8, 2);
    opts[0] = try testing.allocator.dupe(u8, "A");
    opts[1] = try testing.allocator.dupe(u8, "B");
    var gate: AskGate = .init(testing.allocator, testIo());
    const r = try gate.ask(q, opts);
    try testing.expectEqual(Response.canceled, r);
}

test "non-headless ask gate posts and unblocks via deliver-stub" {
    const TestPost = struct {
        captured: ?Request = null,
        fn post(ctx: ?*anyopaque, req: Request) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.captured = req;
        }
    };

    var cap: TestPost = .{};
    var gate: AskGate = .init(testing.allocator, testIo());
    gate.post_fn = TestPost.post;
    gate.post_ctx = &cap;
    gate.response = .{ .selected = 1 };

    const q = try testing.allocator.dupe(u8, "?");
    const opts = try testing.allocator.alloc([]const u8, 2);
    opts[0] = try testing.allocator.dupe(u8, "X");
    opts[1] = try testing.allocator.dupe(u8, "Y");
    const r = try gate.ask(q, opts);
    try testing.expectEqual(Response{ .selected = 1 }, r);
    try testing.expect(cap.captured != null);
    try testing.expectEqualStrings("?", cap.captured.?.question);
    testing.allocator.free(cap.captured.?.question);
    for (cap.captured.?.options) |o| testing.allocator.free(@constCast(o));
    testing.allocator.free(@constCast(cap.captured.?.options));
}
