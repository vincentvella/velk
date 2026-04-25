//! Thin HTTP wrapper around OpenAI's chat completions endpoint.
//! Mirrors src/anthropic/client.zig: blocking request build, streaming
//! body reader piped into the SSE parser. Auth header is
//! `Authorization: Bearer <api_key>`.

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const sse = @import("../anthropic/sse.zig");
const anth_client = @import("../anthropic/client.zig");

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
    /// When true, dump a one-line request envelope summary to stderr
    /// before each call. Driven by the CLI `--debug` flag.
    debug: bool = false,

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
    /// each SSE event to `onEvent`. Retries on 429/5xx with exponential
    /// backoff (max 3 retries, mirroring the Anthropic client).
    pub fn streamChat(
        self: *Client,
        req: types.ChatRequest,
        ctx: anytype,
        comptime onEvent: fn (@TypeOf(ctx), sse.Event) anyerror!void,
    ) !void {
        var streaming_req = req;
        streaming_req.stream = true;
        streaming_req.stream_options = .{ .include_usage = true };

        const body = try std.json.Stringify.valueAlloc(self.gpa, streaming_req, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);

        if (self.debug) self.dumpRequest(streaming_req, body.len);

        const auth_header = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{self.api_key});
        defer self.gpa.free(auth_header);

        const uri = try std.Uri.parse(self.base_url);
        const extra_headers = &[_]std.http.Header{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
        };

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            var http_req = try self.http.request(.POST, uri, .{
                .keep_alive = true,
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
                .extra_headers = extra_headers,
            });
            var keep_req = false;
            defer if (!keep_req) http_req.deinit();

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

            if (anth_client.shouldRetry(status) and attempt < anth_client.max_retries) {
                try anth_client.retryBackoff(self.io, attempt);
                continue;
            }

            if (status < 200 or status >= 300) {
                try self.drainErrorBody(reader);
                return Error.ApiError;
            }

            keep_req = true;
            defer http_req.deinit();
            try sse.stream(self.gpa, reader, ctx, onEvent);
            return;
        }
    }

    fn drainErrorBody(self: *Client, reader: *Io.Reader) !void {
        if (self.last_error_body) |b| self.gpa.free(b);
        var buf: Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        _ = reader.streamRemaining(&buf.writer) catch {};
        self.last_error_body = try self.gpa.dupe(u8, buf.writer.buffered());
    }

    fn dumpRequest(self: *Client, req: types.ChatRequest, body_len: usize) void {
        _ = self;
        const tool_count = if (req.tools) |t| t.len else 0;
        std.debug.print(
            "[debug] openai POST · model={s} · msgs={d} · tools={d} · body={d}b\n",
            .{ req.model, req.messages.len, tool_count, body_len },
        );
    }
};
