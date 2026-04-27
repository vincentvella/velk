//! Workspace + project-context discovery: detect a git repo root
//! by walking up from CWD, and surface any AGENTS.md / VELK.md /
//! CLAUDE.md found in CWD or at the root.
//!
//! Auto-loaded files are prepended to the system prompt so the
//! model picks up project conventions (build commands, gotchas,
//! style) on every launch without the user pasting them.

const std = @import("std");
const Io = std.Io;

/// Filenames we consider "project context" — first match wins, in
/// the order listed. AGENTS.md is the open standard; VELK.md is the
/// project-specific name; CLAUDE.md is widely used by Claude Code
/// users and worth picking up too.
pub const context_filenames = [_][]const u8{
    "AGENTS.md",
    "VELK.md",
    "CLAUDE.md",
};

/// Maximum bytes we'll read from any single context file. Caps the
/// system-prompt size if someone drops a 1MB file in by accident.
pub const max_context_bytes: usize = 32 * 1024;

/// Read CWD via libc (we already link libc for SIGINT / kill /
/// kqueue). Returned slice lives in `arena`.
fn cwdAlloc(arena: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) return error.GetCwdFailed;
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    return try arena.dupe(u8, buf[0..len]);
}

/// Walk up from CWD looking for a `.git` directory; return the
/// containing path. Null when CWD isn't inside a git repo.
/// Walks at most `max_levels` parents so a runaway loop is
/// impossible on weird filesystems.
pub fn findRepoRoot(
    arena: std.mem.Allocator,
    io: Io,
) !?[]const u8 {
    const max_levels: u8 = 16;
    const cwd = try cwdAlloc(arena);
    var current: []const u8 = cwd;
    var levels: u8 = 0;
    while (levels < max_levels) : (levels += 1) {
        const candidate = try std.fmt.allocPrint(arena, "{s}/.git", .{current});
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => null,
            else => return e,
        };
        if (stat != null) return current;
        // Walk one level up.
        const slash = std.mem.lastIndexOfScalar(u8, current, '/') orelse return null;
        if (slash == 0) return null; // hit filesystem root
        current = current[0..slash];
    }
    return null;
}

pub const Loaded = struct {
    /// Absolute path the bytes came from.
    path: []const u8,
    /// File contents (truncated to `max_context_bytes`).
    contents: []const u8,
};

/// Look for the first AGENTS.md / VELK.md / CLAUDE.md in CWD and
/// (if different) repo root. Returns null when nothing matches.
/// Repo root is searched second so a CWD-level file overrides.
pub fn findContextFile(
    arena: std.mem.Allocator,
    io: Io,
    repo_root: ?[]const u8,
) !?Loaded {
    const cwd = try cwdAlloc(arena);
    const candidate_dirs = if (repo_root) |root|
        if (!std.mem.eql(u8, root, cwd))
            &[_][]const u8{ cwd, root }
        else
            &[_][]const u8{cwd}
    else
        &[_][]const u8{cwd};

    for (candidate_dirs) |dir| {
        for (context_filenames) |fname| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, fname });
            const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_context_bytes)) catch |e| switch (e) {
                error.FileNotFound, error.IsDir => continue,
                else => return e,
            };
            return .{ .path = path, .contents = data };
        }
    }
    return null;
}

/// Prepend `context` to `existing` system prompt. Use a labelled
/// fence so the model can distinguish project-loaded context from
/// user-supplied system instructions. When `existing` is null /
/// empty the result is just the wrapped context.
pub fn buildSystemPrompt(
    arena: std.mem.Allocator,
    existing: ?[]const u8,
    context: []const u8,
    source_path: []const u8,
) ![]const u8 {
    const has_existing = existing != null and existing.?.len > 0;
    if (has_existing) {
        return std.fmt.allocPrint(
            arena,
            "<project-context source=\"{s}\">\n{s}\n</project-context>\n\n{s}",
            .{ source_path, context, existing.? },
        );
    }
    return std.fmt.allocPrint(
        arena,
        "<project-context source=\"{s}\">\n{s}\n</project-context>",
        .{ source_path, context },
    );
}

// ───────── tests ─────────

const testing = std.testing;

test "buildSystemPrompt: with existing user system" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try buildSystemPrompt(arena.allocator(), "be terse.", "build: zig build", "AGENTS.md");
    try testing.expect(std.mem.indexOf(u8, out, "be terse.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "build: zig build") != null);
    try testing.expect(std.mem.indexOf(u8, out, "AGENTS.md") != null);
    try testing.expect(std.mem.startsWith(u8, out, "<project-context"));
}

test "buildSystemPrompt: without existing user system" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try buildSystemPrompt(arena.allocator(), null, "X", "X.md");
    try testing.expect(std.mem.endsWith(u8, out, "</project-context>"));
}

test "buildSystemPrompt: empty existing treated as null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try buildSystemPrompt(arena.allocator(), "", "X", "X.md");
    const b = try buildSystemPrompt(arena.allocator(), null, "X", "X.md");
    try testing.expectEqualStrings(a, b);
}
