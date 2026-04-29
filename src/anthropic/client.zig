const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const sse = @import("sse.zig");

pub const default_base_url = "https://api.anthropic.com/v1/messages";
pub const max_retries: u32 = 3;

pub fn shouldRetry(status: u16) bool {
    return status == 429 or (status >= 500 and status < 600);
}

/// Parse the value of a `Retry-After` header. Anthropic + OpenAI both
/// send a non-negative integer count of seconds (the HTTP spec also
/// allows an HTTP-date form, but neither provider does that today).
/// Returns null when absent / unparseable / negative; cap is enforced
/// here so a server can't tell us to sleep for hours.
pub fn parseRetryAfterMs(value: ?[]const u8) ?u64 {
    const v = value orelse return null;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    if (trimmed.len == 0) return null;
    const seconds = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (seconds == 0) return 0;
    const max_seconds: u32 = 60;
    return @as(u64, @min(seconds, max_seconds)) * 1000;
}

/// Sleep before attempt N+1. Honors a `Retry-After` value when the
/// server told us how long to wait; otherwise falls back to
/// exponential backoff (1s, 2s, 4s, capped at 30s).
pub fn retryBackoff(io: Io, attempt: u32, retry_after_ms: ?u64) !void {
    const ms: u64 = if (retry_after_ms) |r|
        // Server-directed wait. Add a small fixed jitter so we
        // don't all wake up at the exact same instant.
        r + 250
    else blk: {
        const base: u64 = 1000;
        break :blk @min(base << @intCast(@min(attempt, 5)), 30_000);
    };
    try Io.sleep(io, Io.Duration.fromMilliseconds(@intCast(ms)), .awake);
}

/// Look up `Retry-After` (case-insensitive) in a response's header
/// iterator. Anthropic 429s carry this; OpenAI 429s do too. Returns
/// null when absent.
pub fn findRetryAfter(response: anytype) ?[]const u8 {
    var iter = response.iterateHeaders();
    while (iter.next()) |h| {
        if (asciiEqlIgnoreCase(h.name, "retry-after")) return h.value;
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl: u8 = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl: u8 = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

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
    /// event to `onEvent` as it arrives. Retries the request setup on
    /// 429 / 5xx with exponential backoff (max 3 retries) — once the body
    /// starts streaming we no longer retry, since the partial output is
    /// already on its way to the user.
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

        if (self.debug) self.dumpRequest(streaming_req, body.len);

        const uri = try std.Uri.parse(self.base_url);
        const extra_headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = types.default_anthropic_version },
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

            if (shouldRetry(status) and attempt < max_retries) {
                // Honor Retry-After when the server provides it
                // (especially important on 429 — Anthropic tells
                // us exactly how long to wait). Falls back to
                // exponential backoff when the header is absent.
                const retry_after = parseRetryAfterMs(findRetryAfter(response.head));
                try retryBackoff(self.io, attempt, retry_after);
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

    fn captureErrorBody(self: *Client, bytes: []const u8) !void {
        if (self.last_error_body) |b| self.gpa.free(b);
        self.last_error_body = try self.gpa.dupe(u8, bytes);
    }

    fn dumpRequest(self: *Client, req: types.MessagesRequest, body_len: usize) void {
        _ = self;
        var sys_len: usize = 0;
        if (req.system) |s| sys_len = s.len;
        const tool_count = if (req.tools) |t| t.len else 0;
        std.debug.print(
            "[debug] anthropic POST · model={s} · msgs={d} · tools={d} · sys={d}b · body={d}b · max_tokens={d}\n",
            .{ req.model, req.messages.len, tool_count, sys_len, body_len, req.max_tokens },
        );
    }
};

// ───────── tests ─────────

const testing = std.testing;

test "parseRetryAfterMs: integer seconds" {
    try testing.expectEqual(@as(?u64, 5000), parseRetryAfterMs("5"));
    try testing.expectEqual(@as(?u64, 0), parseRetryAfterMs("0"));
    try testing.expectEqual(@as(?u64, 1000), parseRetryAfterMs("1"));
}

test "parseRetryAfterMs: trims whitespace" {
    try testing.expectEqual(@as(?u64, 3000), parseRetryAfterMs("  3 \r\n"));
}

test "parseRetryAfterMs: caps at 60 seconds so a server can't hold us hostage" {
    try testing.expectEqual(@as(?u64, 60_000), parseRetryAfterMs("3600"));
    try testing.expectEqual(@as(?u64, 60_000), parseRetryAfterMs("99999"));
}

test "parseRetryAfterMs: null / empty / non-numeric returns null" {
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs(null));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs(""));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs("   "));
    // HTTP-date form (RFC 7231) — neither Anthropic nor OpenAI sends
    // this, and supporting it adds a date parser; reject for now.
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs("Wed, 21 Oct 2026 07:28:00 GMT"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs("soon"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs("-5"));
}

test "asciiEqlIgnoreCase: matches across case" {
    try testing.expect(asciiEqlIgnoreCase("Retry-After", "retry-after"));
    try testing.expect(asciiEqlIgnoreCase("RETRY-AFTER", "Retry-After"));
    try testing.expect(!asciiEqlIgnoreCase("Retry-After", "Content-Type"));
    try testing.expect(!asciiEqlIgnoreCase("short", "longer"));
}
