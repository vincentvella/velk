//! Shared HTTP / caching / robots layer for the WebFetch +
//! WebSearch tools. Wraps `std.http.Client` with a uniform GET
//! that respects a per-process cache and a robots.txt check.
//!
//! V1 scope: text bodies only (we don't run an HTML→markdown pass
//! yet — the model handles raw HTML well enough for Q&A on a page).
//! Cache TTL is fixed at 15 minutes.

const std = @import("std");
const Io = std.Io;
const html_md = @import("html_md.zig");

pub const cache_ttl_seconds: i64 = 15 * 60;
pub const max_body_bytes: usize = 256 * 1024;
pub const user_agent: []const u8 = "velk/0.0.1 (+https://github.com/vincentvella/velk)";

pub const Error = error{
    HomeDirUnknown,
    DisallowedByRobots,
    HttpStatus,
} || std.mem.Allocator.Error;

pub const FetchResult = struct {
    status: u16,
    body: []const u8,
    /// Server-reported content type (lowercased, parameter
    /// stripped) or empty when unknown.
    content_type: []const u8 = "",
    /// True when the body came from the on-disk cache (no network
    /// hit on this call).
    from_cache: bool = false,
};

/// Top-level: GET `url`, honoring robots + cache. HTML bodies are
/// converted to markdown via `html_md.convert`; everything else is
/// returned as-is (capped at `max_body_bytes`). Use the lower-level
/// helpers directly if you need finer control.
pub fn fetch(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    url: []const u8,
) !FetchResult {
    // Cache hit? (Avoids both the robots check + the network round
    // trip — the URL was already validated last time.)
    if (cachePath(arena, env_map, url)) |path| {
        if (readCache(arena, io, path)) |body| {
            return .{ .status = 200, .body = body, .from_cache = true };
        } else |_| {}
    } else |_| {}

    // Robots check (best-effort: failure to fetch robots.txt does
    // NOT block the request — we only enforce explicit Disallow).
    if (try robotsAllows(arena, io, gpa, url)) {} else return Error.DisallowedByRobots;

    var got = try doFetch(arena, io, gpa, url);
    if (looksLikeHtml(got.body)) {
        got.body = try html_md.convert(arena, got.body, .{});
    }
    if (got.status >= 200 and got.status < 300) {
        if (cachePath(arena, env_map, url)) |path| {
            writeCache(arena, io, path, got.body) catch {};
        } else |_| {}
    }
    return got;
}

/// True when the body's leading bytes look like HTML (starts with
/// `<!doctype` or contains an opening html/body/head tag in the
/// first 1KB).
fn looksLikeHtml(body: []const u8) bool {
    var head_buf: [128]u8 = undefined;
    const head_len = @min(body.len, head_buf.len);
    for (body[0..head_len], 0..) |c, i| head_buf[i] = std.ascii.toLower(c);
    const head_lower = head_buf[0..head_len];
    if (std.mem.startsWith(u8, head_lower, "<!doctype html")) return true;
    const probe_end = @min(body.len, 1024);
    var probe_buf: [1024]u8 = undefined;
    for (body[0..probe_end], 0..) |c, i| probe_buf[i] = std.ascii.toLower(c);
    const lower = probe_buf[0..probe_end];
    return std.mem.indexOf(u8, lower, "<html") != null or
        std.mem.indexOf(u8, lower, "<body") != null or
        std.mem.indexOf(u8, lower, "<head") != null;
}

/// One-shot HTTP GET with our user-agent header, body capped at
/// `max_body_bytes`. No caching, no robots.
pub fn doFetch(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    url: []const u8,
) !FetchResult {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var resp_buf: Io.Writer.Allocating = .init(gpa);
    defer resp_buf.deinit();

    const result = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &resp_buf.writer,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = user_agent },
            .{ .name = "accept", .value = "text/html, text/plain, application/json, */*" },
        },
    });

    const status = @intFromEnum(result.status);
    const buffered = resp_buf.writer.buffered();
    const len = @min(buffered.len, max_body_bytes);
    const body = try arena.dupe(u8, buffered[0..len]);
    return .{ .status = status, .body = body };
}

// ─── robots.txt ────────────────────────────────────────────

