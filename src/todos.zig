//! Model-managed task list. The `todo_write` tool replaces the entire
//! list every time it's called; the TUI snapshots the list under a
//! mutex on each render so the worker thread can mutate freely while
//! the main thread reads.
//!
//! Persistence is in-memory only — the list lives for the duration of
//! the velk process. Resuming a session does not restore todos (the
//! model would need to re-emit them).

const std = @import("std");
const Io = std.Io;

pub const Status = enum {
    pending,
    in_progress,
    completed,

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        return null;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };
    }

    pub fn glyph(self: Status) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .completed => "[x]",
        };
    }
};

pub const Item = struct {
    content: []const u8,
    status: Status = .pending,
};

/// Cross-thread store. `set` replaces the list under the mutex;
/// `snapshot` clones the current list into the caller's arena. The
/// tool runs on the agent worker thread and the TUI renders from the
/// main thread, so neither side touches the other's allocations.
pub const Store = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Item) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |it| self.gpa.free(it.content);
        self.items.deinit(self.gpa);
    }

    /// Replace the entire list. The store dupes each `content` slice
    /// onto its own gpa, so the caller is free to discard the input.
    pub fn set(self: *Store, io: Io, new_items: []const Item) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |it| self.gpa.free(it.content);
        self.items.clearRetainingCapacity();
        try self.items.ensureTotalCapacity(self.gpa, new_items.len);
        for (new_items) |it| {
            const dup = try self.gpa.dupe(u8, it.content);
            self.items.appendAssumeCapacity(.{ .content = dup, .status = it.status });
        }
    }

    /// Returns a copy of the list allocated in `arena`. Caller doesn't
    /// need to free — arena will. The slices borrow into `arena`.
    pub fn snapshot(self: *Store, io: Io, arena: std.mem.Allocator) ![]const Item {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len == 0) return &.{};
        const out = try arena.alloc(Item, self.items.items.len);
        for (self.items.items, 0..) |it, i| {
            out[i] = .{
                .content = try arena.dupe(u8, it.content),
                .status = it.status,
            };
        }
        return out;
    }

    /// `len` reads under the lock so callers can quickly decide
    /// whether to render the panel without paying for a snapshot.
    pub fn len(self: *Store, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.items.items.len;
    }
};

// ───────── tests ─────────

const testing = std.testing;

test "Status.fromString" {
    try testing.expectEqual(Status.pending, Status.fromString("pending").?);
    try testing.expectEqual(Status.in_progress, Status.fromString("in_progress").?);
    try testing.expectEqual(Status.completed, Status.fromString("completed").?);
    try testing.expect(Status.fromString("nope") == null);
}

test "Store: set replaces, snapshot copies" {
    var store: Store = .init(testing.allocator);
    defer store.deinit(std.testing.io);

    const first = [_]Item{
        .{ .content = "draft tests", .status = .in_progress },
        .{ .content = "ship phase 12", .status = .pending },
    };
    try store.set(std.testing.io, &first);
    try testing.expectEqual(@as(usize, 2), store.len(std.testing.io));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const snap = try store.snapshot(std.testing.io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqualStrings("draft tests", snap[0].content);
    try testing.expectEqual(Status.in_progress, snap[0].status);

    // Replacement frees the previous entries.
    const second = [_]Item{.{ .content = "merge", .status = .completed }};
    try store.set(std.testing.io, &second);
    try testing.expectEqual(@as(usize, 1), store.len(std.testing.io));
}

test "Store: empty snapshot yields empty slice" {
    var store: Store = .init(testing.allocator);
    defer store.deinit(std.testing.io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const snap = try store.snapshot(std.testing.io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 0), snap.len);
}
