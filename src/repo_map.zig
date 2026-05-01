//! Repo map — a filtered directory listing prepended to the system
//! prompt so the model has the project shape on every turn without
//! the user copy-pasting it. Optional symbol skeleton mode renders
//! up to `max_symbols_per_file` top-level decls per source file via
//! per-language regexes (Zig, Rust, TS/JS, Python, Go).
//!
//! Caching: the map is regenerated when `git status --porcelain`
//! output changes — i.e. whenever the user edits, stages, or
//! commits a file. The cache lives at
//! `$XDG_CACHE_HOME/velk/<base32-of-cwd>/repo-map.cache` so two
//! checkouts of the same repo (e.g. a worktree) don't clobber
//! each other.

const std = @import("std");
const Io = std.Io;
const ignore = @import("ignore.zig");
const git_commit = @import("git_commit.zig");

pub const max_entries: usize = 500;
pub const max_depth: u8 = 6;
/// Cap on the number of top-level symbols rendered per file when
/// symbol-skeleton mode is on. Bounds the generated map size; the
/// model can read the file directly when it needs more.
pub const max_symbols_per_file: usize = 12;
/// Cap on bytes read per file when extracting symbols. We only need
/// the top-of-file decl shape; reading the whole 100 KB body just to
/// regex-match line-prefixes is wasteful.
pub const max_symbol_scan_bytes: usize = 32 * 1024;

pub const Error = error{
    HomeDirUnknown,
} || std.mem.Allocator.Error;

/// Walk CWD and produce a flat-but-indented listing string. Sizes
/// are shown for files; directories get a trailing `/`. Hits the
/// ignore filter from `src/ignore.zig` so node_modules etc. don't
/// pollute the output. `with_symbols=true` adds up to
/// `max_symbols_per_file` top-level decls (per-language regex) under
/// each source file.
pub fn generate(arena: std.mem.Allocator, io: Io) ![]const u8 {
    return generateWithOptions(arena, io, .{});
}

pub const Options = struct {
    with_symbols: bool = false,
};

pub fn generateWithOptions(arena: std.mem.Allocator, io: Io, opts: Options) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, if (opts.with_symbols)
        "Repo layout (filtered, with top-level symbols):\n"
    else
        "Repo layout (filtered):\n");
    var entry_count: usize = 0;
    try walk(arena, io, "", 0, &out, &entry_count, opts);
    if (entry_count >= max_entries) {
        try out.print(arena, "… (truncated at {d} entries)\n", .{max_entries});
    }
    return out.items;
}

fn walk(
    arena: std.mem.Allocator,
    io: Io,
    rel: []const u8,
    depth: u8,
    out: *std.ArrayList(u8),
    entry_count: *usize,
    opts: Options,
) !void {
    if (depth > max_depth) return;
    if (entry_count.* >= max_entries) return;

    const dir_path: []const u8 = if (rel.len == 0) "." else rel;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    var names: std.ArrayList(NamedEntry) = .empty;
    while (try iter.next(io)) |entry| {
        if (ignore.isIgnored(entry.name)) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') {
            // Skip dotfiles other than the few we explicitly want
            // (kept simple: just always skip — they rarely add
            // signal in a repo overview, and the ignore set already
            // catches `.git` etc).
            continue;
        }
        try names.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }
    std.mem.sort(NamedEntry, names.items, {}, NamedEntry.lessThan);

    for (names.items) |entry| {
        if (entry_count.* >= max_entries) return;
        const child_rel = if (rel.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        try indent(arena, out, depth);
        switch (entry.kind) {
            .directory => {
                try out.print(arena, "{s}/\n", .{entry.name});
                entry_count.* += 1;
                try walk(arena, io, child_rel, depth + 1, out, entry_count, opts);
            },
            .file => {
                const stat = Io.Dir.cwd().statFile(io, child_rel, .{}) catch {
                    try out.print(arena, "{s}\n", .{entry.name});
                    entry_count.* += 1;
                    continue;
                };
                try out.print(arena, "{s} ({d}b)\n", .{ entry.name, stat.size });
                entry_count.* += 1;
                if (opts.with_symbols) {
                    if (languageFor(entry.name)) |lang| {
                        try renderSymbols(arena, io, child_rel, depth + 1, out, lang);
                    }
                }
            },
            else => {
                try out.print(arena, "{s}\n", .{entry.name});
                entry_count.* += 1;
            },
        }
    }
}

