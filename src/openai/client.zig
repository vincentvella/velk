//! Thin HTTP wrapper around OpenAI's chat completions endpoint.
//! Mirrors src/anthropic/client.zig: blocking request build, streaming
//! body reader piped into the SSE parser. Auth header is
//! `Authorization: Bearer <api_key>`.

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const sse = @import("../anthropic/sse.zig");

pub const default_base_url = "https://api.openai.com/v1/chat/completions";

pub const Error = error{
    ApiError,
    UnexpectedStatus,
} || std.mem.Allocator.Error;

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    api_key: []const u8,
    base_url: []const u8 = default_base_url,
    http: std.http.Client,
    last_error_body: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, api_key: []const u8, base_url: ?[]const u8) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .api_key = api_key,
            .base_url = base_url orelse default_base_url,
            .http = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.last_error_body) |b| self.gpa.free(b);
        self.http.deinit();
    }

    /// Send a chat completion request with `stream: true` and dispatch
    /// each SSE event to `onEvent`.
    pub fn streamChat(
        self: *Client,
        req: types.ChatRequest,
        ctx: anytype,
        comptime onEvent: fn (@TypeOf(ctx), sse.Event) anyerror!void,
    ) !void {
        var streaming_req = req;
        streaming_req.stream = true;

        const body = try std.json.Stringify.valueAlloc(self.gpa, streaming_req, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);

        const auth_header = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{self.api_key});
        defer self.gpa.free(auth_header);

        const uri = try std.Uri.parse(self.base_url);
        var http_req = try self.http.request(.POST, uri, .{
            .keep_alive = true,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{
                .{ .name = "authorization", .value = auth_header },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "text/event-stream" },
            },
        });
        defer http_req.deinit();

        http_req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try http_req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try http_req.connection.?.flush();

        var redirect_buf: [1024]u8 = undefined;
        var response = try http_req.receiveHead(&redirect_buf);

        const status = @intFromEnum(response.head.status);
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        if (status < 200 or status >= 300) {
            try self.drainErrorBody(reader);
            return Error.ApiError;
        }

        try sse.stream(self.gpa, reader, ctx, onEvent);
    }

    fn drainErrorBody(self: *Client, reader: *Io.Reader) !void {
        if (self.last_error_body) |b| self.gpa.free(b);
        var buf: Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        _ = reader.streamRemaining(&buf.writer) catch {};
        self.last_error_body = try self.gpa.dupe(u8, buf.writer.buffered());
    }
};
