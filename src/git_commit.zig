//! Optional auto-commit at the end of a turn. When the working
//! tree is dirty after a turn that touched files, run
//! `git add -A && git commit -m "velk: <message>"`. Best-effort:
//! all errors are swallowed so a missing `git` binary or a
//! pre-commit hook failure doesn't break the agent loop.
//!
//! Off by default — opt in via `--auto-commit` or
//! `auto_commit: true` in settings.json.

const std = @import("std");
const Io = std.Io;

/// Run `git status --porcelain`; return true when the output is
/// non-empty (working tree dirty). Anything that goes wrong (no
/// git in PATH, not in a repo, exit nonzero) returns false so
/// callers can short-circuit.
pub fn isDirty(io: Io, gpa: std.mem.Allocator) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) return false,
        else => return false,
    }
    return result.stdout.len > 0;
}

/// Run `git add -A && git commit -m message`. Returns true on
/// success. Suppresses output (we don't want commit chatter in
/// the TUI). Hooks are NOT skipped — if a project's pre-commit
/// fails the auto-commit fails too, and the user can re-run.
pub fn commitAll(io: Io, message: []const u8) bool {
    var add = std.process.spawn(io, .{
        .argv = &.{ "git", "add", "-A" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const add_term = add.wait(io) catch return false;
    switch (add_term) {
        .exited => |c| if (c != 0) return false,
        else => return false,
    }

    var commit = std.process.spawn(io, .{
        .argv = &.{ "git", "commit", "-m", message },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const commit_term = commit.wait(io) catch return false;
    switch (commit_term) {
        .exited => |c| if (c != 0) return false,
        else => return false,
    }
    return true;
}

/// Convenience: only commits if the tree is dirty. Returns the
/// outcome so the caller can surface a notice.
pub const CommitOutcome = enum { committed, clean, failed };

pub fn maybeCommit(io: Io, gpa: std.mem.Allocator, message: []const u8) CommitOutcome {
    if (!isDirty(io, gpa)) return .clean;
    if (commitAll(io, message)) return .committed;
    return .failed;
}
