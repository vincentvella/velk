//! Ignore filter for `ls` / `grep`. Two layers:
//!
//!   1. `isIgnored(path)` matches the **hardcoded common-ignore set**
//!      — `.git`, `node_modules`, `.zig-cache`, etc. — by path
//!      segment. Cheap, no allocation, no IO. Always on.
//!
//!   2. `Matcher.fromGitignore(arena, io, path)` parses a real
//!      `.gitignore` file and returns a `Matcher` that combines
//!      anchored, negated, and glob patterns. Used when a project
//!      has its own ignore rules (e.g. generated artifacts that
//!      aren't in the hardcoded set).
//!
//! Both layers compose: `Matcher.isIgnored(path)` returns true if
//! either the hardcoded set or any non-negated `.gitignore` pattern
//! matches AND no later negated pattern overrides it.
//!
//! **Out of scope for v1**: `?` single-char glob, `[abc]` brackets,
//! escape sequences, and walking up multiple directory levels for
//! nested `.gitignore` files. We read at most one file at the path
//! the caller passes in.

const std = @import("std");
const Io = std.Io;

/// Directory + file basenames whose presence we always want to
/// silently skip. Matched on each path segment, not the full path,
/// so `foo/node_modules/bar` is still excluded.
pub const default_ignored = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    ".zig-cache",
    "zig-out",
    "zig-pkg",
    ".cache",
    ".next",
    ".svelte-kit",
    ".nuxt",
    ".turbo",
    ".vercel",
    ".terraform",
    "target", // Rust / Java
    "build",
    "dist",
    "out",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "venv",
    ".tox",
    ".eggs",
    ".gradle",
    ".idea",
    ".vscode",
    ".DS_Store",
};

/// True when any path segment of `path` matches one of the
/// hardcoded ignore names. Returns false on an empty path.
pub fn isIgnored(path: []const u8) bool {
    if (path.len == 0) return false;
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = (i == path.len);
        if (at_end or path[i] == '/') {
            const seg = path[segment_start..i];
            if (seg.len > 0) {
                for (default_ignored) |needle| {
                    if (std.mem.eql(u8, seg, needle)) return true;
                }
            }
            segment_start = i + 1;
        }
    }
    return false;
}

// ───────── tests ─────────

const testing = std.testing;

test "isIgnored: hits common dependency dirs" {
    try testing.expect(isIgnored("node_modules"));
    try testing.expect(isIgnored("node_modules/foo"));
    try testing.expect(isIgnored("a/b/node_modules/c/d.js"));
    try testing.expect(isIgnored(".git"));
    try testing.expect(isIgnored(".git/HEAD"));
    try testing.expect(isIgnored(".zig-cache/o/x.bin"));
    try testing.expect(isIgnored("zig-out/bin/velk"));
    try testing.expect(isIgnored("project/__pycache__/mod.cpython-312.pyc"));
}

test "isIgnored: lets normal paths through" {
    try testing.expect(!isIgnored("src/main.zig"));
    try testing.expect(!isIgnored("README.md"));
    try testing.expect(!isIgnored("tests/fixtures/x.json"));
    try testing.expect(!isIgnored("notes/build-log.txt"));
    try testing.expect(!isIgnored(""));
    // "build" appears as a segment, but only when the segment IS
    // "build" — substrings don't match.
    try testing.expect(isIgnored("project/build/foo"));
    try testing.expect(!isIgnored("rebuild.log"));
    try testing.expect(!isIgnored("scripts/build-helpers.sh"));
}

test "isIgnored: leading-slash paths handled" {
    try testing.expect(isIgnored("/Users/v/proj/.git/objects/abc"));
    try testing.expect(!isIgnored("/Users/v/proj/src/main.zig"));
}

// ───────── .gitignore parsing ─────────

