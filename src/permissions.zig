//! Permission engine — decides whether a tool call should run, run
//! silently, or prompt the user via the approval gate. V1 is
//! mode-only; per-tool allow/deny rule lists and bash-subcommand
//! AST parsing are scoped for a v2.
//!
//! Modes:
//!   default     — prompt for edit/write_file (status quo)
//!   acceptEdits — auto-apply edit/write_file without prompting
//!   acceptAll   — auto-apply every tool with no prompts
//!   bypass      — same as acceptAll today (logging is a future hook)
//!   plan        — refuse every write-side tool; the agent stays
//!                 read-only (read_file / ls / grep still run)
//!
//! Dangerous-path guardrail: edits to `~/.ssh`, `~/.aws`, or any
//! `.env*` file always force a prompt regardless of mode. Implemented
//! as a check inside the tool, before consulting the gate.

const std = @import("std");

pub const Mode = enum {
    default,
    accept_edits,
    accept_all,
    bypass,
    plan,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "acceptEdits") or std.mem.eql(u8, s, "accept_edits")) return .accept_edits;
        if (std.mem.eql(u8, s, "acceptAll") or std.mem.eql(u8, s, "accept_all")) return .accept_all;
        if (std.mem.eql(u8, s, "bypass")) return .bypass;
        if (std.mem.eql(u8, s, "plan")) return .plan;
        return null;
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .default => "default",
            .accept_edits => "acceptEdits",
            .accept_all => "acceptAll",
            .bypass => "bypass",
            .plan => "plan",
        };
    }

    /// True when this mode should let the approval gate auto-apply
    /// every write request without prompting (modulo dangerous-path
    /// override).
    pub fn bypassesPrompts(self: Mode) bool {
        return switch (self) {
            .accept_edits, .accept_all, .bypass => true,
            .default, .plan => false,
        };
    }

    /// True when write-side tools (edit, write_file, bash) must
    /// refuse to run. Read-only tools (read_file, ls, grep) still
    /// execute.
    pub fn refusesWrites(self: Mode) bool {
        return self == .plan;
    }
};

/// True when `path` matches a hard-wired sensitive prefix:
/// home-relative `.ssh/`, `.aws/`, or any `.env`/`.env.<x>` file
/// at any depth. Matching is purely lexical; symlink shenanigans
/// aren't caught.
pub fn isDangerousPath(path: []const u8) bool {
    // Tail-segment check for .env and .env.<anything>.
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = (i == path.len);
        if (at_end or path[i] == '/') {
            const seg = path[segment_start..i];
            if (seg.len >= 4 and std.mem.eql(u8, seg[0..4], ".env")) {
                if (seg.len == 4 or seg[4] == '.') return true;
            }
            segment_start = i + 1;
        }
    }
    // Substring scan for sensitive directories.
    if (std.mem.indexOf(u8, path, ".ssh/") != null) return true;
    if (std.mem.indexOf(u8, path, ".aws/") != null) return true;
    if (std.mem.endsWith(u8, path, "/.ssh") or std.mem.eql(u8, path, ".ssh")) return true;
    if (std.mem.endsWith(u8, path, "/.aws") or std.mem.eql(u8, path, ".aws")) return true;
    return false;
}

// ───────── tests ─────────

const testing = std.testing;

test "Mode.fromString accepts the documented spellings" {
    try testing.expectEqual(Mode.default, Mode.fromString("default").?);
    try testing.expectEqual(Mode.accept_edits, Mode.fromString("acceptEdits").?);
    try testing.expectEqual(Mode.accept_edits, Mode.fromString("accept_edits").?);
    try testing.expectEqual(Mode.accept_all, Mode.fromString("acceptAll").?);
    try testing.expectEqual(Mode.bypass, Mode.fromString("bypass").?);
    try testing.expectEqual(Mode.plan, Mode.fromString("plan").?);
    try testing.expect(Mode.fromString("nonsense") == null);
}

test "Mode.bypassesPrompts: only the trust modes auto-apply" {
    try testing.expect(!Mode.default.bypassesPrompts());
    try testing.expect(Mode.accept_edits.bypassesPrompts());
    try testing.expect(Mode.accept_all.bypassesPrompts());
    try testing.expect(Mode.bypass.bypassesPrompts());
    try testing.expect(!Mode.plan.bypassesPrompts());
}

test "Mode.refusesWrites: only plan mode" {
    try testing.expect(Mode.plan.refusesWrites());
    try testing.expect(!Mode.default.refusesWrites());
    try testing.expect(!Mode.accept_all.refusesWrites());
}

test "isDangerousPath: ssh + aws directory hits" {
    try testing.expect(isDangerousPath(".ssh/id_rsa"));
    try testing.expect(isDangerousPath("/Users/v/.ssh/known_hosts"));
    try testing.expect(isDangerousPath(".aws/credentials"));
    try testing.expect(isDangerousPath("/home/v/.aws/config"));
}

test "isDangerousPath: .env tail-segment hits" {
    try testing.expect(isDangerousPath(".env"));
    try testing.expect(isDangerousPath("project/.env"));
    try testing.expect(isDangerousPath("project/.env.local"));
    try testing.expect(isDangerousPath("project/.env.production"));
}

test "isDangerousPath: false-positive guards" {
    try testing.expect(!isDangerousPath("README.md"));
    try testing.expect(!isDangerousPath("src/main.zig"));
    try testing.expect(!isDangerousPath("environment.txt"));
    try testing.expect(!isDangerousPath("env-vars.json"));
    try testing.expect(!isDangerousPath("ssh-keygen.md"));
    // ".env" appearing inside a non-tail segment is fine
    try testing.expect(!isDangerousPath(".envrc/legit-file"));
}
