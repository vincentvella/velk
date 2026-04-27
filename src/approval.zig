//! Cross-thread approval gate for write-side tools (`edit`,
//! `write_file`). The agent worker thread calls `requestApproval`
//! with a unified-diff blob; the gate posts a request to the TUI's
//! main thread and blocks on a condition variable until a decision
//! comes back. Cancellation (Ctrl-C → Future.cancel) raises
//! `error.Canceled` directly out of the wait so the worker unwinds
//! exactly like any other Cancelable IO call.
//!
//! Headless callers (one-shot CLI, --no-tui) leave `post_fn` null;
//! every request fast-paths to `apply` without touching the mutex.

const std = @import("std");
const Io = std.Io;

pub const Decision = enum {
    /// User pressed `a` or Enter — apply this single edit.
    apply,
    /// User pressed `s` or Esc — skip this single edit; the tool
    /// returns a "skipped by user" string back to the model.
    skip,
    /// User pressed `A` (shift-A) — apply this and all future edits
    /// in the session without prompting.
    always_apply,
};

/// Posted to the TUI's main thread via `post_fn`. The TUI renders
/// the diff and captures the next keystroke to deliver back. Both
/// strings are gpa-owned and must be freed by the receiver.
pub const Request = struct {
    path: []const u8,
    diff_text: []const u8,
};

pub const PostFn = *const fn (ctx: ?*anyopaque, request: Request) anyerror!void;

pub const ApprovalGate = struct {
    gpa: std.mem.Allocator,
    io: Io,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    response: ?Decision = null,
    bypass: bool = false,

    /// Function the gate calls to surface a Request to the TUI.
    /// May be null in headless contexts; in that case the gate
    /// auto-approves every request.
    post_fn: ?PostFn = null,
    post_ctx: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator, io: Io) ApprovalGate {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn isHeadless(self: *const ApprovalGate) bool {
        return self.post_fn == null;
    }

    /// WORKER THREAD. Block until the user delivers a decision OR
    /// the future is cancelled (returns `error.Canceled` from the
    /// wait). Caller hands ownership of `path` and `diff_text` over;
    /// in the headless path we free them immediately, otherwise the
    /// TUI takes ownership via the posted Request.
    pub fn requestApproval(
        self: *ApprovalGate,
        path: []const u8,
        diff_text: []const u8,
    ) !Decision {
        if (self.isHeadless() or self.bypass) {
            self.gpa.free(@constCast(path));
            self.gpa.free(@constCast(diff_text));
            return .apply;
        }

        try self.post_fn.?(self.post_ctx, .{ .path = path, .diff_text = diff_text });

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (self.response == null) {
            try self.cond.wait(self.io, &self.mutex);
        }
        const decision = self.response.?;
        self.response = null;
        if (decision == .always_apply) self.bypass = true;
        return decision;
    }

    /// MAIN THREAD. Hand a decision to whoever is currently blocked
    /// in `requestApproval`. Uses lockUncancelable so the deliverer
    /// never raises Canceled even if a stray cancel hits the main
    /// thread during this call.
    pub fn deliver(self: *ApprovalGate, decision: Decision) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.response = decision;
        self.cond.signal(self.io);
    }
};

// ───────── tests ─────────

const testing = std.testing;

fn testIo() Io {
    // Tests don't actually call any io operations on the headless
    // path (we never lock the mutex), so the io can come from a
    // throwaway Threaded with a failing allocator. If a test ever
    // hits the cancelable wait path, that's a real allocation; bump
    // this then.
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

test "headless gate auto-approves and frees inputs" {
    const path = try testing.allocator.dupe(u8, "/tmp/x");
    const diff = try testing.allocator.dupe(u8, "+a\n-b\n");
    var gate: ApprovalGate = .init(testing.allocator, testIo());
    const d = try gate.requestApproval(path, diff);
    try testing.expectEqual(Decision.apply, d);
}

test "bypass short-circuits future requests" {
    var gate: ApprovalGate = .init(testing.allocator, testIo());
    gate.bypass = true;
    const path = try testing.allocator.dupe(u8, "/tmp/y");
    const diff = try testing.allocator.dupe(u8, "@@");
    const d = try gate.requestApproval(path, diff);
    try testing.expectEqual(Decision.apply, d);
}

test "non-headless gate posts to fn (no waiter)" {
    const TestPost = struct {
        captured: ?Request = null,

        fn post(ctx: ?*anyopaque, req: Request) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.captured = req;
        }
    };

    var captured: TestPost = .{};
    var gate: ApprovalGate = .init(testing.allocator, testIo());
    gate.post_fn = TestPost.post;
    gate.post_ctx = &captured;
    // Pre-seed the response so requestApproval doesn't actually
    // block — exercises the post path without needing a second
    // thread.
    gate.response = .skip;

    const path = try testing.allocator.dupe(u8, "/tmp/z");
    const diff = try testing.allocator.dupe(u8, "diff body");
    const d = try gate.requestApproval(path, diff);
    try testing.expectEqual(Decision.skip, d);
    try testing.expect(captured.captured != null);
    try testing.expectEqualStrings("/tmp/z", captured.captured.?.path);
    testing.allocator.free(captured.captured.?.path);
    testing.allocator.free(captured.captured.?.diff_text);
}