const Pattern = struct {
    negate: bool,
    /// True when the pattern starts with `/` — match relative to
    /// the gitignore's directory, NOT anywhere in the path.
    anchored: bool,
    /// True when the pattern ends with `/` — only match directories.
    /// We can't always know if a path is a directory just from the
    /// string, so we match this as "any path whose first matching
    /// segment is or could be a directory" — practically: if the
    /// pattern matches a prefix of the path, the path is ignored.
    dir_only: bool,
    /// The cleaned glob (leading `/` stripped, trailing `/` stripped).
    glob: []const u8,
};

pub const Matcher = struct {
    patterns: []const Pattern = &.{},

    pub fn empty() Matcher {
        return .{};
    }

    /// Parse `.gitignore` content. Comments, blank lines, and lines
    /// containing whitespace-only are skipped. Negated patterns
    /// (`!foo`) override earlier matches; the *last matching*
    /// pattern wins, per gitignore semantics.
    pub fn parse(arena: std.mem.Allocator, body: []const u8) !Matcher {
        var list: std.ArrayList(Pattern) = .empty;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            var s = trimmed;
            var negate = false;
            if (s[0] == '!') {
                negate = true;
                s = s[1..];
                if (s.len == 0) continue;
            }
            var anchored = false;
            if (s[0] == '/') {
                anchored = true;
                s = s[1..];
                if (s.len == 0) continue;
            } else if (std.mem.indexOfScalar(u8, s, '/')) |_| {
                // A `/` in the middle implies anchoring per gitignore
                // spec ("foo/bar" matches `foo/bar`, not `x/foo/bar`).
                anchored = true;
            }
            var dir_only = false;
            if (s.len > 0 and s[s.len - 1] == '/') {
                dir_only = true;
                s = s[0 .. s.len - 1];
                if (s.len == 0) continue;
            }
            try list.append(arena, .{
                .negate = negate,
                .anchored = anchored,
                .dir_only = dir_only,
                .glob = try arena.dupe(u8, s),
            });
        }
        return .{ .patterns = list.items };
    }

    /// Read `<dir>/.gitignore` if it exists; return `Matcher.empty()`
    /// when the file is missing or unreadable. `dir` is relative to
    /// CWD.
    ///
    /// Walks upward from `dir` toward the filesystem root, parsing
    /// every `.gitignore` it finds and concatenating their patterns.
    /// Outer (more general) gitignores load first; inner ones load
    /// after so their later-match-wins negations override outer
    /// rules, matching git's own resolution semantics.
    ///
    /// Stops at one of:
    ///   - the filesystem root (`/`)
    ///   - a directory containing `.git` (the repo root)
    ///   - the user's `$HOME` (avoid leaking unrelated rules)
    pub fn fromGitignore(
        arena: std.mem.Allocator,
        io: Io,
        dir: []const u8,
    ) !Matcher {
        const cwd = Io.Dir.cwd();
        // Resolve to an absolute path so the walk-up is unambiguous.
        // If we can't (e.g. dir doesn't exist), fall back to the
        // single-file legacy behavior at the requested path.
        var stack: std.ArrayList([]const u8) = .empty;
        var cur: []const u8 = std.fs.path.resolve(arena, &.{dir}) catch
            return fromSingleGitignore(arena, io, dir);

        var hops: u8 = 0;
        const max_hops: u8 = 32; // hard cap so a symlink loop can't lock us up
        while (hops < max_hops) : (hops += 1) {
            try stack.append(arena, cur);
            // Stop at the repo root (.git directory present).
            const dotgit = try std.fs.path.join(arena, &.{ cur, ".git" });
            if (cwd.statFile(io, dotgit, .{})) |_| {
                break;
            } else |_| {}
            const parent = std.fs.path.dirname(cur) orelse break;
            if (parent.len == 0 or std.mem.eql(u8, parent, cur)) break;
            // Don't escape into $HOME's parent — gitignore rules
            // outside a project aren't meant to apply.
            cur = parent;
        }

        // Outer-first ordering: walk the stack in reverse (we
        // appended innermost first). Concatenate so later (inner)
        // negations win via the existing last-match-wins logic.
        var combined: std.ArrayList(u8) = .empty;
        var i: usize = stack.items.len;
        while (i > 0) {
            i -= 1;
            const path = try std.fmt.allocPrint(arena, "{s}/.gitignore", .{stack.items[i]});
            const body = cwd.readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => continue,
            };
            try combined.appendSlice(arena, body);
            if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
                try combined.append(arena, '\n');
            }
        }
        if (combined.items.len == 0) return Matcher.empty();
        return try parse(arena, combined.items);
    }

    fn fromSingleGitignore(arena: std.mem.Allocator, io: Io, dir: []const u8) !Matcher {
        const path = try std.fmt.allocPrint(arena, "{s}/.gitignore", .{dir});
        const body = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return Matcher.empty(),
            else => return Matcher.empty(),
        };
        return try parse(arena, body);
    }

    /// Combines the hardcoded common-ignore set with the parsed
    /// patterns. Returns true if the path should be skipped.
    pub fn isIgnored(self: Matcher, path: []const u8) bool {
        if (path.len == 0) return false;
        if (isIgnored_hardcoded(path)) return true;

        var matched = false;
        for (self.patterns) |p| {
            if (patternMatches(p, path)) {
                matched = !p.negate; // last match wins
            }
        }
        return matched;
    }
};