/// Fetch the origin's `/robots.txt` and return true when `url`'s
/// path is allowed for our user-agent (or when robots is missing /
/// unparseable — fail-open, match the de-facto convention).
pub fn robotsAllows(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    url: []const u8,
) !bool {
    const origin = originOf(url) orelse return true;
    const robots_url = try std.fmt.allocPrint(arena, "{s}/robots.txt", .{origin});

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const got = http.fetch(.{
        .location = .{ .url = robots_url },
        .method = .GET,
        .response_writer = &buf.writer,
        .extra_headers = &.{.{ .name = "user-agent", .value = user_agent }},
    }) catch return true;

    const status = @intFromEnum(got.status);
    if (status < 200 or status >= 300) return true;

    const text = buf.writer.buffered();
    const path = pathOf(url) orelse "/";
    return parseRobotsAllows(text, path);
}

/// Pure parser: returns `true` when `path` is allowed for
/// User-agent: *. Walks the file looking for the most-specific
/// matching `Disallow:` rule. Honors trailing `Allow:` overrides.
pub fn parseRobotsAllows(text: []const u8, path: []const u8) bool {
    var ua_section_active = false;
    var saw_star_section = false;
    var matching_disallow: ?[]const u8 = null;
    var matching_allow: ?[]const u8 = null;

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or line[0] == '#') continue;

        if (eqIgnoreCasePrefix(line, "user-agent:")) {
            const v = std.mem.trim(u8, line["user-agent:".len..], " \t");
            // Switch sections: a new User-agent block resets the
            // accumulators only when it actually applies to us.
            if (std.mem.eql(u8, v, "*")) {
                ua_section_active = true;
                saw_star_section = true;
            } else {
                ua_section_active = false;
            }
            continue;
        }
        if (!ua_section_active) continue;

        if (eqIgnoreCasePrefix(line, "disallow:")) {
            const v = std.mem.trim(u8, line["disallow:".len..], " \t");
            if (v.len == 0) continue;
            if (std.mem.startsWith(u8, path, v)) {
                if (matching_disallow == null or v.len > matching_disallow.?.len) {
                    matching_disallow = v;
                }
            }
        } else if (eqIgnoreCasePrefix(line, "allow:")) {
            const v = std.mem.trim(u8, line["allow:".len..], " \t");
            if (v.len == 0) continue;
            if (std.mem.startsWith(u8, path, v)) {
                if (matching_allow == null or v.len > matching_allow.?.len) {
                    matching_allow = v;
                }
            }
        }
    }
    if (!saw_star_section) return true; // no rules for us
    if (matching_disallow) |d| {
        if (matching_allow) |a| return a.len > d.len;
        return false;
    }
    return true;
}

fn eqIgnoreCasePrefix(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (std.ascii.toLower(p) != std.ascii.toLower(s[i])) return false;
    }
    return true;
}

fn trimLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Return the scheme+host of `url`, e.g. "https://example.com".
/// Null when we can't parse the URL.
pub fn originOf(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOf(u8, url, "://") orelse return null;
    const after = colon + 3;
    if (after >= url.len) return null;
    const slash = std.mem.indexOfScalarPos(u8, url, after, '/') orelse return url;
    return url[0..slash];
}

/// Return the path portion of `url`, defaulting to "/" when the
/// URL has no path. Includes querystring.
pub fn pathOf(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOf(u8, url, "://") orelse return null;
    const after = colon + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, after, '/') orelse return "/";
    return url[slash..];
}

// ─── search backends ───────────────────────────────────────

pub const SearchHit = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

/// Brave Search API. Requires `BRAVE_API_KEY` (caller passes it
/// via the `key` arg). Returns formatted text with top-N hits.
pub fn braveSearch(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    query: []const u8,
    key: []const u8,
    max_results: usize,
) ![]const u8 {
    const encoded = try urlEncode(arena, query);
    const url = try std.fmt.allocPrint(
        arena,
        "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}",
        .{ encoded, max_results },
    );

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    const auth_header = try std.fmt.allocPrint(arena, "{s}", .{key});
    const got = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &buf.writer,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = user_agent },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "x-subscription-token", .value = auth_header },
        },
    });
    const status = @intFromEnum(got.status);
    if (status < 200 or status >= 300) return Error.HttpStatus;

    const Response = struct {
        web: ?struct {
            results: []const struct {
                title: []const u8 = "",
                url: []const u8 = "",
                description: []const u8 = "",
            } = &.{},
        } = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Response, arena, buf.writer.buffered(), .{ .ignore_unknown_fields = true }) catch
        return Error.HttpStatus;

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "Brave Search: \"{s}\"\n\n", .{query});
    const results = if (parsed.web) |w| w.results else &.{};
    if (results.len == 0) {
        try out.appendSlice(arena, "(no results)\n");
        return out.items;
    }
    const limit = @min(results.len, max_results);
    for (results[0..limit], 0..) |r, idx| {
        try out.print(arena, "{d}. {s}\n   {s}\n   {s}\n\n", .{
            idx + 1, r.title, r.url, stripHtmlTags(arena, r.description) catch r.description,
        });
    }
    return out.items;
}

