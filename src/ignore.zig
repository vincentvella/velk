//! Lightweight ignore filter for `ls` / `grep`. V1 hard-codes the
//! common dependency / build / cache directories that bloat a
//! listing without telling the model anything useful. A real
//! `.gitignore` parser (with negations, globs, anchored patterns)
//! is a v2 lift — these names cover ~95% of the noise in a typical
//! repo.

const std = @import("std");

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