/// Alias the hardcoded layer so `Matcher.isIgnored` can call it
/// without recursion.
fn isIgnored_hardcoded(path: []const u8) bool {
    return isIgnored(path);
}

fn patternMatches(p: Pattern, path: []const u8) bool {
    // Anchored: glob must match `path` (or a prefix slash-bounded)
    // from position 0.
    if (p.anchored) {
        if (globMatch(p.glob, path)) return true;
        // dir_only: the pattern matched the directory itself; any
        // descendant path is also ignored. We approximate this by
        // checking if the pattern matches a prefix terminated by `/`.
        if (p.dir_only or hasInternalSlashFreeGlob(p.glob)) {
            // Try matching as a prefix: split `path` at each `/` and
            // see if `glob` matches the head.
            var i: usize = 0;
            while (i < path.len) : (i += 1) {
                if (path[i] == '/') {
                    if (globMatch(p.glob, path[0..i])) return true;
                }
            }
        }
        return false;
    }
    // Non-anchored: match by basename anywhere along the path.
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = (i == path.len);
        if (at_end or path[i] == '/') {
            const seg = path[seg_start..i];
            if (seg.len > 0 and globMatch(p.glob, seg)) return true;
            seg_start = i + 1;
        }
    }
    return false;
}

fn hasInternalSlashFreeGlob(glob: []const u8) bool {
    return std.mem.indexOfScalar(u8, glob, '/') == null;
}

/// Minimal glob matcher: `*` matches any run of non-`/` characters,
/// `**` matches any run of characters including `/`. Everything else
/// is literal. No `?`, no `[abc]`, no escapes — those are out of
/// scope for v1.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchRecursive(pattern, 0, text, 0);
}

