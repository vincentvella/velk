//! Skills (v1, catalog-only). A skill is a directory containing a
//! `SKILL.md` whose YAML frontmatter declares `name` + `description`.
//! The body is the skill's instructions — kept on disk; the model
//! reads it via `read_file` when it decides the skill applies.
//!
//! Discovery roots, in priority order (later wins on name collisions):
//!
//!   1. `~/.claude/skills/<name>/SKILL.md`           (Claude Code shape)
//!   2. `$XDG_CONFIG_HOME/velk/skills/<name>/SKILL.md`
//!   3. `.claude/skills/<name>/SKILL.md`             (project, Claude shape)
//!   4. `.velk/skills/<name>/SKILL.md`               (project, velk shape)
//!
//! `loadAll` returns a slice of `Skill` records; `formatCatalog`
//! renders them as a `<skills>...</skills>` block ready to prepend
//! onto the system prompt so the model knows the catalog exists.
//!
//! **Out of scope for v1**: `tools` filter, `argument-names`
//! substitution, plugin/policy scopes, hot-reload. The frontmatter
//! parser only honours `name` + `description`; everything else is
//! ignored without error.

const std = @import("std");
const Io = std.Io;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// Path to `SKILL.md`. Surfaced in the catalog so the model can
    /// `read_file` it without guessing.
    path: []const u8,
};

pub const Source = enum { user_claude, user_velk, project_claude, project_velk };

const max_frontmatter_bytes: usize = 8 * 1024;
const max_body_bytes: usize = 256 * 1024;

/// Walk every discovery root that exists; return all skills found.
/// Project skills override user skills with the same `name`.
pub fn loadAll(
    arena: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
) ![]const Skill {
    var by_name: std.StringHashMap(Skill) = .init(arena);
    defer by_name.deinit();

    // User scopes first (lowest priority).
    if (try userClaudeRoot(arena, env_map)) |root| try loadFrom(arena, io, root, &by_name);
    if (try userVelkRoot(arena, env_map)) |root| try loadFrom(arena, io, root, &by_name);

    // Project scopes (highest priority).
    try loadFrom(arena, io, ".claude/skills", &by_name);
    try loadFrom(arena, io, ".velk/skills", &by_name);

    var out: std.ArrayList(Skill) = .empty;
    var it = by_name.iterator();
    while (it.next()) |kv| try out.append(arena, kv.value_ptr.*);
    return out.items;
}

/// Render the catalog as a `<skills>` block, suitable for prepending
/// onto the system prompt. Returns an empty slice when no skills.
pub fn formatCatalog(arena: std.mem.Allocator, skills: []const Skill) ![]const u8 {
    if (skills.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "<skills>\n");
    try buf.appendSlice(arena, "Skills available in this workspace. Each skill lives at the path shown; read it via the `read_file` tool when you decide to apply it.\n\n");
    for (skills) |s| {
        try buf.print(arena, "- **{s}** — {s}\n  path: {s}\n", .{ s.name, s.description, s.path });
    }
    try buf.appendSlice(arena, "</skills>\n");
    return buf.items;
}

fn userClaudeRoot(arena: std.mem.Allocator, env_map: *std.process.Environ.Map) !?[]const u8 {
    const home = env_map.get("HOME") orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/.claude/skills", .{home});
}

fn userVelkRoot(arena: std.mem.Allocator, env_map: *std.process.Environ.Map) !?[]const u8 {
    const base = env_map.get("XDG_CONFIG_HOME") orelse blk: {
        const home = env_map.get("HOME") orelse return null;
        break :blk try std.fmt.allocPrint(arena, "{s}/.config", .{home});
    };
    return try std.fmt.allocPrint(arena, "{s}/velk/skills", .{base});
}