/// DuckDuckGo HTML endpoint scrape. Best-effort parser of the
/// `result__a` / `result__snippet` block structure. Caches the
/// raw HTML response via `cachePath`.
pub fn duckduckgoSearch(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    query: []const u8,
    max_results: usize,
) ![]const u8 {
    const encoded = try urlEncode(arena, query);
    const url = try std.fmt.allocPrint(
        arena,
        "https://html.duckduckgo.com/html/?q={s}",
        .{encoded},
    );

    // Read cache if fresh.
    if (cachePath(arena, env_map, url)) |path| {
        if (readCache(arena, io, path)) |body| {
            return formatDdgResults(arena, query, body, max_results);
        } else |_| {}
    } else |_| {}

    const got = try doFetch(arena, io, gpa, url);
    if (got.status < 200 or got.status >= 300) return Error.HttpStatus;
    if (cachePath(arena, env_map, url)) |path| {
        writeCache(arena, io, path, got.body) catch {};
    } else |_| {}
    return formatDdgResults(arena, query, got.body, max_results);
}

fn formatDdgResults(
    arena: std.mem.Allocator,
    query: []const u8,
    html: []const u8,
    max_results: usize,
) ![]const u8 {
    const hits = try parseDdgHits(arena, html, max_results);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "DuckDuckGo: \"{s}\"\n\n", .{query});
    if (hits.len == 0) {
        try out.appendSlice(arena, "(no results — DuckDuckGo may have rate-limited or changed their HTML format)\n");
        return out.items;
    }
    for (hits, 0..) |h, idx| {
        try out.print(arena, "{d}. {s}\n   {s}\n   {s}\n\n", .{ idx + 1, h.title, h.url, h.snippet });
    }
    return out.items;
}

/// Parse DuckDuckGo's `?html` response into a structured hit list.
/// Looks for the `class="result__a"` anchor + sibling
/// `class="result__snippet"` element pattern. DuckDuckGo wraps
/// outbound URLs in a redirect: we extract the original via the
/// `uddg=` querystring parameter.
pub fn parseDdgHits(
    arena: std.mem.Allocator,
    html: []const u8,
    max_results: usize,
) ![]SearchHit {
    var hits: std.ArrayList(SearchHit) = .empty;
    var search_pos: usize = 0;

    while (hits.items.len < max_results) {
        // Find next `class="result__a"`.
        const anchor_class = std.mem.indexOfPos(u8, html, search_pos, "class=\"result__a\"") orelse break;
        // Walk back to the enclosing `<a` tag start.
        const tag_open = std.mem.lastIndexOf(u8, html[0..anchor_class], "<a ") orelse {
            search_pos = anchor_class + 1;
            continue;
        };
        const tag_close = std.mem.indexOfScalarPos(u8, html, anchor_class, '>') orelse {
            search_pos = anchor_class + 1;
            continue;
        };
        const tag_attrs = html[tag_open + 3 .. tag_close];
        const raw_href = attrInZone(tag_attrs, "href");
        const url = try resolveDdgRedirect(arena, raw_href);

        // Title text spans from after '>' to the next "</a>".
        const title_start = tag_close + 1;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;
        const title = try stripHtmlTags(arena, html[title_start..title_end]);
        const title_trimmed = std.mem.trim(u8, title, " \n\r\t");

        // Snippet: next `class="result__snippet"` after this hit.
        var snippet: []const u8 = "";
        if (std.mem.indexOfPos(u8, html, title_end, "class=\"result__snippet\"")) |sn_class| {
            if (std.mem.indexOfScalarPos(u8, html, sn_class, '>')) |sn_open| {
                if (std.mem.indexOfPos(u8, html, sn_open, "</a>")) |sn_close| {
                    const raw = html[sn_open + 1 .. sn_close];
                    const s = try stripHtmlTags(arena, raw);
                    snippet = std.mem.trim(u8, s, " \n\r\t");
                }
            }
        }

        try hits.append(arena, .{
            .title = try arena.dupe(u8, title_trimmed),
            .url = url,
            .snippet = try arena.dupe(u8, snippet),
        });
        search_pos = title_end + "</a>".len;
    }
    return hits.toOwnedSlice(arena);
}

