//! Vaxis-backed REPL with fixed input line, mouse-wheel scrolling, and
//! in-app mouse selection that copies to the system clipboard via
//! OSC-52. Because we own the alt-screen, the terminal's own selection
//! doesn't work — instead we track mouse drags ourselves, highlight
//! the range, and push it to the clipboard on release.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const agent = @import("agent.zig");
const provider_mod = @import("provider.zig");
const session_mod = @import("session.zig");
const persist = @import("persist.zig");
const cost = @import("cost.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

const Block = struct {
    kind: Kind,
    text: []const u8,

    const Kind = enum {
        user_prompt,
        assistant_text,
        tool_call,
        tool_result,
        tool_result_error,
        notice,
    };
};

const RenderedLine = struct {
    kind: Block.Kind,
    /// Bytes as they appear on the row (no trailing newline, already wrapped).
    text: []const u8,
};

/// A selection coordinate in logical scrollback space: which wrapped
/// line (0 = topmost ever), at which column. Logical positions stay
/// stable as the user scrolls, so anchor keeps pointing at the same
/// text while the cursor chases the mouse.
const Point = struct {
    line: usize,
    col: u16,
};

const Selection = struct {
    anchor: Point,
    cursor: Point,
    active: bool = false,

    fn normalized(self: Selection) struct { start: Point, end: Point } {
        const a = self.anchor;
        const b = self.cursor;
        if (a.line < b.line or (a.line == b.line and a.col <= b.col)) {
            return .{ .start = a, .end = b };
        }
        return .{ .start = b, .end = a };
    }
};

const AutoScroll = enum { none, up, down };

const Tui = struct {
    arena: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    model: []const u8,
    blocks: std.ArrayList(Block) = .empty,
    assistant_buf: std.ArrayList(u8) = .empty,
    has_open_assistant: bool = false,
    input: std.ArrayList(u8) = .empty,
    busy: bool = false,
    scroll_offset: usize = 0,
    selection: Selection = .{ .anchor = .{ .line = 0, .col = 0 }, .cursor = .{ .line = 0, .col = 0 } },
    /// Latest full set of wrapped lines, keyed by logical line index.
    all_lines: []const RenderedLine = &.{},
    /// Logical line index of the topmost visible row.
    visible_top: usize = 0,
    /// Number of visible rows in the scrollback region.
    visible_h: u16 = 0,
    /// The column where the mouse currently sits while dragging (for the
    /// autoscroll tick to know where to plant the cursor).
    drag_col: u16 = 0,
    /// When the mouse is held at the top/bottom while dragging, the
    /// polling tick scrolls in this direction until released.
    autoscroll: AutoScroll = .none,
    /// In-memory list of submitted prompts, oldest first. Up/Down at
    /// the input prompt walks through this.
    input_history: std.ArrayList([]const u8) = .empty,
    /// `null` = composing fresh; otherwise an index into `input_history`
    /// counted from the *end* (0 = last submitted prompt).
    history_idx: ?usize = null,

    fn pushBlock(self: *Tui, kind: Block.Kind, text: []const u8) !void {
        try self.flushOpenAssistant();
        const owned = try self.arena.dupe(u8, text);
        try self.blocks.append(self.arena, .{ .kind = kind, .text = owned });
        self.scroll_offset = 0;
    }

    fn appendAssistantText(self: *Tui, text: []const u8) !void {
        try self.assistant_buf.appendSlice(self.arena, text);
        self.has_open_assistant = true;
        self.scroll_offset = 0;
    }

    fn flushOpenAssistant(self: *Tui) !void {
        if (!self.has_open_assistant) return;
        const owned = try self.arena.dupe(u8, self.assistant_buf.items);
        try self.blocks.append(self.arena, .{ .kind = .assistant_text, .text = owned });
        self.assistant_buf.clearRetainingCapacity();
        self.has_open_assistant = false;
    }

    fn render(self: *Tui) !void {
        const win = self.vx.window();
        win.clear();

        const w = win.width;
        const h = win.height;
        if (h < 3) return;

        const scroll_h: u16 = h - 2;

        var lines: std.ArrayList(RenderedLine) = .empty;
        for (self.blocks.items) |block| try wrapBlockInto(self.arena, &lines, block, w);
        if (self.has_open_assistant) {
            const tmp: Block = .{ .kind = .assistant_text, .text = self.assistant_buf.items };
            try wrapBlockInto(self.arena, &lines, tmp, w);
        }

        const total = lines.items.len;
        const max_offset = if (total > scroll_h) total - scroll_h else 0;
        if (self.scroll_offset > max_offset) self.scroll_offset = max_offset;
        const end: usize = total - self.scroll_offset;
        const start: usize = if (end > scroll_h) end - scroll_h else 0;
        self.all_lines = lines.items;
        self.visible_top = start;
        self.visible_h = scroll_h;

        const visible = lines.items[start..end];
        for (visible, 0..) |line, idx| {
            const row: u16 = @intCast(idx);
            const logical: usize = start + idx;
            const base_style = styleFor(line.kind);
            if (self.selection.active and selectionOverlapsLine(self.selection, logical)) {
                renderRowWithSelection(win, row, line.text, base_style, self.selection, logical);
            } else {
                _ = win.print(&.{.{ .text = line.text, .style = base_style }}, .{
                    .row_offset = row,
                    .col_offset = 0,
                    .wrap = .none,
                });
            }
        }

        const sep_row: u16 = h - 2;
        var sep_buf: std.ArrayList(u8) = .empty;
        if (self.scroll_offset > 0) {
            try sep_buf.print(self.arena, "── ↑ {d} line(s) above ", .{self.scroll_offset});
        } else {
            try sep_buf.appendSlice(self.arena, "── ");
        }
        while (sep_buf.items.len < w) try sep_buf.append(self.arena, '-');
        _ = win.print(&.{.{ .text = sep_buf.items[0..@min(sep_buf.items.len, w)], .style = .{ .fg = .{ .index = 8 } } }}, .{
            .row_offset = sep_row,
            .wrap = .none,
        });

        const input_row: u16 = h - 1;
        const prompt: []const u8 = if (self.busy) "… " else "> ";
        _ = win.print(&.{
            .{ .text = prompt, .style = .{ .fg = .{ .index = 4 }, .bold = true } },
            .{ .text = self.input.items },
        }, .{ .row_offset = input_row, .wrap = .none });

        if (!self.busy) {
            const cursor_col: u16 = @intCast(@min(w - 1, prompt.len + self.input.items.len));
            win.showCursor(cursor_col, input_row);
        } else {
            win.hideCursor();
        }

        try self.vx.render(self.tty.writer());
    }

    fn sink(self: *Tui) agent.Sink {
        return .{
            .ctx = self,
            .onText = onText,
            .onToolCall = onToolCall,
            .onToolResult = onToolResult,
            .onTurnEnd = onTurnEnd,
        };
    }

    fn cast(ctx: ?*anyopaque) *Tui {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = cast(ctx);
        try self.appendAssistantText(text);
        try self.render();
    }

    fn onToolCall(ctx: ?*anyopaque, name: []const u8, input_json: []const u8) anyerror!void {
        const self = cast(ctx);
        var preview = input_json;
        if (preview.len > 200) preview = preview[0..200];
        const line = try std.fmt.allocPrint(self.arena, "→ {s}({s})", .{ name, preview });
        try self.pushBlock(.tool_call, line);
        try self.render();
    }

    fn onToolResult(ctx: ?*anyopaque, text: []const u8, is_error: bool) anyerror!void {
        const self = cast(ctx);
        var preview = text;
        if (preview.len > 200) preview = preview[0..200];
        const ellipsis: []const u8 = if (text.len > 200) "…" else "";
        const line = try std.fmt.allocPrint(self.arena, "← {s}{s}", .{ preview, ellipsis });
        try self.pushBlock(if (is_error) .tool_result_error else .tool_result, line);
        try self.render();
    }

    fn onTurnEnd(ctx: ?*anyopaque, usage: provider_mod.Usage) anyerror!void {
        const self = cast(ctx);
        try self.flushOpenAssistant();
        if (usage.input_tokens > 0 or usage.output_tokens > 0) {
            var buf: std.ArrayList(u8) = .empty;
            try buf.print(self.arena, "[tokens: {d} in / {d} out", .{ usage.input_tokens, usage.output_tokens });
            if (usage.cache_read_tokens > 0 or usage.cache_creation_tokens > 0) {
                try buf.print(self.arena, " · cache {d} read / {d} write", .{ usage.cache_read_tokens, usage.cache_creation_tokens });
            }
            if (cost.turnCost(self.model, usage)) |c| {
                try buf.print(self.arena, " · ${d:.4}", .{c});
            }
            try buf.append(self.arena, ']');
            try self.pushBlock(.notice, buf.items);
        }
        try self.render();
    }
};

fn styleFor(kind: Block.Kind) vaxis.Cell.Style {
    return switch (kind) {
        .user_prompt => .{ .fg = .{ .index = 6 }, .bold = true },
        .assistant_text => .{},
        .tool_call => .{ .fg = .{ .index = 3 } },
        .tool_result => .{ .fg = .{ .index = 8 } },
        .tool_result_error => .{ .fg = .{ .index = 1 } },
        .notice => .{ .fg = .{ .index = 8 }, .italic = true },
    };
}

fn wrapBlockInto(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderedLine),
    block: Block,
    width: u16,
) !void {
    if (block.text.len == 0) {
        try out.append(arena, .{ .kind = block.kind, .text = "" });
        return;
    }
    var rest = block.text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_end = nl orelse rest.len;
        var line = rest[0..line_end];
        while (line.len > width) {
            try out.append(arena, .{ .kind = block.kind, .text = line[0..width] });
            line = line[width..];
        }
        try out.append(arena, .{ .kind = block.kind, .text = line });
        rest = if (nl) |n| rest[n + 1 ..] else rest[line_end..];
    }
}

