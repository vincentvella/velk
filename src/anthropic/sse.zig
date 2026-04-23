//! Generic Server-Sent Events parser. Reads line-delimited `event:` /
//! `data:` lines from a `std.Io.Reader` and dispatches a complete event
//! on each blank-line boundary. Slices passed to `onEvent` are valid
//! only during the callback — copy if you need to keep them.

const std = @import("std");
const Io = std.Io;

pub const Event = struct {
    /// Empty when the source omitted `event:` (defaults to "message" per spec,
    /// but Anthropic always sends one so we leave the empty signal intact).
    name: []const u8,
    /// Concatenation of all `data:` lines for this event, joined by '\n'.
    data: []const u8,
};

pub const StreamError = error{
    SseLineTooLong,
} || Io.Reader.Error;

/// Read SSE events from `reader` until EOF, calling `onEvent` for each.
/// `gpa` is used to grow the per-event accumulators; both are reset between
/// events so peak memory is one event's worth.
pub fn stream(
    gpa: std.mem.Allocator,
    reader: *Io.Reader,
    ctx: anytype,
    comptime onEvent: fn (@TypeOf(ctx), Event) anyerror!void,
) !void {
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    while (true) {
        const inclusive = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Dispatch a trailing event if the stream ended without a
                // blank line (some servers do this).
                if (data.items.len > 0 or name.items.len > 0) {
                    try onEvent(ctx, .{ .name = name.items, .data = data.items });
                }
                return;
            },
            error.StreamTooLong => return error.SseLineTooLong,
            else => |e| return e,
        };

        // Strip trailing \n and any preceding \r (CRLF).
        var line = inclusive[0 .. inclusive.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (line.len == 0) {
            if (data.items.len > 0 or name.items.len > 0) {
                try onEvent(ctx, .{ .name = name.items, .data = data.items });
            }
            name.clearRetainingCapacity();
            data.clearRetainingCapacity();
            continue;
        }

        // Comment line per SSE spec.
        if (line[0] == ':') continue;

        if (parseField(line, "event:")) |v| {
            name.clearRetainingCapacity();
            try name.appendSlice(gpa, v);
        } else if (parseField(line, "data:")) |v| {
            if (data.items.len > 0) try data.append(gpa, '\n');
            try data.appendSlice(gpa, v);
        }
        // Other fields (id:, retry:) are ignored — Anthropic doesn't use them.
    }
}

fn parseField(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    // SSE spec: a single optional leading space after the colon is stripped.
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

// ───────── tests ─────────

const testing = std.testing;

const Collected = struct {
    list: std.ArrayList(struct { name: []const u8, data: []const u8 }) = .empty,
    gpa: std.mem.Allocator,

    fn record(self: *Collected, ev: Event) anyerror!void {
        try self.list.append(self.gpa, .{
            .name = try self.gpa.dupe(u8, ev.name),
            .data = try self.gpa.dupe(u8, ev.data),
        });
    }

    fn deinit(self: *Collected) void {
        for (self.list.items) |it| {
            self.gpa.free(it.name);
            self.gpa.free(it.data);
        }
        self.list.deinit(self.gpa);
    }
};

fn collect(input: []const u8) !Collected {
    var collected: Collected = .{ .gpa = testing.allocator };
    errdefer collected.deinit();
    var r: Io.Reader = .fixed(input);
    try stream(testing.allocator, &r, &collected, Collected.record);
    return collected;
}

test "stream: single event with name and data" {
    var c = try collect("event: message_start\ndata: {\"x\":1}\n\n");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.list.items.len);
    try testing.expectEqualStrings("message_start", c.list.items[0].name);
    try testing.expectEqualStrings("{\"x\":1}", c.list.items[0].data);
}

test "stream: multiple events separated by blank lines" {
    var c = try collect(
        "event: a\ndata: 1\n\nevent: b\ndata: 2\n\nevent: c\ndata: 3\n\n",
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 3), c.list.items.len);
    try testing.expectEqualStrings("a", c.list.items[0].name);
    try testing.expectEqualStrings("1", c.list.items[0].data);
    try testing.expectEqualStrings("c", c.list.items[2].name);
    try testing.expectEqualStrings("3", c.list.items[2].data);
}

test "stream: multi-line data joined with newlines" {
    var c = try collect("event: msg\ndata: line1\ndata: line2\n\n");
    defer c.deinit();
    try testing.expectEqualStrings("line1\nline2", c.list.items[0].data);
}

test "stream: CRLF line endings work" {
    var c = try collect("event: x\r\ndata: y\r\n\r\n");
    defer c.deinit();
    try testing.expectEqualStrings("x", c.list.items[0].name);
    try testing.expectEqualStrings("y", c.list.items[0].data);
}

test "stream: comment lines ignored" {
    var c = try collect(": this is a comment\nevent: x\ndata: y\n\n");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.list.items.len);
    try testing.expectEqualStrings("x", c.list.items[0].name);
}

test "stream: trailing event without final blank line dispatched" {
    var c = try collect("event: x\ndata: y\n");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.list.items.len);
    try testing.expectEqualStrings("y", c.list.items[0].data);
}

test "stream: data without leading space" {
    var c = try collect("event: x\ndata:y\n\n");
    defer c.deinit();
    try testing.expectEqualStrings("y", c.list.items[0].data);
}

test "stream: empty input dispatches nothing" {
    var c = try collect("");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.list.items.len);
}