fn attrInZone(zone: []const u8, name: []const u8) []const u8 {
    var i: usize = 0;
    while (i < zone.len) {
        while (i < zone.len and std.ascii.isWhitespace(zone[i])) i += 1;
        const n_start = i;
        while (i < zone.len and zone[i] != '=' and !std.ascii.isWhitespace(zone[i])) i += 1;
        const this_name = zone[n_start..i];
        while (i < zone.len and std.ascii.isWhitespace(zone[i])) i += 1;
        if (i >= zone.len or zone[i] != '=') continue;
        i += 1;
        while (i < zone.len and std.ascii.isWhitespace(zone[i])) i += 1;
        if (i >= zone.len) break;
        const quoted = zone[i] == '"' or zone[i] == '\'';
        const quote = if (quoted) zone[i] else 0;
        if (quoted) i += 1;
        const v_start = i;
        if (quoted) {
            while (i < zone.len and zone[i] != quote) i += 1;
        } else {
            while (i < zone.len and !std.ascii.isWhitespace(zone[i])) i += 1;
        }
        const value = zone[v_start..i];
        if (eqIgnoreCase(this_name, name)) return value;
        if (quoted and i < zone.len) i += 1;
    }
    return "";
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// DuckDuckGo wraps outbound URLs with `//duckduckgo.com/l/?uddg=…`.
/// Pull the original out of the querystring + percent-decode it.
fn resolveDdgRedirect(arena: std.mem.Allocator, href: []const u8) ![]const u8 {
    const marker = "uddg=";
    const start = std.mem.indexOf(u8, href, marker) orelse return arena.dupe(u8, href);
    const after = start + marker.len;
    var end = after;
    while (end < href.len and href[end] != '&') end += 1;
    return percentDecode(arena, href[after..end]);
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(arena, s[i]);
                i += 1;
                continue;
            };
            try out.append(arena, v);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(arena, ' ');
            i += 1;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const safe = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

fn stripHtmlTags(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, s, i, '>') orelse break;
            i = end + 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

// ─── cache ──────────────────────────────────────────────────

pub fn cachePath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    url: []const u8,
) ![]const u8 {
    const base = if (env_map.get("XDG_CACHE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.cache", .{home});
    };
    const hash = std.hash.Wyhash.hash(0, url);
    return try std.fmt.allocPrint(arena, "{s}/velk/web/{x:0>16}.cache", .{ base, hash });
}

const CacheHeader = struct {
    ts: i64,
};

fn readCache(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_body_bytes + 64));
    // First line: "<ts>\n", remainder is body.
    const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return error.MalformedCache;
    const ts = std.fmt.parseInt(i64, data[0..nl], 10) catch return error.MalformedCache;
    const now = Io.Clock.now(.real, io).toSeconds();
    if (now - ts > cache_ttl_seconds) return error.Expired;
    return data[nl + 1 ..];
}

fn writeCache(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    body: []const u8,
) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, path[0..slash]);
    const now = Io.Clock.now(.real, io).toSeconds();
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "{d}\n", .{now});
    try buf.appendSlice(arena, body);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