fn selectionOverlapsLine(sel: Selection, line: usize) bool {
    const n = sel.normalized();
    return line >= n.start.line and line <= n.end.line;
}

fn renderRowWithSelection(
    win: vaxis.Window,
    row: u16,
    text: []const u8,
    base: vaxis.Cell.Style,
    sel: Selection,
    line: usize,
) void {
    const n = sel.normalized();
    const selected_start: u16 = if (line == n.start.line) n.start.col else 0;
    const selected_end: u16 = if (line == n.end.line) n.end.col else @intCast(text.len);
    const clamp_end: u16 = @min(selected_end, @as(u16, @intCast(text.len)));
    const clamp_start: u16 = @min(selected_start, clamp_end);

    const sel_style: vaxis.Cell.Style = .{ .reverse = true };

    if (clamp_start > 0) {
        _ = win.print(&.{.{ .text = text[0..clamp_start], .style = base }}, .{
            .row_offset = row,
            .col_offset = 0,
            .wrap = .none,
        });
    }
    if (clamp_end > clamp_start) {
        _ = win.print(&.{.{ .text = text[clamp_start..clamp_end], .style = sel_style }}, .{
            .row_offset = row,
            .col_offset = clamp_start,
            .wrap = .none,
        });
    }
    if (clamp_end < text.len) {
        _ = win.print(&.{.{ .text = text[clamp_end..], .style = base }}, .{
            .row_offset = row,
            .col_offset = clamp_end,
            .wrap = .none,
        });
    }
}

