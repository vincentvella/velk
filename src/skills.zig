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
    /// Optional tool allowlist declared in the YAML frontmatter as
    /// `tools: [bash, edit]` (inline) or `tools: bash, edit`. Empty
    /// when unset — the catalog then advertises the skill as
    /// using all tools. v1 is honor-system: the catalog surfaces
    /// the constraint to the model; runtime enforcement of the
    /// allowlist when the model is acting under a skill is a
    /// follow-up (would need an "active skill" runtime concept).
    tools: []const []const u8 = &.{},
    /// Optional output-style hint declared as `style: concise` in
    /// the frontmatter. Surfaced in the catalog so the model knows
    /// the author's preferred output shape when applying the skill.
    /// Same honor-system caveat as `tools` — runtime auto-switch is
    /// out of scope for catalog-only skills.
    style: ?[]const u8 = null,
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
        if (s.tools.len > 0) {
            try buf.appendSlice(arena, "  allowed tools (when applying this skill): ");
            for (s.tools, 0..) |t, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try buf.appendSlice(arena, t);
            }
            try buf.append(arena, '\n');
        }
        if (s.style) |st| {
            try buf.print(arena, "  recommended output style: {s}\n", .{st});
        }
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
        const fm = parseFrontmatterAlloc(arena, body) orelse continue;
        const name_owned = try arena.dupe(u8, fm.name);
        const desc_owned = try arena.dupe(u8, fm.description);
        try out.put(name_owned, .{
            .name = name_owned,
            .description = desc_owned,
            .path = skill_md,
            .tools = fm.tools,
            .style = fm.style,
        });
    }
}

const Frontmatter = struct {
    name: []const u8,
    description: []const u8,
    tools: []const []const u8 = &.{},
    style: ?[]const u8 = null,
};

/// Parse the `---`-delimited YAML header at the start of `body`.
/// Recognises `name:` and `description:` keys; ignores everything
/// else. Returns null when the frontmatter is missing either key
/// or malformed.
///
/// String-only path (no `tools:` allowlist parsing — that requires
/// an allocator for the dynamic list). Use `parseFrontmatterAlloc`
/// to pick up the tools field; both share the same name/description
/// extraction.
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

/// Same as `parseFrontmatter` but also extracts `tools:` as a list
/// of allowed tool names. Supported forms (both case-insensitive
/// at the YAML key):
///   tools: [bash, edit, write_file]      ← inline flow
///   tools: bash, edit, write_file        ← bare comma-separated
/// Block-style (one entry per line under `tools:`) is recognised
/// when the lines that follow start with `- ` and at least two
/// spaces of indent. Anything else is silently ignored — the
/// catalog still lists the skill, just with no tool restriction.
pub fn parseFrontmatterAlloc(arena: std.mem.Allocator, body: []const u8) ?Frontmatter {
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
    var tools: std.ArrayList([]const u8) = .empty;
    var in_tools_block: bool = false;
    var style: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line_raw| {
        // Strip CR but keep leading whitespace so we can detect
        // block-list indentation.
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Block-list continuation: `  - bash` while in_tools_block.
        if (in_tools_block and line.len >= 2 and line[0] == ' ') {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const item = std.mem.trim(u8, trimmed[2..], " \t");
                if (item.len > 0) {
                    const owned = arena.dupe(u8, stripQuotes(item)) catch return null;
                    tools.append(arena, owned) catch return null;
                }
                continue;
            }
            // Indented but not a list item — block ended.
            in_tools_block = false;
        } else {
            in_tools_block = false;
        }

        if (parseKeyValue(trimmed, "name")) |v| name = v;
        if (parseKeyValue(trimmed, "description")) |v| desc = v;
        if (parseKeyValue(trimmed, "style")) |v| {
            if (v.len > 0) {
                const owned = arena.dupe(u8, stripQuotes(v)) catch return null;
                style = owned;
            }
        }
        if (parseKeyValue(trimmed, "tools")) |v| {
            // Empty value → expect a block list on the following lines.
            if (v.len == 0) {
                in_tools_block = true;
                continue;
            }
            // Inline flow `[a, b, c]` or bare `a, b, c`.
            const inner: []const u8 = if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') v[1 .. v.len - 1] else v;
            var it = std.mem.splitScalar(u8, inner, ',');
            while (it.next()) |raw| {
                const item = std.mem.trim(u8, raw, " \t");
                if (item.len == 0) continue;
                const owned = arena.dupe(u8, stripQuotes(item)) catch return null;
                tools.append(arena, owned) catch return null;
            }
        }
    }
    if (name == null or desc == null) return null;
    return .{ .name = name.?, .description = desc.?, .tools = tools.items, .style = style };
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
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

test "parseFrontmatterAlloc: inline tools list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\name: x
        \\description: y
        \\tools: [bash, edit, write_file]
        \\---
        \\
    ;
    const fm = parseFrontmatterAlloc(arena_state.allocator(), body).?;
    try testing.expectEqual(@as(usize, 3), fm.tools.len);
    try testing.expectEqualStrings("bash", fm.tools[0]);
    try testing.expectEqualStrings("edit", fm.tools[1]);
    try testing.expectEqualStrings("write_file", fm.tools[2]);
}