fn mkdirAllAbsolute(io: Io, abs_path: []const u8) !void {
    if (abs_path.len == 0 or abs_path[0] != '/') return;
    var i: usize = 1;
    while (true) {
        const next = std.mem.indexOfScalarPos(u8, abs_path, i, '/');
        const end = next orelse abs_path.len;
        if (end > i) {
            const prefix = abs_path[0..end];
            Io.Dir.createDirAbsolute(io, prefix, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        if (next == null) return;
        i = end + 1;
    }
}

// ───────── tests ─────────

const testing = std.testing;

test "originOf: typical URLs" {
    try testing.expectEqualStrings("https://example.com", originOf("https://example.com/foo/bar?x=1").?);
    try testing.expectEqualStrings("http://localhost:8080", originOf("http://localhost:8080/api").?);
    try testing.expectEqualStrings("https://x.y.z", originOf("https://x.y.z").?);
    try testing.expect(originOf("not-a-url") == null);
}

test "pathOf: defaults to /" {
    try testing.expectEqualStrings("/foo/bar", pathOf("https://example.com/foo/bar").?);
    try testing.expectEqualStrings("/", pathOf("https://example.com").?);
    try testing.expectEqualStrings("/?q=1", pathOf("https://example.com/?q=1").?);
}

test "parseRobotsAllows: no rules → allowed" {
    try testing.expect(parseRobotsAllows("", "/anything"));
    try testing.expect(parseRobotsAllows("# just a comment\n", "/anything"));
}

test "parseRobotsAllows: User-agent: * Disallow: / blocks everything" {
    const r = "User-agent: *\nDisallow: /\n";
    try testing.expect(!parseRobotsAllows(r, "/foo"));
    try testing.expect(!parseRobotsAllows(r, "/"));
}

test "parseRobotsAllows: targeted Disallow" {
    const r = "User-agent: *\nDisallow: /admin\nDisallow: /private/\n";
    try testing.expect(!parseRobotsAllows(r, "/admin/login"));
    try testing.expect(!parseRobotsAllows(r, "/private/x"));
    try testing.expect(parseRobotsAllows(r, "/public/x"));
    try testing.expect(parseRobotsAllows(r, "/"));
}

test "parseRobotsAllows: Allow overrides a more-specific Disallow" {
    const r =
        "User-agent: *\n" ++
        "Disallow: /search\n" ++
        "Allow: /search/special\n";
    try testing.expect(!parseRobotsAllows(r, "/search/foo"));
    try testing.expect(parseRobotsAllows(r, "/search/special/page"));
}

test "parseDdgHits: extracts title + url + snippet from realistic markup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const html =
        \\<div class="result">
        \\  <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fone&rut=1">First Hit</a>
        \\  <a class="result__snippet" href="...">First snippet text</a>
        \\</div>
        \\<div class="result">
        \\  <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Ftwo">Second <b>Hit</b></a>
        \\  <a class="result__snippet" href="...">Snippet with <em>em</em> tags</a>
        \\</div>
    ;
    const hits = try parseDdgHits(arena.allocator(), html, 5);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("First Hit", hits[0].title);
    try testing.expectEqualStrings("https://example.com/one", hits[0].url);
    try testing.expectEqualStrings("First snippet text", hits[0].snippet);
    try testing.expectEqualStrings("Second Hit", hits[1].title);
    try testing.expectEqualStrings("https://example.com/two", hits[1].url);
    try testing.expectEqualStrings("Snippet with em tags", hits[1].snippet);
}

test "parseDdgHits: caps at max_results" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const block =
        \\<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com">A</a>
        \\<a class="result__snippet" href="...">snip</a>
    ;
    const html = block ++ "\n" ++ block ++ "\n" ++ block;
    const hits = try parseDdgHits(arena.allocator(), html, 2);
    try testing.expectEqual(@as(usize, 2), hits.len);
}

test "percentDecode: unescapes + handles plus-as-space" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try percentDecode(arena.allocator(), "hello+world%20%21");
    try testing.expectEqualStrings("hello world !", out);
}

test "urlEncode: encodes spaces and ampersands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try urlEncode(arena.allocator(), "zig 0.16 & beyond");
    try testing.expectEqualStrings("zig%200.16%20%26%20beyond", out);
}

test "stripHtmlTags: keeps text only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try stripHtmlTags(arena.allocator(), "<b>hi</b> <a href='x'>there</a>");
    try testing.expectEqualStrings("hi there", out);
}

test "parseRobotsAllows: targeted UA section ignored when not us" {
    const r =
        "User-agent: BadBot\n" ++
        "Disallow: /\n" ++
        "User-agent: *\n" ++
        "Disallow: /private\n";
    try testing.expect(parseRobotsAllows(r, "/public"));
    try testing.expect(!parseRobotsAllows(r, "/private/x"));
}