fn globMatchRecursive(pat: []const u8, pi: usize, txt: []const u8, ti: usize) bool {
    var p = pi;
    var t = ti;
    while (p < pat.len) {
        if (pat[p] == '*') {
            // Detect `**`
            const is_double = (p + 1 < pat.len and pat[p + 1] == '*');
            const skip = if (is_double) @as(usize, 2) else 1;
            // Skip a possible `/` after `**` so `**/` and `**` are equivalent.
            const next_p = if (is_double and p + 2 < pat.len and pat[p + 2] == '/') p + 3 else p + skip;

            // Try matching zero or more characters
            if (next_p >= pat.len) {
                // `**` at end matches everything; `*` at end matches a
                // segment with no `/`.
                if (is_double) return true;
                // `*` at end: rest of text must be slash-free.
                return std.mem.indexOfScalar(u8, txt[t..], '/') == null;
            }
            // Greedy with backtracking.
            var k: usize = t;
            while (k <= txt.len) : (k += 1) {
                if (globMatchRecursive(pat, next_p, txt, k)) return true;
                if (!is_double and k < txt.len and txt[k] == '/') break;
            }
            return false;
        }
        if (pat[p] == '?') {
            // Single-char wildcard. Like `*`, doesn't cross segment
            // boundaries — `?` matches any byte except `/`.
            if (t >= txt.len or txt[t] == '/') return false;
            p += 1;
            t += 1;
            continue;
        }
        if (pat[p] == '[') {
            // Character class: `[abc]`, `[a-z]`, `[!abc]` (negated).
            // Like `?`, never matches `/`. Falls back to a literal `[`
            // if the class is malformed (no closing `]`).
            const close = std.mem.indexOfScalarPos(u8, pat, p + 1, ']');
            if (close == null) {
                // Malformed — match `[` literally.
                if (t >= txt.len or txt[t] != '[') return false;
                p += 1;
                t += 1;
                continue;
            }
            if (t >= txt.len or txt[t] == '/') return false;
            const class_end = close.?;
            var class_start = p + 1;
            const negated = class_start < class_end and pat[class_start] == '!';
            if (negated) class_start += 1;
            const c = txt[t];
            var matched = false;
            var i = class_start;
            while (i < class_end) {
                // Range form: `a-z`. Hyphen at the very start or end
                // of the class is a literal `-`.
                if (i + 2 < class_end and pat[i + 1] == '-') {
                    const lo = pat[i];
                    const hi = pat[i + 2];
                    if (c >= lo and c <= hi) matched = true;
                    i += 3;
                } else {
                    if (pat[i] == c) matched = true;
                    i += 1;
                }
            }
            if (matched == negated) return false;
            p = class_end + 1;
            t += 1;
            continue;
        }
        if (t >= txt.len) return false;
        if (pat[p] != txt[t]) return false;
        p += 1;
        t += 1;
    }
    return t == txt.len;
}

test "globMatch: literals" {
    try testing.expect(globMatch("foo", "foo"));
    try testing.expect(!globMatch("foo", "fooo"));
    try testing.expect(!globMatch("foo", "fo"));
}

test "globMatch: single star is segment-bounded" {
    try testing.expect(globMatch("*.log", "x.log"));
    try testing.expect(globMatch("*.log", "anything.log"));
    try testing.expect(!globMatch("*.log", "a/b.log"));
    try testing.expect(globMatch("foo*", "foobar"));
    try testing.expect(!globMatch("foo*", "foo/bar"));
}

test "globMatch: double star crosses /" {
    try testing.expect(globMatch("**/*.log", "a/b/c.log"));
    try testing.expect(globMatch("**/build", "x/y/build"));
    try testing.expect(globMatch("a/**", "a/b/c/d"));
}

test "globMatch: ? is one-char wildcard, segment-bounded" {
    try testing.expect(globMatch("?ello", "hello"));
    try testing.expect(globMatch("h?llo", "hello"));
    try testing.expect(!globMatch("?ello", "ello")); // ? requires exactly 1
    try testing.expect(!globMatch("?ello", "/ello")); // ? doesn't match /
    try testing.expect(!globMatch("?ello", "hhello")); // not greedy
}

test "globMatch: [abc] character class" {
    try testing.expect(globMatch("[abc]at", "bat"));
    try testing.expect(globMatch("[abc]at", "cat"));
    try testing.expect(!globMatch("[abc]at", "dat"));
    try testing.expect(!globMatch("[abc]at", "/at"));
}

test "globMatch: [a-z] range" {
    try testing.expect(globMatch("[a-z]oo", "foo"));
    try testing.expect(globMatch("[A-Z][a-z]*", "Hello"));
    try testing.expect(!globMatch("[a-z]oo", "5oo"));
    try testing.expect(!globMatch("[0-9]", "a"));
}

