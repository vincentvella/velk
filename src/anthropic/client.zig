const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const sse = @import("sse.zig");

pub const default_base_url = "https://api.anthropic.com/v1/messages";

pub const Error = error{
    // Surfaced when the API returns 4xx/5xx with a parseable error body.
    ApiError,
    // 4xx/5xx where we couldn't parse a JSON error body.
    UnexpectedStatus,
    // Successful status but the body didn't match MessagesResponse.
    ResponseParseFailure,
} || std.mem.Allocator.Error;

pub const Result = struct {
    parsed: std.json.Parsed(types.MessagesResponse),
    status: u16,

    pub fn deinit(self: *Result) void {
        self.parsed.deinit();
    }

    pub fn value(self: *const Result) types.MessagesResponse {
        return self.parsed.value;
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    api_key: []const u8,
    base_url: []const u8 = default_base_url,
    http: std.http.Client,
    last_error_body: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, api_key: []const u8) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .api_key = api_key,
            .http = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.last_error_body) |b| self.gpa.free(b);
        self.http.deinit();
    }

    /// Send a Messages API request. On non-2xx, the raw body is captured in
    /// `self.last_error_body` (overwriting any previous one) so the caller
    /// can format a useful message.
    pub fn createMessage(self: *Client, req: types.MessagesRequest) !Result {
        const body = try std.json.Stringify.valueAlloc(self.gpa, req, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);

        var resp_buf: Io.Writer.Allocating = .init(self.gpa);
        defer resp_buf.deinit();

        const fetch_result = try self.http.fetch(.{
            .location = .{ .url = self.base_url },
            .method = .POST,
            .payload = body,
            .response_writer = &resp_buf.writer,
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = types.default_anthropic_version },
                .{ .name = "content-type", .value = "application/json" },
            },
        });

        const status = @intFromEnum(fetch_result.status);
        const response_bytes = resp_buf.writer.buffered();

        if (status < 200 or status >= 300) {
            try self.captureErrorBody(response_bytes);
            return Error.ApiError;
        }

        const parsed = std.json.parseFromSlice(
            types.MessagesResponse,
            self.gpa,
            response_bytes,
            .{ .ignore_unknown_fields = true },
        ) catch {
            try self.captureErrorBody(response_bytes);
            return Error.ResponseParseFailure;
        };

        return .{ .parsed = parsed, .status = status };
    }

    /// Send a Messages API request with `stream: true` and dispatch each SSE
    /// event to `onEvent` as it arrives. Forces `req.stream = true`.
    /// On non-2xx, drains the body into `self.last_error_body` and returns
    /// `Error.ApiError` without invoking `onEvent`.
    pub fn streamMessage(
        self: *Client,
        req: types.MessagesRequest,
        ctx: anytype,
        comptime onEvent: fn (@TypeOf(ctx), sse.Event) anyerror!void,
    ) !void {
        var streaming_req = req;
        streaming_req.stream = true;

        const body = try std.json.Stringify.valueAlloc(self.gpa, streaming_req, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);

        const uri = try std.Uri.parse(self.base_url);
        var http_req = try self.http.request(.POST, uri, .{
            .keep_alive = true,
            // Force uncompressed body so we can feed bytes straight into the
            // SSE parser. Compression on tiny event frames isn't worth the
            // extra Decompress wiring (and the server would otherwise pick
            // gzip/zstd, leaving the parser staring at binary garbage).
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = types.default_anthropic_version },
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

    fn captureErrorBody(self: *Client, bytes: []const u8) !void {
        if (self.last_error_body) |b| self.gpa.free(b);
        self.last_error_body = try self.gpa.dupe(u8, bytes);
    }
};