const NamedEntry = struct {
    name: []const u8,
    kind: Io.File.Kind,

    fn lessThan(_: void, a: NamedEntry, b: NamedEntry) bool {
        // Directories first, then alpha within each kind.
        const a_dir = a.kind == .directory;
        const b_dir = b.kind == .directory;
        if (a_dir and !b_dir) return true;
        if (!a_dir and b_dir) return false;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

fn indent(arena: std.mem.Allocator, out: *std.ArrayList(u8), depth: u8) !void {
    var i: u8 = 0;
    while (i < depth) : (i += 1) {
        try out.appendSlice(arena, "  ");
    }
}

/// Compute a stable cache key from `git status --porcelain` output.
/// When the output changes (any edit, stage, or commit), the map is
/// invalidated. Returns `.{ .key, .ok }` — `ok=false` when git is
/// missing / not a repo, in which case the caller should fall back
/// to "always regenerate" (no cache).
pub fn statusKey(io: Io, gpa: std.mem.Allocator) ?u64 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    return std.hash.Wyhash.hash(0, result.stdout);
}

/// Cache file path. `cwd_key` is a base16-encoded hash of the
/// absolute CWD so distinct checkouts of the same repo don't share
/// state.
pub fn cachePath(
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cwd_key: []const u8,
) ![]const u8 {
    const base = if (env_map.get("XDG_CACHE_HOME")) |x| x else blk: {
        const home = env_map.get("HOME") orelse return Error.HomeDirUnknown;
        break :blk try std.fmt.allocPrint(arena, "{s}/.cache", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/repo-map/{s}.cache", .{ base, cwd_key });
}

/// Cache file format: 16 ASCII hex chars (the git-status hash) +
/// '\n' + the map body. Splitting by the first newline yields both.
fn parseCache(data: []const u8) ?struct { key: u64, body: []const u8 } {
    if (data.len < 17) return null;
    if (data[16] != '\n') return null;
    const k = std.fmt.parseInt(u64, data[0..16], 16) catch return null;
    return .{ .key = k, .body = data[17..] };
}

/// Generate or reuse the cached map for the current CWD. When git
/// is unavailable, regenerates every time (no caching). On any
/// cache write failure, falls through silently.
pub fn cachedOrGenerate(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cwd_key: []const u8,
) ![]const u8 {
    return cachedOrGenerateWithOptions(arena, io, gpa, env_map, cwd_key, .{});
}

pub fn cachedOrGenerateWithOptions(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cwd_key: []const u8,
    opts: Options,
) ![]const u8 {
    // Pick a cache path that varies with `with_symbols` so flipping
    // the flag mid-session doesn't return the wrong shape.
    const suffix: []const u8 = if (opts.with_symbols) "-sym" else "";
    const keyed_cwd = try std.fmt.allocPrint(arena, "{s}{s}", .{ cwd_key, suffix });
    const key_opt = statusKey(io, gpa);
    if (key_opt == null) return generateWithOptions(arena, io, opts);

    const key = key_opt.?;
    const path = cachePath(arena, env_map, keyed_cwd) catch return generateWithOptions(arena, io, opts);

    // Try cache hit.
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 * 1024 * 1024))) |data| {
        if (parseCache(data)) |c| {
            if (c.key == key) return c.body;
        }
    } else |_| {}

    const body = try generateWithOptions(arena, io, opts);
    writeCache(io, arena, path, key, body) catch {};
    return body;
}

fn writeCache(
    io: Io,
    arena: std.mem.Allocator,
    path: []const u8,
    key: u64,
    body: []const u8,
) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash > 0) try mkdirAllAbsolute(io, path[0..slash]);
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "{x:0>16}\n", .{key});
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

// ───────── symbol skeleton ─────────

/// Languages we know how to extract top-level decls from. Each maps
/// a regex-style line predicate to a "renderable" symbol shape.
const Language = enum {
    zig,
    rust,
    typescript,
    javascript,
    python,
    go,
};

