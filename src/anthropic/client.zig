const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

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

    fn captureErrorBody(self: *Client, bytes: []const u8) !void {
        if (self.last_error_body) |b| self.gpa.free(b);
        self.last_error_body = try self.gpa.dupe(u8, bytes);
    }
};