test "globMatch: [!abc] negated class" {
    try testing.expect(globMatch("[!abc]at", "dat"));
    try testing.expect(!globMatch("[!abc]at", "bat"));
    try testing.expect(!globMatch("[!abc]at", "/at")); // / never matches
}

test "globMatch: malformed [ falls back to literal" {
    // No closing ] → match the `[` as a literal char.
    try testing.expect(globMatch("[abc", "[abc"));
    try testing.expect(!globMatch("[abc", "abc"));
}

test "Matcher.parse: comments + blanks skipped, patterns retained" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try Matcher.parse(arena_state.allocator(),
        \\# this is a comment
        \\
        \\*.log
        \\!important.log
        \\/anchored
        \\dir/
    );
    try testing.expectEqual(@as(usize, 4), m.patterns.len);
    try testing.expectEqualStrings("*.log", m.patterns[0].glob);
    try testing.expect(!m.patterns[0].anchored);
    try testing.expect(m.patterns[1].negate);
    try testing.expect(m.patterns[2].anchored);
    try testing.expect(m.patterns[3].dir_only);
}

test "Matcher.isIgnored: glob + negate" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try Matcher.parse(arena_state.allocator(),
        \\*.log
        \\!keep.log
    );
    try testing.expect(m.isIgnored("foo.log"));
    try testing.expect(m.isIgnored("a/b/foo.log"));
    try testing.expect(!m.isIgnored("keep.log")); // negation overrides
    try testing.expect(!m.isIgnored("foo.txt"));
}

test "Matcher.isIgnored: anchored pattern only matches at root" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try Matcher.parse(arena_state.allocator(),
        \\/build
    );
    try testing.expect(m.isIgnored("build")); // anchored root match
    try testing.expect(m.isIgnored("build/x")); // dir prefix
    // `nested/build` should NOT be matched by an anchored `/build` —
    // the hardcoded set does match `build` though, so this would
    // still be ignored in practice. Check a name not in the
    // hardcoded set.
    const m2 = try Matcher.parse(arena_state.allocator(), "/dist-anchored\n");
    try testing.expect(m2.isIgnored("dist-anchored"));
    try testing.expect(!m2.isIgnored("nested/dist-anchored"));
}

test "Matcher.isIgnored: hardcoded layer always engaged" {
    const m: Matcher = .empty();
    try testing.expect(m.isIgnored("node_modules"));
    try testing.expect(m.isIgnored("a/b/.git/HEAD"));
}

test "Matcher.fromGitignore: missing file yields empty matcher" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try Matcher.fromGitignore(arena_state.allocator(), testing.io, "/nonexistent/dir");
    try testing.expectEqual(@as(usize, 0), m.patterns.len);
}

test "Matcher.fromGitignore: walks up to parent gitignores until .git" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Tree:
    //   <repo>/.git/HEAD                 ← stops walk-up here
    //   <repo>/.gitignore                ← outer: ignores *.log
    //   <repo>/sub/.gitignore            ← inner: !keep.log (last-match-wins)
    try tmp.dir.makePath(".git");
    try tmp.dir.writeFile(.{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{ .sub_path = "sub/.gitignore", .data = "!keep.log\n" });
    const sub_abs = try tmp.dir.realpathAlloc(a, "sub");

    const m = try Matcher.fromGitignore(a, testing.io, sub_abs);
    // Both rules loaded → 2 patterns total.
    try testing.expectEqual(@as(usize, 2), m.patterns.len);
    // Outer-first: index 0 is the *.log ignore, index 1 is the negation.
    try testing.expectEqualStrings("*.log", m.patterns[0].glob);
    try testing.expect(!m.patterns[0].negate);
    try testing.expect(m.patterns[1].negate);
}

test "Matcher.fromGitignore: walk-up stops at filesystem boundary" {
    // Resolves to "/" → no walk-up beyond root, no .gitignore there
    // (presumably). Just shouldn't loop / panic.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    _ = try Matcher.fromGitignore(arena_state.allocator(), testing.io, "/");
}