fn languageFor(name: []const u8) ?Language {
    const ext = std.fs.path.extension(name);
    if (ext.len == 0) return null;
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".ts")) return .typescript;
    if (std.mem.eql(u8, ext, ".tsx")) return .typescript;
    if (std.mem.eql(u8, ext, ".js")) return .javascript;
    if (std.mem.eql(u8, ext, ".jsx")) return .javascript;
    if (std.mem.eql(u8, ext, ".mjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".py")) return .python;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    return null;
}

/// Read the top of `path` and append up to `max_symbols_per_file`
/// indented decl lines under the file's row in `out`. Each line is
/// trimmed (no trailing brace / semicolon / docstring fluff). On any
/// error we silently skip — repo-map degrades to layout-only for the
/// affected file rather than failing the whole render.
fn renderSymbols(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    depth: u8,
    out: *std.ArrayList(u8),
    lang: Language,
) !void {
    const body = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_symbol_scan_bytes)) catch return;
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        if (emitted >= max_symbols_per_file) {
            try indent(arena, out, depth);
            try out.appendSlice(arena, "… (more decls truncated)\n");
            return;
        }
        // Symbol detection runs on the line as written — we want to
        // catch top-level decls only, so leading whitespace excludes
        // the line by default. Two languages need exceptions:
        //   - Python uses indentation as syntax; top-level still has
        //     no indent, so the rule still works.
        //   - TS/JS sometimes have `export default function` after a
        //     `// comment` block; not handled — we accept the false
        //     negative.
        if (raw.len == 0) continue;
        if (raw[0] == ' ' or raw[0] == '\t') continue;
        if (matchTopLevelDecl(lang, raw)) |trimmed| {
            try indent(arena, out, depth);
            try out.print(arena, "· {s}\n", .{trimmed});
            emitted += 1;
        }
    }
}

/// Per-language test: does this line LOOK like a top-level decl?
/// Returns the canonicalised display string (signature only, no
/// trailing brace) when it does, null otherwise. Cheap prefix
/// matching only; no AST. Wrong on edge cases by design — the
/// model can read the file when it needs ground truth.
fn matchTopLevelDecl(lang: Language, line: []const u8) ?[]const u8 {
    return switch (lang) {
        .zig => matchZig(line),
        .rust => matchRust(line),
        .typescript, .javascript => matchTsJs(line),
        .python => matchPython(line),
        .go => matchGo(line),
    };
}

fn matchZig(line: []const u8) ?[]const u8 {
    // pub fn / fn / pub const / const / pub var / var / pub extern fn
    const prefixes = [_][]const u8{
        "pub fn ", "fn ", "pub const ", "const ", "pub var ", "var ", "pub extern ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return trimDeclTail(line);
    }
    return null;
}

fn matchRust(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "pub fn ",         "fn ",         "pub async fn ",   "async fn ",
        "pub struct ",     "struct ",     "pub enum ",       "enum ",
        "pub trait ",      "trait ",      "pub impl ",       "impl ",
        "pub const ",      "const ",      "pub static ",     "static ",
        "pub type ",       "type ",       "pub(crate) fn ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return trimDeclTail(line);
    }
    return null;
}

fn matchTsJs(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "export function ",   "export async function ", "function ",
        "export const ",      "const ",
        "export class ",      "class ",
        "export interface ",  "interface ",
        "export type ",       "type ",
        "export default function ", "export default class ",
        "export enum ",       "enum ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return trimDeclTail(line);
    }
    return null;
}

fn matchPython(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "def ", "async def ", "class ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return trimDeclTail(line);
    }
    return null;
}

fn matchGo(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "func ", "type ", "var ", "const ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return trimDeclTail(line);
    }
    return null;
}

/// Strip trailing `{`, `:`, or `;` from a decl line to get a clean
/// signature for display. Also caps at 160 chars — repo-map rows
/// are an overview, not a full reference.
fn trimDeclTail(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == '\r' or line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    while (end > 0 and (line[end - 1] == '{' or line[end - 1] == ':' or line[end - 1] == ';')) {
        end -= 1;
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    }
    if (end > 160) end = 160;
    return line[0..end];
}

// ───────── tests ─────────

const testing = std.testing;

test "languageFor: covers shipped extensions" {
    try testing.expectEqual(Language.zig, languageFor("foo.zig").?);
    try testing.expectEqual(Language.rust, languageFor("lib.rs").?);
    try testing.expectEqual(Language.typescript, languageFor("App.tsx").?);
    try testing.expectEqual(Language.javascript, languageFor("util.mjs").?);
    try testing.expectEqual(Language.python, languageFor("script.py").?);
    try testing.expectEqual(Language.go, languageFor("main.go").?);
    try testing.expect(languageFor("README.md") == null);
    try testing.expect(languageFor("noext") == null);
}