test "parseFrontmatterAlloc: bare comma-separated tools" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\name: x
        \\description: y
        \\tools: read_file, grep
        \\---
        \\
    ;
    const fm = parseFrontmatterAlloc(arena_state.allocator(), body).?;
    try testing.expectEqual(@as(usize, 2), fm.tools.len);
    try testing.expectEqualStrings("read_file", fm.tools[0]);
    try testing.expectEqualStrings("grep", fm.tools[1]);
}

test "parseFrontmatterAlloc: block-list tools" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\name: x
        \\description: y
        \\tools:
        \\  - bash
        \\  - "edit"
        \\---
        \\
    ;
    const fm = parseFrontmatterAlloc(arena_state.allocator(), body).?;
    try testing.expectEqual(@as(usize, 2), fm.tools.len);
    try testing.expectEqualStrings("bash", fm.tools[0]);
    try testing.expectEqualStrings("edit", fm.tools[1]);
}

test "parseFrontmatterAlloc: missing tools key yields empty list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\name: x
        \\description: y
        \\---
        \\
    ;
    const fm = parseFrontmatterAlloc(arena_state.allocator(), body).?;
    try testing.expectEqual(@as(usize, 0), fm.tools.len);
}

test "parseFrontmatterAlloc: extracts style field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\name: bug-triage
        \\description: when to apply
        \\style: concise
        \\---
        \\body
    ;
    const fm = parseFrontmatterAlloc(arena_state.allocator(), body).?;
    try testing.expectEqualStrings("concise", fm.style.?);
}

test "parseFrontmatterAlloc: missing style yields null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\---
        \\name: x
        \\description: y
        \\---
        \\
    ;
    const fm = parseFrontmatterAlloc(arena_state.allocator(), body).?;
    try testing.expect(fm.style == null);
}

test "formatCatalog: surfaces recommended output style" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const skills = [_]Skill{
        .{
            .name = "tidy",
            .description = "clean up a file",
            .path = ".velk/skills/tidy/SKILL.md",
            .style = "concise",
        },
    };
    const out = try formatCatalog(arena_state.allocator(), &skills);
    try testing.expect(std.mem.indexOf(u8, out, "recommended output style: concise") != null);
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

fn writeSkill(io: Io, root_abs: []const u8, name: []const u8, body: []const u8, arena: std.mem.Allocator) !void {
    const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root_abs, name });
    try Io.Dir.cwd().makePath(io, dir);
    const path = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dir});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

test "loadFrom: discovers skills with valid frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root_abs = try tmp.dir.realpathAlloc(a, ".");

    try writeSkill(testing.io, root_abs, "alpha",
        \\---
        \\name: alpha
        \\description: first
        \\---
        \\
        \\body
    , a);
    try writeSkill(testing.io, root_abs, "beta",
        \\---
        \\name: beta
        \\description: second
        \\---
    , a);

    var by_name: std.StringHashMap(Skill) = .init(a);
    defer by_name.deinit();
    try loadFrom(a, testing.io, root_abs, &by_name);
    try testing.expectEqual(@as(usize, 2), by_name.count());
    try testing.expect(by_name.get("alpha") != null);
    try testing.expect(by_name.get("beta") != null);
}

test "loadFrom: malformed SKILL.md (no frontmatter) is silently skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root_abs = try tmp.dir.realpathAlloc(a, ".");

    // good skill alongside a malformed one
    try writeSkill(testing.io, root_abs, "good",
        \\---
        \\name: good
        \\description: works
        \\---
    , a);
    try writeSkill(testing.io, root_abs, "broken", "no frontmatter at all", a);

    var by_name: std.StringHashMap(Skill) = .init(a);
    defer by_name.deinit();
    try loadFrom(a, testing.io, root_abs, &by_name);
    try testing.expectEqual(@as(usize, 1), by_name.count());
    try testing.expect(by_name.get("good") != null);
    try testing.expect(by_name.get("broken") == null);
}

test "loadFrom: project skill with same name overrides earlier root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_abs = try tmp.dir.realpathAlloc(a, ".");
    const user_root = try std.fmt.allocPrint(a, "{s}/user", .{tmp_abs});
    const project_root = try std.fmt.allocPrint(a, "{s}/project", .{tmp_abs});

    try writeSkill(testing.io, user_root, "shared",
        \\---
        \\name: shared
        \\description: from-user
        \\---
    , a);
    try writeSkill(testing.io, project_root, "shared",
        \\---
        \\name: shared
        \\description: from-project
        \\---
    , a);

    var by_name: std.StringHashMap(Skill) = .init(a);
    defer by_name.deinit();
    // Same precedence as loadAll: user first, project later wins.
    try loadFrom(a, testing.io, user_root, &by_name);
    try loadFrom(a, testing.io, project_root, &by_name);
    try testing.expectEqual(@as(usize, 1), by_name.count());
    try testing.expectEqualStrings("from-project", by_name.get("shared").?.description);
}

test "loadFrom: missing root is a silent no-op" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var by_name: std.StringHashMap(Skill) = .init(a);
    defer by_name.deinit();
    try loadFrom(a, testing.io, "/nonexistent/path/that/does/not/exist", &by_name);
    try testing.expectEqual(@as(usize, 0), by_name.count());
}