fn extractSelection(arena: std.mem.Allocator, lines: []const RenderedLine, sel: Selection) ![]u8 {
    const n = sel.normalized();
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = n.start.line;
    const end_line: usize = @min(n.end.line, lines.len -| 1);
    while (i <= end_line) : (i += 1) {
        const text = lines[i].text;
        const s: usize = if (i == n.start.line) @min(n.start.col, text.len) else 0;
        const e: usize = if (i == n.end.line) @min(n.end.col, text.len) else text.len;
        if (e > s) try buf.appendSlice(arena, text[s..e]);
        if (i != end_line) try buf.append(arena, '\n');
    }
    return buf.items;
}

fn copyToClipboard(arena: std.mem.Allocator, tty_writer: *Io.Writer, text: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(text.len);
    const buf = try arena.alloc(u8, encoded_len);
    _ = encoder.encode(buf, text);
    try tty_writer.writeAll("\x1b]52;c;");
    try tty_writer.writeAll(buf);
    try tty_writer.writeAll("\x07");
    try tty_writer.flush();
}

pub fn run(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    sess: *session_mod.Session,
    model: []const u8,
) !void {
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, env_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminalSend(tty.writer());
    try vx.setMouseMode(tty.writer(), true);
    defer vx.setMouseMode(tty.writer(), false) catch {};

    var tui: Tui = .{ .arena = arena, .vx = &vx, .tty = &tty, .model = model };

    // Hydrate input history from disk so up-arrow recall works across
    // launches. Failures are non-fatal — first run, no XDG_STATE_HOME,
    // etc — we just skip persistence and run with an empty history.
    const history_path = persist.historyPath(arena, env_map) catch null;
    if (history_path) |path| {
        if (persist.loadHistory(arena, io, path)) |hist| {
            try tui.input_history.appendSlice(arena, hist);
        } else |_| {}
    }

    try tui.pushBlock(
        .notice,
        "velk REPL — Ctrl-D exit · Enter send · ↑/↓ history · PageUp/PageDown scroll · drag to select · mouse-up copies to clipboard",
    );
    try tui.render();

    while (true) {
        // Poll for an event. When idle, drive autoscroll at ~25 Hz so
        // holding the mouse at the edge scrolls continuously.
        const maybe_event: ?Event = try loop.tryEvent();
        const event = maybe_event orelse {
            if (tui.autoscroll != .none and tui.selection.active) {
                const lines_per_tick: usize = 1;
                const total = tui.all_lines.len;
                const scroll_h: u16 = if (tui.visible_h > 0) tui.visible_h else 1;
                const max_off = if (total > scroll_h) total - scroll_h else 0;
                switch (tui.autoscroll) {
                    .up => tui.scroll_offset = @min(tui.scroll_offset + lines_per_tick, max_off),
                    .down => tui.scroll_offset -|= lines_per_tick,
                    .none => unreachable,
                }
                const off = @min(tui.scroll_offset, max_off);
                const end: usize = total -| off;
                const start: usize = if (end > scroll_h) end - scroll_h else 0;
                const row: u16 = switch (tui.autoscroll) {
                    .up => 0,
                    .down => scroll_h - 1,
                    .none => unreachable,
                };
                tui.selection.cursor = .{ .line = start + row, .col = tui.drag_col };
                try tui.render();
            }
            try Io.sleep(io, Io.Duration.fromMilliseconds(50), .awake);
            continue;
        };
        switch (event) {
            .winsize => |ws| {
                try vx.resize(gpa, tty.writer(), ws);
                try tui.render();
            },
            .mouse => |m| {
                const h = vx.window().height;
                const scroll_h: u16 = if (h > 2) h - 2 else 0;
                switch (m.type) {
                    .press => switch (m.button) {
                        .wheel_up => {
                            tui.scroll_offset += 3;
                            tui.selection.active = false;
                            try tui.render();
                        },
                        .wheel_down => {
                            tui.scroll_offset -|= 3;
                            tui.selection.active = false;
                            try tui.render();
                        },
                        .left => {
                            if (m.row >= 0 and m.row < scroll_h) {
                                const row: u16 = @intCast(m.row);
                                const col: u16 = @max(@as(i16, 0), m.col);
                                const line_idx = tui.visible_top + row;
                                tui.selection = .{
                                    .anchor = .{ .line = line_idx, .col = col },
                                    .cursor = .{ .line = line_idx, .col = col },
                                    .active = true,
                                };
                                try tui.render();
                            }
                        },
                        else => {},
                    },
                    .drag => {
                        if (!tui.selection.active) continue;
                        const col: u16 = @max(@as(i16, 0), m.col);
                        tui.drag_col = col;

                        // Decide whether we should auto-scroll continuously
                        // while the mouse is held at or past an edge.
                        if (scroll_h > 0 and m.row <= 0) {
                            tui.autoscroll = .up;
                        } else if (scroll_h > 0 and m.row >= @as(i16, @intCast(scroll_h - 1))) {
                            tui.autoscroll = .down;
                        } else {
                            tui.autoscroll = .none;
                        }

                        const clamped_row: i16 = @max(0, @min(m.row, @as(i16, @intCast(scroll_h -| 1))));
                        const row: u16 = @intCast(clamped_row);
                        tui.selection.cursor = .{ .line = tui.visible_top + row, .col = col };
                        try tui.render();
                    },
                    .release => {
                        tui.autoscroll = .none;
                        if (!tui.selection.active) continue;
                        const n = tui.selection.normalized();
                        const has_span = n.start.line != n.end.line or n.start.col != n.end.col;
                        if (has_span) {
                            const text = try extractSelection(arena, tui.all_lines, tui.selection);
                            if (text.len > 0) try copyToClipboard(arena, tty.writer(), text);
                        } else {
                            tui.selection.active = false;
                            try tui.render();
                        }
                    },
                    .motion => {},
                }
            },
            .key_press => |key| {
                if (key.matches('d', .{ .ctrl = true })) return;
                if (key.matches('c', .{ .ctrl = true })) {
                    if (tui.selection.active) {
                        tui.selection.active = false;
                        try tui.render();
                        continue;
                    }
                    if (tui.input.items.len > 0) {
                        tui.input.clearRetainingCapacity();
                        try tui.render();
                    } else {
                        return;
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.page_up, .{})) {
                    const page: u16 = @max(1, (vx.window().height -| 2) / 2);
                    tui.scroll_offset += page;
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    const page: u16 = @max(1, (vx.window().height -| 2) / 2);
                    tui.scroll_offset -|= page;
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.up, .{ .shift = true })) {
                    tui.scroll_offset += 1;
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.down, .{ .shift = true })) {
                    tui.scroll_offset -|= 1;
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.home, .{})) {
                    tui.scroll_offset = std.math.maxInt(usize);
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.end, .{})) {
                    tui.scroll_offset = 0;
                    try tui.render();
                    continue;
                }
                if (tui.busy) continue;
                // Plain Up/Down (no modifiers) = input history navigation.
                if (key.matches(vaxis.Key.up, .{})) {
                    if (tui.input_history.items.len == 0) continue;
                    const next_idx: usize = if (tui.history_idx) |i|
                        @min(i + 1, tui.input_history.items.len - 1)
                    else
                        0;
                    tui.history_idx = next_idx;
                    const entry = tui.input_history.items[tui.input_history.items.len - 1 - next_idx];
                    tui.input.clearRetainingCapacity();
                    try tui.input.appendSlice(arena, entry);
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    if (tui.history_idx) |i| {
                        if (i == 0) {
                            tui.history_idx = null;
                            tui.input.clearRetainingCapacity();
                        } else {
                            tui.history_idx = i - 1;
                            const entry = tui.input_history.items[tui.input_history.items.len - i];
                            tui.input.clearRetainingCapacity();
                            try tui.input.appendSlice(arena, entry);
                        }
                        try tui.render();
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (tui.input.items.len == 0) continue;
                    const prompt = try arena.dupe(u8, tui.input.items);
                    try tui.input_history.append(arena, prompt);
                    tui.history_idx = null;
                    if (history_path) |path| persist.appendHistory(arena, io, path, prompt) catch {};
                    try tui.pushBlock(.user_prompt, prompt);
                    tui.input.clearRetainingCapacity();
                    tui.busy = true;
                    try tui.render();

                    sess.ask(prompt, tui.sink()) catch |err| {
                        const msg = try std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)});
                        try tui.pushBlock(.tool_result_error, msg);
                    };

                    tui.busy = false;
                    try tui.render();
                    continue;
                }
                if (key.matches(vaxis.Key.backspace, .{})) {
                    if (tui.input.items.len > 0) _ = tui.input.pop();
                    try tui.render();
                    continue;
                }
                if (key.text) |t| {
                    try tui.input.appendSlice(arena, t);
                    try tui.render();
                }
            },
        }
    }
}