test "matchZig: catches pub fn / const / var" {
    try testing.expectEqualStrings("pub fn run() !void", matchZig("pub fn run() !void {").?);
    try testing.expectEqualStrings("const Foo = struct", matchZig("const Foo = struct {").?);
    try testing.expectEqualStrings("pub var counter: u32 = 0", matchZig("pub var counter: u32 = 0;").?);
    try testing.expect(matchZig("    fn nested() void {") == null); // indented = not top-level
    try testing.expect(matchZig("// comment") == null);
}

test "matchRust: pub fn / struct / impl / trait" {
    try testing.expectEqualStrings("pub fn helper() -> u32", matchRust("pub fn helper() -> u32 {").?);
    try testing.expectEqualStrings("pub struct Foo<T>", matchRust("pub struct Foo<T> {").?);
    try testing.expectEqualStrings("impl Display for Foo", matchRust("impl Display for Foo {").?);
    try testing.expectEqualStrings("pub trait Visitor", matchRust("pub trait Visitor {").?);
    try testing.expect(matchRust("// doc") == null);
}

test "matchTsJs: export function / class / interface" {
    try testing.expectEqualStrings("export function ping(): boolean", matchTsJs("export function ping(): boolean {").?);
    try testing.expectEqualStrings("export class Foo", matchTsJs("export class Foo {").?);
    try testing.expectEqualStrings("interface Bar", matchTsJs("interface Bar {").?);
    try testing.expect(matchTsJs("import x from 'y'") == null);
}

test "matchPython: def / class / async def" {
    try testing.expectEqualStrings("def hello(name)", matchPython("def hello(name):").?);
    try testing.expectEqualStrings("async def fetch(url)", matchPython("async def fetch(url):").?);
    try testing.expectEqualStrings("class Foo(Base)", matchPython("class Foo(Base):").?);
    try testing.expect(matchPython("    def nested(self): pass") == null);
}

test "matchGo: func / type / var / const" {
    try testing.expectEqualStrings("func Hello(name string) string", matchGo("func Hello(name string) string {").?);
    try testing.expectEqualStrings("type User struct", matchGo("type User struct {").?);
    try testing.expectEqualStrings("var Default = New()", matchGo("var Default = New()").?);
    try testing.expect(matchGo("// pkg doc") == null);
}

test "trimDeclTail: caps at 160 chars + strips trailing brace" {
    const long = "pub fn aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa() void {";
    const out = trimDeclTail(long);
    try testing.expect(out.len <= 160);
}

test "generateWithOptions: symbol mode includes top-level decls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Drop a tiny zig file in the testing tmp directory.
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "src/sample.zig",
        .data =
            \\const std = @import("std");
            \\
            \\pub fn run() !void {
            \\    return;
            \\}
            \\
            \\pub const Banner = "hello";
        ,
    });

    // Switch CWD into the tmp dir so the walker sees just our sample
    // (no need to fight with the host repo). Restore at end.
    var original_cwd_buf: [4096]u8 = undefined;
    const original_cwd_ptr = std.c.getcwd(&original_cwd_buf, original_cwd_buf.len);
    if (original_cwd_ptr == null) return error.TestFailed;
    const original_cwd_len = std.mem.indexOfScalar(u8, &original_cwd_buf, 0) orelse original_cwd_buf.len;
    const original_cwd = original_cwd_buf[0..original_cwd_len];
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const tmp_z = try a.dupeZ(u8, tmp_abs);
    const orig_z = try a.dupeZ(u8, original_cwd);
    if (std.c.chdir(tmp_z.ptr) != 0) return error.TestFailed;
    defer _ = std.c.chdir(orig_z.ptr);

    const out = try generateWithOptions(a, testing.io, .{ .with_symbols = true });
    try testing.expect(std.mem.indexOf(u8, out, "sample.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn run() !void") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const Banner") != null);
}

test "parseCache: round-trips key + body" {
    const sample = "deadbeefcafebabe\nhello world\n";
    const c = parseCache(sample) orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 0xdeadbeefcafebabe), c.key);
    try testing.expectEqualStrings("hello world\n", c.body);
}

test "parseCache: rejects too-short input" {
    try testing.expect(parseCache("short") == null);
}

test "parseCache: rejects missing newline at offset 16" {
    try testing.expect(parseCache("0123456789abcdefXbody") == null);
}