fn loadFrom(
    arena: std.mem.Allocator,
    io: Io,
    root_path: []const u8,
    out: *std.StringHashMap(Skill),
) !void {
    var dir = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => return,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const skill_md = try std.fmt.allocPrint(arena, "{s}/{s}/SKILL.md", .{ root_path, entry.name });
        const body = Io.Dir.cwd().readFileAlloc(io, skill_md, arena, .limited(max_body_bytes)) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => continue,
        };
        const fm = parseFrontmatter(body) orelse continue;
        const name_owned = try arena.dupe(u8, fm.name);
        const desc_owned = try arena.dupe(u8, fm.description);
        try out.put(name_owned, .{
            .name = name_owned,
            .description = desc_owned,
            .path = skill_md,
        });
    }
}

const Frontmatter = struct {
    name: []const u8,
    description: []const u8,
};

/// Parse the `---`-delimited YAML header at the start of `body`.
/// Recognises `name:` and `description:` keys; ignores everything
/// else. Returns null when the frontmatter is missing either key
/// or malformed.
pub fn parseFrontmatter(body: []const u8) ?Frontmatter {
    if (!std.mem.startsWith(u8, body, "---")) return null;
    const after_open = body[3..];
    const header_start = std.mem.indexOfScalar(u8, after_open, '\n') orelse return null;
    const block_start: usize = 3 + header_start + 1;
    if (block_start > body.len) return null;
    const close_rel = std.mem.indexOf(u8, body[block_start..], "\n---") orelse return null;
    const block = body[block_start .. block_start + close_rel];
    if (block.len > max_frontmatter_bytes) return null;

    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (parseKeyValue(line, "name")) |v| name = v;
        if (parseKeyValue(line, "description")) |v| desc = v;
    }
    if (name == null or desc == null) return null;
    return .{ .name = name.?, .description = desc.? };
}

fn parseKeyValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len) return null;
    const after = line[key.len..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) i += 1;
    if (i >= after.len or after[i] != ':') return null;
    i += 1;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) i += 1;
    var value = after[i..];
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = value[1 .. value.len - 1];
    }
    return std.mem.trim(u8, value, " \t\r");
}

// ───────── tests ─────────

const testing = std.testing;

test "parseFrontmatter: name + description" {
    const body =
        \\---
        \\name: my-skill
        \\description: When to apply
        \\---
        \\
        \\body here
    ;
    const fm = parseFrontmatter(body).?;
    try testing.expectEqualStrings("my-skill", fm.name);
    try testing.expectEqualStrings("When to apply", fm.description);
}

test "parseFrontmatter: ignores unknown keys" {
    const body =
        \\---
        \\name: x
        \\description: y
        \\tools:
        \\  - read_file
        \\argument-names:
        \\  - path
        \\---
        \\body
    ;
    const fm = parseFrontmatter(body).?;
    try testing.expectEqualStrings("x", fm.name);
}

test "parseFrontmatter: rejects missing description" {
    const body =
        \\---
        \\name: x
        \\---
        \\body
    ;
    try testing.expect(parseFrontmatter(body) == null);
}

test "parseFrontmatter: rejects body without --- header" {
    const body = "name: x\ndescription: y\n";
    try testing.expect(parseFrontmatter(body) == null);
}

test "parseFrontmatter: handles quoted values" {
    const body =
        \\---
        \\name: "quoted name"
        \\description: 'single-quoted desc'
        \\---
        \\
    ;
    const fm = parseFrontmatter(body).?;
    try testing.expectEqualStrings("quoted name", fm.name);
    try testing.expectEqualStrings("single-quoted desc", fm.description);
}

test "formatCatalog: empty list yields empty string" {
    const out = try formatCatalog(testing.allocator, &.{});
    try testing.expectEqualStrings("", out);
}

test "formatCatalog: includes name, description, path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const skills = [_]Skill{
        .{ .name = "a", .description = "first skill", .path = ".velk/skills/a/SKILL.md" },
        .{ .name = "b", .description = "second", .path = ".velk/skills/b/SKILL.md" },
    };
    const out = try formatCatalog(arena_state.allocator(), &skills);
    try testing.expect(std.mem.indexOf(u8, out, "<skills>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "**a**") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first skill") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".velk/skills/a/SKILL.md") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</skills>") != null);
}
