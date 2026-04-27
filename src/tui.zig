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
const cost_log = @import("cost_log.zig");
const slash = @import("slash.zig");
const notify = @import("notify.zig");
const markdown = @import("markdown.zig");
const approval = @import("approval.zig");
const mentions = @import("mentions.zig");
const git_commit = @import("git_commit.zig");

const Event = union(enum) {
    // vaxis-posted events
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,

    // Agent-thread-posted events. Slices are heap-allocated via gpa
    // and owned by the main thread once dequeued; the handler frees.
    a_text: []u8,
    a_tool_call: AgentToolCall,
    a_tool_result: AgentToolResult,
    a_usage: provider_mod.Usage,
    a_done: WorkerResult,
    /// Posted by ApprovalGate.requestApproval — main thread renders
    /// the diff + prompt, captures the user's decision, calls
    /// gate.deliver(...). Strings are gpa-owned; main thread frees.
    a_approval: approval.Request,
};

const AgentToolCall = struct {
    name: []u8,
    input: []u8,
};

const AgentToolResult = struct {
    text: []u8,
    is_error: bool,
};

const WorkerResult = struct {
    err: ?anyerror = null,
};

const Block = struct {
    /// Stable, monotonic id assigned at push-time. RenderedLine carries
    /// it as a back-pointer so the Tab-toggle handler can find the
    /// source block from a logical row.
    id: u32,
    kind: Kind,
    text: []const u8,
    /// When true, the wrapper renders a one-line summary instead of
    /// the full text. Only honoured for `tool_call` / `tool_result*`.
    /// Tab in normal mode toggles this for the block under the cursor.
    collapsed: bool = false,

    const Kind = enum {
        user_prompt,
        assistant_text,
        tool_call,
        tool_result,
        tool_result_error,
        notice,
        /// Unified diff awaiting approval. Rendered in green/red,
        /// followed by an approval-prompt notice. The block stays
        /// after approval as a record of what was changed.
        diff,
        /// "[a]pply / [s]kip / [A]lways apply" prompt — only visible
        /// while `awaiting_approval` is true. Removed after the user
        /// responds.
        approval_prompt,
        /// Fenced code block extracted from assistant text on
        /// flush. Rendered with a header showing the language tag
        /// and body in dim cyan; markdown inline parsing is skipped
        /// for the body (verbatim).
        code_block,
    };

    /// Tool-block kinds the user can collapse. Other kinds ignore the
    /// `collapsed` flag entirely.
    fn isCollapsible(self: Block) bool {
        return switch (self.kind) {
            .tool_call, .tool_result, .tool_result_error => true,
            else => false,
        };
    }
};

const RenderedLine = struct {
    kind: Block.Kind,
    /// Bytes as they appear on the row (no trailing newline, already wrapped).
    text: []const u8,
    /// id of the source `Block` this row came from, or 0 when this row
    /// has no associated block (e.g. live assistant streaming buffer).
    block_id: u32 = 0,
};

/// Auto-collapse threshold: tool blocks taller than this many wrapped
/// rows render as a one-line summary on push. The user can still
/// expand with Tab.
const auto_collapse_lines: usize = 8;

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

const LoopT = vaxis.Loop(Event);

/// Per-turn agent execution state. While a turn is in flight, the worker
/// runs on its own task (via Io.concurrent). Sink callbacks alloc strings
/// in `gpa` and post Event variants to the loop queue; the main thread
/// drains them and updates TUI state. Cancel is sub-ms via Future.cancel.
const Turn = struct {
    future: Io.Future(WorkerResult),
    shim: *ShimSink,
    /// Owned by gpa; freed on turn cleanup (after future has been awaited).
    prompt: []u8,
    /// Monotonic timestamp captured when the turn started. Used to
    /// compute elapsed time for the post-turn desktop notification.
    started_at: Io.Timestamp,
};

const ShimSink = struct {
    gpa: std.mem.Allocator,
    loop: *LoopT,

    fn sink(self: *ShimSink) agent.Sink {
        return .{
            .ctx = self,
            .onText = onText,
            .onToolCall = onToolCall,
            .onToolResult = onToolResult,
            .onTurnEnd = onTurnEnd,
        };
    }

    fn cast(ctx: ?*anyopaque) *ShimSink {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = cast(ctx);
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        try self.loop.postEvent(.{ .a_text = owned });
    }

    fn onToolCall(ctx: ?*anyopaque, name: []const u8, input_json: []const u8) anyerror!void {
        const self = cast(ctx);
        const name_dup = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(name_dup);
        const input_dup = try self.gpa.dupe(u8, input_json);
        errdefer self.gpa.free(input_dup);
        try self.loop.postEvent(.{ .a_tool_call = .{ .name = name_dup, .input = input_dup } });
    }

    fn onToolResult(ctx: ?*anyopaque, text: []const u8, is_error: bool) anyerror!void {
        const self = cast(ctx);
        const text_dup = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_dup);
        try self.loop.postEvent(.{ .a_tool_result = .{ .text = text_dup, .is_error = is_error } });
    }

    fn onTurnEnd(ctx: ?*anyopaque, usage: provider_mod.Usage) anyerror!void {
        const self = cast(ctx);
        try self.loop.postEvent(.{ .a_usage = usage });
    }
};

/// Worker function invoked on a separate task. Returns a `WorkerResult`
/// (in the Future) and ALSO posts `a_done` so the main thread learns to
/// await without polling.
fn agentWorker(
    sess: *session_mod.Session,
    prompt: []const u8,
    shim: *ShimSink,
) WorkerResult {
    var result: WorkerResult = .{};
    sess.ask(prompt, shim.sink()) catch |err| {
        result.err = err;
    };
    shim.loop.postEvent(.{ .a_done = result }) catch {};
    return result;
}

const Tui = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    loop: *LoopT,
    sess: *session_mod.Session,
    model: []const u8,
    turn: ?Turn = null,
    /// Owned by run(); scoped so `all_lines` stays valid between renders
    /// (selection extraction reads it after a render returns). Reset
    /// at the start of each render so memory is reclaimed.
    lines_arena: *std.heap.ArenaAllocator,
    blocks: std.ArrayList(Block) = .empty,
    /// Next id to assign on `pushBlock`. Starts at 1 — id 0 means
    /// "no associated block" on a `RenderedLine`.
    next_block_id: u32 = 1,
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
    /// Vim-ish modal toggle. Insert is the default and matches the
    /// pre-vim-mode behavior exactly. Normal mode swallows printable
    /// keys and reinterprets them as scrollback navigation. Visual
    /// (charwise) keeps `selection.anchor` pinned and grows
    /// `selection.cursor` with the nav cursor; visual_line widens
    /// the selection to whole lines from min(anchor,cursor) to max.
    mode: enum { insert, normal, visual, visual_line } = .insert,
    /// In visual_line mode we remember the anchor's line so the
    /// recomputed selection covers exactly the line range, regardless
    /// of which direction the cursor moves.
    visual_line_anchor: usize = 0,
    /// Logical (line, col) cursor used by normal/visual modes. Tracked
    /// independently from `selection` because normal mode shows just a
    /// caret while visual extends the selection.
    nav_cursor: Point = .{ .line = 0, .col = 0 },
    /// Rolling sum of every per-turn `Usage` we've seen this session.
    /// Drives `/cost`. Reset by `/clear`.
    cumulative_usage: provider_mod.Usage = .{},
    /// Frame counter for the status-line spinner. Advances on idle
    /// ticks while `busy = true`.
    spinner_tick: u32 = 0,
    /// Number of MCP servers attached for this session (for the
    /// status line). 0 when none.
    mcp_count: u8 = 0,
    /// Process env map. Used for notify thresholds + webhook URL.
    env_map: *std.process.Environ.Map,
    /// Cross-thread approval gate. The TUI plugs its event-posting
    /// closure into this; the worker calls `requestApproval` from
    /// inside edit/write_file and blocks until we deliver a decision.
    approval_gate: *approval.ApprovalGate,
    /// Block id of the "[a]pply / [s]kip / [A]lways apply" prompt
    /// that's currently awaiting input. 0 means no prompt active.
    /// Set when an `a_approval` event arrives; cleared after we
    /// deliver a decision.
    awaiting_prompt_id: u32 = 0,
    /// Multi-line input mode. While true, Enter appends `\n` to
    /// the input buffer and Ctrl-D submits (instead of exiting).
    /// Toggled by the `/multiline` slash command.
    multiline: bool = false,
    /// When true, run `git add -A && git commit -m …` at the end
    /// of every dirty turn. Off by default.
    auto_commit: bool = false,
    /// Last user prompt text — used as the auto-commit message
    /// (truncated). Populated on every successful submit.
    last_prompt: []const u8 = "",

    /// Adjust `scroll_offset` so `nav_cursor.line` is on screen. Must
    /// be called after touching `nav_cursor.line`. Uses the most recent
    /// render's `visible_h`; safe before the first render (no-op).
    fn ensureCursorVisible(self: *Tui) void {
        if (self.visible_h == 0 or self.all_lines.len == 0) return;
        const total = self.all_lines.len;
        const max_offset = if (total > self.visible_h) total - self.visible_h else 0;
        const top = total -| @min(self.scroll_offset, max_offset) -| self.visible_h;
        const bot = total -| @min(self.scroll_offset, max_offset);
        if (self.nav_cursor.line < top) {
            // cursor is above viewport — increase offset
            self.scroll_offset = total -| self.nav_cursor.line -| self.visible_h;
        } else if (self.nav_cursor.line >= bot) {
            // cursor is at/below viewport — decrease offset
            self.scroll_offset = total -| self.nav_cursor.line -| 1;
        }
    }

    fn lineLen(self: *const Tui, line_idx: usize) usize {
        if (line_idx >= self.all_lines.len) return 0;
        return self.all_lines[line_idx].text.len;
    }

    /// Move `nav_cursor` to the start of the next word, walking across
    /// lines if the current one has nothing left. No-op at end of
    /// scrollback.
    fn moveWordForward(self: *Tui) void {
        if (self.all_lines.len == 0) return;
        // First try same line, starting after current col.
        if (self.nav_cursor.line < self.all_lines.len) {
            const text = self.all_lines[self.nav_cursor.line].text;
            if (nextWordStart(text, self.nav_cursor.col)) |c| {
                self.nav_cursor.col = @intCast(c);
                return;
            }
        }
        // Scan subsequent lines for the first word.
        var li: usize = self.nav_cursor.line + 1;
        while (li < self.all_lines.len) : (li += 1) {
            const text = self.all_lines[li].text;
            if (firstWordStart(text)) |c| {
                self.nav_cursor.line = li;
                self.nav_cursor.col = @intCast(c);
                return;
            }
        }
    }

    /// Inverse of `moveWordForward`. No-op at start of scrollback.
    fn moveWordBackward(self: *Tui) void {
        if (self.all_lines.len == 0) return;
        if (self.nav_cursor.line < self.all_lines.len) {
            const text = self.all_lines[self.nav_cursor.line].text;
            if (prevWordStart(text, self.nav_cursor.col)) |c| {
                self.nav_cursor.col = @intCast(c);
                return;
            }
        }
        var li: usize = self.nav_cursor.line;
        while (li > 0) {
            li -= 1;
            const text = self.all_lines[li].text;
            if (lastWordStart(text)) |c| {
                self.nav_cursor.line = li;
                self.nav_cursor.col = @intCast(c);
                return;
            }
        }
    }

    /// In visual_line mode, snap `selection` to cover whole lines from
    /// `visual_line_anchor` through the current nav_cursor's line.
    fn syncVisualLineSelection(self: *Tui) void {
        const a_line = self.visual_line_anchor;
        const c_line = self.nav_cursor.line;
        const lo = @min(a_line, c_line);
        const hi = @max(a_line, c_line);
        const hi_len = self.lineLen(hi);
        const hi_col: u16 = if (hi_len == 0) 0 else @intCast(hi_len - 1);
        self.selection.anchor = .{ .line = lo, .col = 0 };
        self.selection.cursor = .{ .line = hi, .col = hi_col };
        self.selection.active = true;
    }

    /// Clamp the nav cursor to the bounds of its current line. Call
    /// after any line move so the cursor doesn't sit past the right
    /// edge of a now-shorter row.
    fn clampNavCol(self: *Tui) void {
        const len = self.lineLen(self.nav_cursor.line);
        if (len == 0) {
            self.nav_cursor.col = 0;
        } else if (self.nav_cursor.col >= len) {
            self.nav_cursor.col = @intCast(len - 1);
        }
    }

    fn pushBlock(self: *Tui, kind: Block.Kind, text: []const u8) !void {
        try self.flushOpenAssistant();
        const owned = try self.arena.dupe(u8, text);
        const id = self.next_block_id;
        self.next_block_id += 1;
        var block: Block = .{ .id = id, .kind = kind, .text = owned };
        // Auto-collapse tool blocks whose text spans more than the
        // threshold (counted as newline-terminated rows; long single
        // lines also auto-collapse since wrapping will multiply the
        // visible row count).
        if (block.isCollapsible() and naturalLineCount(owned) > auto_collapse_lines) {
            block.collapsed = true;
        }
        try self.blocks.append(self.arena, block);
        self.scroll_offset = 0;
    }

    fn appendAssistantText(self: *Tui, text: []const u8) !void {
        try self.assistant_buf.appendSlice(self.arena, text);
        self.has_open_assistant = true;
        self.scroll_offset = 0;
    }

    fn flushOpenAssistant(self: *Tui) !void {
        if (!self.has_open_assistant) return;
        // Whole-buffer parse: split into prose + fenced code blocks
        // so each renders with the right styling. Streaming text
        // stays in `assistant_buf` until a turn ends, so this only
        // runs once per turn (or once per pushBlock that closes the
        // open assistant).
        const segments = try markdown.parseBlocks(self.arena, self.assistant_buf.items);
        for (segments) |seg| {
            const id = self.next_block_id;
            self.next_block_id += 1;
            switch (seg) {
                .text => |t| try self.blocks.append(self.arena, .{
                    .id = id,
                    .kind = .assistant_text,
                    .text = t,
                }),
                .code => |c| {
                    const formatted = try formatCodeBlock(self.arena, c);
                    try self.blocks.append(self.arena, .{
                        .id = id,
                        .kind = .code_block,
                        .text = formatted,
                    });
                },
            }
        }
        self.assistant_buf.clearRetainingCapacity();
        self.has_open_assistant = false;
    }

    /// Replace the pending approval-prompt block with a one-line
    /// notice recording the user's choice, and clear the awaiting
    /// flag so subsequent keys go to the input box again.
    fn consumeApprovalPrompt(self: *Tui, decision: approval.Decision) !void {
        const prompt_id = self.awaiting_prompt_id;
        if (prompt_id == 0) return;
        self.awaiting_prompt_id = 0;
        const verdict: []const u8 = switch (decision) {
            .apply => "applied",
            .skip => "skipped",
            .always_apply => "applied (and approving the rest of this session)",
        };
        for (self.blocks.items) |*b| {
            if (b.id != prompt_id) continue;
            b.kind = .notice;
            b.text = try std.fmt.allocPrint(self.arena, "→ {s}", .{verdict});
            return;
        }
    }

    /// Toggle the `collapsed` flag of the block under the nav cursor.
    /// No-op when nothing collapsible is selected. Returns true if a
    /// toggle happened, so the caller can re-render.
    fn toggleCollapseAtCursor(self: *Tui) bool {
        if (self.all_lines.len == 0) return false;
        if (self.nav_cursor.line >= self.all_lines.len) return false;
        const target_id = self.all_lines[self.nav_cursor.line].block_id;
        if (target_id == 0) return false;
        for (self.blocks.items) |*b| {
            if (b.id != target_id) continue;
            if (!b.isCollapsible()) return false;
            b.collapsed = !b.collapsed;
            return true;
        }
        return false;
    }

    fn render(self: *Tui) !void {
        const win = self.vx.window();
        win.clear();

        const w = win.width;
        const h = win.height;
        // Need at least: 1 row scrollback, status, separator, input.
        if (h < 4) return;

        // Input rows expand when the buffer holds newlines (multi-line
        // mode). Cap at h/3 so the scrollback never disappears.
        var input_rows: u16 = 1;
        for (self.input.items) |c| {
            if (c == '\n') input_rows += 1;
        }
        const input_cap: u16 = @max(1, @divTrunc(h, 3));
        if (input_rows > input_cap) input_rows = input_cap;

        const reserved: u16 = 2 + input_rows; // status + separator + input rows
        const scroll_h: u16 = if (h > reserved) h - reserved else 0;

        // Reset (not deinit) so previous render's lines memory is
        // reclaimed AND `all_lines` is repointed to a fresh slab that
        // outlives this render call. Mouse handlers that read
        // `tui.all_lines` between renders see valid bytes.
        _ = self.lines_arena.reset(.retain_capacity);
        const lines_alloc = self.lines_arena.allocator();

        var lines: std.ArrayList(RenderedLine) = .empty;
        for (self.blocks.items) |block| try wrapBlockInto(lines_alloc, &lines, block, w);
        if (self.has_open_assistant) {
            const tmp: Block = .{ .id = 0, .kind = .assistant_text, .text = self.assistant_buf.items };
            try wrapBlockInto(lines_alloc, &lines, tmp, w);
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
            const base_style = if (line.kind == .diff)
                styleForDiffLine(line.text)
            else
                styleFor(line.kind);
            if (self.selection.active and selectionOverlapsLine(self.selection, logical)) {
                renderRowWithSelection(win, row, line.text, base_style, self.selection, logical);
            } else if (line.kind == .assistant_text) {
                // Apply inline markdown styling. Wrapping has already
                // happened so each `line` is one terminal row of text.
                try renderMarkdownLine(lines_alloc, win, row, line.text, base_style);
            } else {
                _ = win.print(&.{.{ .text = line.text, .style = base_style }}, .{
                    .row_offset = row,
                    .col_offset = 0,
                    .wrap = .none,
                });
            }
        }

        // Caret for normal mode (no active selection): paint a single
        // inverted cell at nav_cursor. Visual mode's selection range
        // already covers this position.
        if (self.mode == .normal and self.nav_cursor.line >= start and self.nav_cursor.line < end) {
            const row: u16 = @intCast(self.nav_cursor.line - start);
            const line_text = visible[row].text;
            const col = @min(self.nav_cursor.col, @as(u16, @intCast(if (line_text.len == 0) 0 else line_text.len - 1)));
            const ch: []const u8 = if (line_text.len == 0) " " else line_text[col .. col + 1];
            _ = win.print(&.{.{ .text = ch, .style = .{ .reverse = true } }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
        }

        // Status row at h-3: model · tokens · cost · spinner-when-busy.
        // One row, padded so the cost sits flush right.
        try self.renderStatusLine(lines_alloc, win, h - 3, w);

        const sep_row: u16 = h - 2;
        var sep_buf: std.ArrayList(u8) = .empty;
        if (self.scroll_offset > 0) {
            try sep_buf.print(lines_alloc, "── ↑ {d} line(s) above ", .{self.scroll_offset});
        } else {
            try sep_buf.appendSlice(lines_alloc, "── ");
        }
        while (sep_buf.items.len < w) try sep_buf.append(lines_alloc, '-');
        _ = win.print(&.{.{ .text = sep_buf.items[0..@min(sep_buf.items.len, w)], .style = .{ .fg = .{ .index = 8 } } }}, .{
            .row_offset = sep_row,
            .wrap = .none,
        });

        const input_top: u16 = h - input_rows;
        const prompt: []const u8 = if (self.busy)
            "… "
        else switch (self.mode) {
            .insert => "> ",
            .normal => "n ",
            .visual => "v ",
            .visual_line => "V ",
        };
        const prompt_color: u8 = switch (self.mode) {
            .insert => 4, // blue
            .normal => 2, // green
            .visual => 5, // magenta
            .visual_line => 5,
        };
        const cont_prompt: []const u8 = "  "; // continuation rows: blank gutter
        const prompt_style: vaxis.Cell.Style = .{ .fg = .{ .index = prompt_color }, .bold = true };

        // Walk newlines in the buffer; render up to `input_rows` of them.
        var line_iter = std.mem.splitScalar(u8, self.input.items, '\n');
        var rendered_rows: u16 = 0;
        var last_line_text: []const u8 = "";
        while (line_iter.next()) |line_text| {
            if (rendered_rows >= input_rows) break;
            const row = input_top + rendered_rows;
            const head: []const u8 = if (rendered_rows == 0) prompt else cont_prompt;
            _ = win.print(&.{
                .{ .text = head, .style = prompt_style },
                .{ .text = line_text },
            }, .{ .row_offset = row, .wrap = .none });
            last_line_text = line_text;
            rendered_rows += 1;
        }

        if (!self.busy) {
            const cursor_row = input_top + (rendered_rows -| 1);
            const cursor_col: u16 = @intCast(@min(w - 1, prompt.len + last_line_text.len));
            win.showCursor(cursor_col, cursor_row);
        } else {
            win.hideCursor();
        }

        try self.vx.render(self.tty.writer());
    }

    /// Spawn the agent worker on its own task. Caller has already pushed
    /// the user prompt as a block and set `busy = true`. The shim and
    /// prompt are owned by gpa and freed when the turn cleans up.
    fn startTurn(self: *Tui, prompt: []u8) !void {
        const shim = try self.gpa.create(ShimSink);
        shim.* = .{ .gpa = self.gpa, .loop = self.loop };
        const future = Io.concurrent(self.io, agentWorker, .{ self.sess, prompt, shim }) catch |e| {
            self.gpa.destroy(shim);
            return e;
        };
        self.turn = .{
            .future = future,
            .shim = shim,
            .prompt = prompt,
            .started_at = Io.Clock.now(.awake, self.io),
        };
    }

    /// Run after we've received the worker's `a_done` event. Awaits the
    /// future (non-blocking — worker has already returned), frees the
    /// per-turn allocations, clears `busy`, and renders any trailing
    /// assistant text.
    fn finishTurn(self: *Tui) !void {
        if (self.turn) |*t| {
            _ = t.future.await(self.io);
            self.gpa.free(t.prompt);
            self.gpa.destroy(t.shim);
            self.turn = null;
        }
        self.busy = false;
        try self.flushOpenAssistant();
    }

    /// Cancel the in-flight turn (if any). Blocks briefly while the
    /// worker unwinds — Future.cancel sends a cancel signal that the
    /// next Cancelable IO call in the worker raises as
    /// `error.Canceled`. Also wakes any approval-gate waiter so
    /// `cond.wait` returns Canceled immediately.
    fn cancelTurn(self: *Tui) !void {
        if (self.turn) |*t| {
            _ = t.future.cancel(self.io);
            self.gpa.free(t.prompt);
            self.gpa.destroy(t.shim);
            self.turn = null;
        }
        self.awaiting_prompt_id = 0;
        self.busy = false;
        try self.flushOpenAssistant();
        // Drain any agent events the worker had already queued before
        // it noticed the cancel — those events own gpa-allocated
        // buffers we have to free, otherwise they leak.
        while (try self.loop.tryEvent()) |stale| freeAgentEvent(self.gpa, stale);
    }

    /// Append a turn-summary notice with token counts (and cost when
    /// the model is in our price table). Called when an `a_usage` event
    /// arrives from the worker.
    /// Paint the status row at `row`. Layout (best-effort, truncates
    /// gracefully on narrow terminals):
    ///
    ///     ⠋ claude-opus-4-7 · 12 in / 7 out · mcp:2          $0.0007
    ///     ^ spinner / ◆ idle    ^model               ^tokens     ^cost
    fn renderStatusLine(self: *Tui, gpa: std.mem.Allocator, win: vaxis.Window, row: u16, w: u16) !void {
        const spinner_glyphs = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        const head: []const u8 = if (self.busy)
            spinner_glyphs[self.spinner_tick % spinner_glyphs.len]
        else
            "◆";

        var left: std.ArrayList(u8) = .empty;
        try left.print(gpa, " {s} {s}", .{ head, self.model });
        const u = self.cumulative_usage;
        if (u.input_tokens != 0 or u.output_tokens != 0) {
            try left.print(gpa, " · {d} in / {d} out", .{ u.input_tokens, u.output_tokens });
        }
        if (self.mcp_count > 0) try left.print(gpa, " · mcp:{d}", .{self.mcp_count});

        var right: std.ArrayList(u8) = .empty;
        if (cost.turnCost(self.model, u)) |c| {
            if (c > 0) try right.print(gpa, "${d:.4} ", .{c});
        }

        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(gpa, left.items);
        const used = displayWidth(left.items) + displayWidth(right.items);
        if (used < w) try line.appendNTimes(gpa, ' ', w - used);
        try line.appendSlice(gpa, right.items);

        const fg: vaxis.Color = if (self.busy) .{ .index = 3 } else .{ .index = 8 };
        _ = win.print(&.{.{
            .text = line.items[0..@min(line.items.len, std.math.maxInt(u16))],
            .style = .{ .fg = fg, .bg = .{ .index = 0 } },
        }}, .{ .row_offset = row, .wrap = .none });
    }

    fn pushUsageNotice(self: *Tui, usage: provider_mod.Usage) !void {
        if (usage.input_tokens == 0 and usage.output_tokens == 0) return;
        self.cumulative_usage.input_tokens += usage.input_tokens;
        self.cumulative_usage.output_tokens += usage.output_tokens;
        self.cumulative_usage.cache_read_tokens += usage.cache_read_tokens;
        self.cumulative_usage.cache_creation_tokens += usage.cache_creation_tokens;
        var buf: std.ArrayList(u8) = .empty;
        try buf.print(self.arena, "[tokens: {d} in / {d} out", .{ usage.input_tokens, usage.output_tokens });
        if (usage.cache_read_tokens > 0 or usage.cache_creation_tokens > 0) {
            try buf.print(self.arena, " · cache {d} read / {d} write", .{ usage.cache_read_tokens, usage.cache_creation_tokens });
        }
        const this_turn_cost: ?f64 = cost.turnCost(self.model, usage);
        if (this_turn_cost) |c| {
            try buf.print(self.arena, " · ${d:.4}", .{c});
        }
        try buf.append(self.arena, ']');
        try self.pushBlock(.notice, buf.items);

        // Append to the persistent cost log (best-effort: a write
        // failure here mustn't break the turn, just like notify).
        const log_path = cost_log.logPath(self.arena, self.env_map) catch return;
        const entry: cost_log.Entry = .{
            .ts = std.Io.Clock.now(.real, self.io).toSeconds(),
            .model = self.model,
            .in = usage.input_tokens,
            .out = usage.output_tokens,
            .cache_read = usage.cache_read_tokens,
            .cache_write = usage.cache_creation_tokens,
            .cost_usd = this_turn_cost orelse 0,
        };
        cost_log.append(self.arena, self.io, log_path, entry) catch {};
    }
};

/// Approximate visible-column count for a UTF-8 string. Counts the
/// number of code points (bytes whose top two bits aren't `10`),
/// treating each as one column. Good enough for the status line where
/// we only render Latin + a handful of single-cell box-drawing /
/// braille glyphs — wide East-Asian + emoji would over-count, but we
/// don't render those here.
fn displayWidth(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        if ((b & 0xc0) != 0x80) n += 1;
    }
    return n;
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Position of the next word-start strictly after `from_col`.
fn nextWordStart(text: []const u8, from_col: u16) ?usize {
    var i: usize = from_col;
    if (i >= text.len) return null;
    // Skip the rest of the current word, then any non-word run.
    if (isWordChar(text[i])) {
        while (i < text.len and isWordChar(text[i])) i += 1;
    } else {
        i += 1;
    }
    while (i < text.len and !isWordChar(text[i])) i += 1;
    if (i >= text.len) return null;
    return i;
}

fn firstWordStart(text: []const u8) ?usize {
    var i: usize = 0;
    while (i < text.len and !isWordChar(text[i])) i += 1;
    return if (i >= text.len) null else i;
}

/// Position of the previous word-start strictly before `from_col`.
fn prevWordStart(text: []const u8, from_col: u16) ?usize {
    if (from_col == 0 or text.len == 0) return null;
    var i: usize = @min(from_col, text.len) - 1;
    while (true) {
        if (!isWordChar(text[i])) {
            if (i == 0) return null;
            i -= 1;
            continue;
        }
        // Walk to start of this word.
        while (i > 0 and isWordChar(text[i - 1])) i -= 1;
        // If that landed at our caller's position, keep going past.
        if (i + 1 > from_col) {
            // unreachable in normal flow — defensive guard
            return null;
        }
        return i;
    }
}

fn lastWordStart(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var i: usize = text.len - 1;
    // Skip trailing non-word chars.
    while (true) {
        if (isWordChar(text[i])) break;
        if (i == 0) return null;
        i -= 1;
    }
    while (i > 0 and isWordChar(text[i - 1])) i -= 1;
    return i;
}

/// Release any gpa allocations carried by an agent-posted Event.
/// Non-agent variants (key_press, mouse, winsize, a_usage, a_done) own
/// no heap memory.
fn freeAgentEvent(gpa: std.mem.Allocator, event: Event) void {
    switch (event) {
        .a_text => |text| gpa.free(text),
        .a_tool_call => |tc| {
            gpa.free(tc.name);
            gpa.free(tc.input);
        },
        .a_tool_result => |tr| gpa.free(tr.text),
        .a_approval => |a| {
            gpa.free(a.path);
            gpa.free(a.diff_text);
        },
        else => {},
    }
}

/// Approval-gate post hook. Called from the WORKER THREAD when a
/// write tool needs sign-off. We post an `a_approval` event onto
/// vaxis's loop and return immediately; the worker then blocks on
/// the gate's condition variable.
fn postApprovalEvent(ctx: ?*anyopaque, request: approval.Request) anyerror!void {
    const tui: *Tui = @ptrCast(@alignCast(ctx.?));
    try tui.loop.postEvent(.{ .a_approval = request });
}

/// Hand the contents of `tui.input` to the slash dispatcher, or to
/// the agent worker if it's not a slash command. Shared by the
/// Enter (single-line) path and the Ctrl-D (multi-line submit)
/// path. Returns `.exit` when the slash handler asked to leave the
/// REPL — the caller `return`s in that case.
fn submitInputBuffer(
    tui: *Tui,
    tui_arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
    tty: *vaxis.Tty,
    history_path: ?[]const u8,
) !slash.Action {
    if (tui.input.items.len == 0) return .handled;

    if (slash.parse(tui.input.items)) |parsed| {
        // Dupe name + args into the tui arena before clearing the
        // input buffer — `parsed` borrows slices of `tui.input.items`
        // and the next keystroke would overwrite them otherwise.
        const name_owned = try tui_arena.dupe(u8, parsed.name);
        const args_owned = try tui_arena.dupe(u8, parsed.args);
        tui.input.clearRetainingCapacity();

        var slash_ctx: SlashCtx = .{
            .tui = tui,
            .env_map = env_map,
            .tty_writer = tty.writer(),
        };
        if (slash_registry.find(name_owned)) |cmd| {
            const action = cmd.handler(@ptrCast(&slash_ctx), args_owned) catch |err| blk: {
                const msg = try std.fmt.allocPrint(tui_arena, "/{s} failed: {s}", .{ name_owned, @errorName(err) });
                try tui.pushBlock(.tool_result_error, msg);
                break :blk slash.Action.handled;
            };
            try tui.render();
            return action;
        }
        const msg = try std.fmt.allocPrint(tui_arena, "unknown command: /{s} (try /help)", .{name_owned});
        try tui.pushBlock(.tool_result_error, msg);
        try tui.render();
        return .handled;
    }

    // History keeps the literal text the user typed (with the
    // `@mention` syntax intact) so Up/Down recall stays clean.
    // The worker sees an expanded prompt with each `@path`'s
    // contents prepended in an `<attachments>` block — which the
    // session's persisted messages then capture as the user turn.
    const prompt_for_history = try tui_arena.dupe(u8, tui.input.items);
    tui.last_prompt = prompt_for_history; // remembered for auto-commit
    const expanded = try mentions.expand(tui_arena, io, prompt_for_history, false);
    const prompt_for_worker = try gpa.dupe(u8, expanded);
    try tui.input_history.append(tui_arena, prompt_for_history);
    tui.history_idx = null;
    if (history_path) |path| persist.appendHistory(tui_arena, io, path, prompt_for_history) catch {};
    try tui.pushBlock(.user_prompt, prompt_for_history);
    if (expanded.len != prompt_for_history.len) {
        const note = try std.fmt.allocPrint(
            tui_arena,
            "(attached {d} byte(s) of @-referenced file context)",
            .{expanded.len - prompt_for_history.len},
        );
        try tui.pushBlock(.notice, note);
    }
    tui.input.clearRetainingCapacity();
    tui.busy = true;
    try tui.render();

    tui.startTurn(prompt_for_worker) catch |err| {
        gpa.free(prompt_for_worker);
        const msg = try std.fmt.allocPrint(tui_arena, "error spawning agent: {s}", .{@errorName(err)});
        try tui.pushBlock(.tool_result_error, msg);
        tui.busy = false;
        try tui.render();
    };
    return .handled;
}

fn styleFor(kind: Block.Kind) vaxis.Cell.Style {
    return switch (kind) {
        .user_prompt => .{ .fg = .{ .index = 6 }, .bold = true },
        .assistant_text => .{},
        .tool_call => .{ .fg = .{ .index = 3 } },
        .tool_result => .{ .fg = .{ .index = 8 } },
        .tool_result_error => .{ .fg = .{ .index = 1 } },
        .notice => .{ .fg = .{ .index = 8 }, .italic = true },
        // Diff body — per-line colour is applied by `styleForDiffLine`,
        // not by the block-level base. The fallback dim grey here is
        // used only for the `--- a/...` / `+++ b/...` headers.
        .diff => .{ .fg = .{ .index = 8 } },
        .approval_prompt => .{ .fg = .{ .index = 4 }, .bold = true },
        .code_block => .{ .fg = .{ .index = 6 } },
    };
}

/// Format a fenced code block as a styled text payload. The header
/// shows the language tag (or `code` when the fence had no info
/// string); body is verbatim. Trailing rule line bookends the block
/// visually.
fn formatCodeBlock(arena: std.mem.Allocator, c: markdown.CodeBlock) ![]const u8 {
    const lang_label: []const u8 = if (c.language.len > 0) c.language else "code";
    return std.fmt.allocPrint(arena, "─── {s} ───\n{s}\n─────────────", .{ lang_label, c.body });
}

/// Per-row colour for diff text. Looks at the leading char to colour
/// adds green, removes red, hunk headers magenta, file headers grey.
fn styleForDiffLine(text: []const u8) vaxis.Cell.Style {
    if (text.len == 0) return .{};
    return switch (text[0]) {
        '+' => .{ .fg = .{ .index = 2 } }, // green
        '-' => .{ .fg = .{ .index = 1 } }, // red
        '@' => .{ .fg = .{ .index = 5 }, .bold = true }, // magenta hunk header
        else => .{ .fg = .{ .index = 8 } }, // grey context / file headers
    };
}

fn wrapBlockInto(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderedLine),
    block: Block,
    width: u16,
) !void {
    if (block.collapsed and block.isCollapsible()) {
        const summary = try collapseSummary(arena, block);
        try out.append(arena, .{ .kind = block.kind, .text = summary, .block_id = block.id });
        return;
    }
    if (block.text.len == 0) {
        try out.append(arena, .{ .kind = block.kind, .text = "", .block_id = block.id });
        return;
    }
    var rest = block.text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_end = nl orelse rest.len;
        var line = rest[0..line_end];
        while (line.len > width) {
            try out.append(arena, .{ .kind = block.kind, .text = line[0..width], .block_id = block.id });
            line = line[width..];
        }
        try out.append(arena, .{ .kind = block.kind, .text = line, .block_id = block.id });
        rest = if (nl) |n| rest[n + 1 ..] else rest[line_end..];
    }
}

/// Build a one-line summary for a collapsed tool block. Format:
///   "→ <head> [N lines, Tab to expand]"   (tool_call)
///   "← <head> [N lines, Tab to expand]"   (tool_result / tool_result_error)
/// `head` is the first line of the block's text, truncated to ~80 cols.
fn collapseSummary(arena: std.mem.Allocator, block: Block) ![]const u8 {
    const total = naturalLineCount(block.text);
    const first_nl = std.mem.indexOfScalar(u8, block.text, '\n') orelse block.text.len;
    var head = block.text[0..first_nl];
    // Strip the kind-specific arrow prefix from the head if present —
    // we re-add it below, formatted for the summary.
    const arrow_call: []const u8 = "→ ";
    const arrow_res: []const u8 = "← ";
    const arrow_err: []const u8 = "← (error) ";
    if (block.kind == .tool_call and std.mem.startsWith(u8, head, arrow_call)) {
        head = head[arrow_call.len..];
    } else if (block.kind == .tool_result and std.mem.startsWith(u8, head, arrow_res)) {
        head = head[arrow_res.len..];
    } else if (block.kind == .tool_result_error and std.mem.startsWith(u8, head, arrow_err)) {
        head = head[arrow_err.len..];
    } else if (block.kind == .tool_result_error and std.mem.startsWith(u8, head, arrow_res)) {
        head = head[arrow_res.len..];
    }
    if (head.len > 80) head = head[0..80];

    const arrow: []const u8 = switch (block.kind) {
        .tool_call => "→ ",
        .tool_result => "← ",
        .tool_result_error => "← (error) ",
        else => "",
    };
    return std.fmt.allocPrint(arena, "{s}{s} [{d} lines, Tab to expand]", .{ arrow, head, total });
}

/// Count the natural newline-terminated rows in `text`. A trailing
/// non-newline run counts as one extra row.
fn naturalLineCount(text: []const u8) usize {
    if (text.len == 0) return 1;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') n += 1;
    }
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

fn selectionOverlapsLine(sel: Selection, line: usize) bool {
    const n = sel.normalized();
    return line >= n.start.line and line <= n.end.line;
}

/// Render a single assistant-text line with inline markdown styling.
/// Tokenises into spans, merges each span's bold/italic/code with the
/// base style, and emits one vaxis cell segment per span. Each segment
/// is placed at the running column offset (we count UTF-8 code points,
/// matching `displayWidth`).
fn renderMarkdownLine(
    arena: std.mem.Allocator,
    win: vaxis.Window,
    row: u16,
    text: []const u8,
    base: vaxis.Cell.Style,
) !void {
    const spans = try markdown.tokenize(arena, text);
    var col: u16 = 0;
    for (spans) |span| {
        var style = base;
        if (span.bold) style.bold = true;
        if (span.italic) style.italic = true;
        if (span.code) {
            // Cyan-ish accent so code spans stand out from prose
            // without looking like an error highlight.
            style.fg = .{ .index = 6 };
        }
        _ = win.print(&.{.{ .text = span.text, .style = style }}, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
        col +|= @intCast(displayWidth(span.text));
    }
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

// ─── slash commands ──────────────────────────────────────────────

/// Context passed to every slash handler. Lives on the stack of `run()`
/// for the lifetime of the TUI loop.
const SlashCtx = struct {
    tui: *Tui,
    env_map: *std.process.Environ.Map,
    /// `null` until we know how to surface non-OSC-52 clipboards. For
    /// now /copy uses the same OSC-52 escape as mouse-copy.
    tty_writer: *Io.Writer,
};

fn slashCtx(ctx: *anyopaque) *SlashCtx {
    return @ptrCast(@alignCast(ctx));
}

fn slashHelp(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(c.tui.arena, "Available commands:\n");
    for (slash_registry.commands) |cmd| {
        try buf.print(c.tui.arena, "  /{s:<10} {s}\n", .{ cmd.name, cmd.description });
    }
    // Drop the trailing newline so the block doesn't render an empty row.
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') _ = buf.pop();
    try c.tui.pushBlock(.notice, buf.items);
    return .handled;
}

fn slashClear(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    c.tui.sess.messages.clearRetainingCapacity();
    c.tui.blocks.clearRetainingCapacity();
    c.tui.assistant_buf.clearRetainingCapacity();
    c.tui.has_open_assistant = false;
    c.tui.cumulative_usage = .{};
    c.tui.scroll_offset = 0;
    try c.tui.pushBlock(.notice, "Cleared scrollback and conversation history.");
    return .handled;
}

fn slashExit(_: *anyopaque, _: []const u8) anyerror!slash.Action {
    return .exit;
}

fn slashCost(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    var buf: std.ArrayList(u8) = .empty;

    // In-session totals first.
    const u = c.tui.cumulative_usage;
    if (u.input_tokens == 0 and u.output_tokens == 0) {
        try buf.appendSlice(c.tui.arena, "Session totals · (no turns yet)\n");
    } else {
        try buf.print(c.tui.arena, "Session totals · {d} in / {d} out", .{ u.input_tokens, u.output_tokens });
        if (u.cache_read_tokens > 0 or u.cache_creation_tokens > 0) {
            try buf.print(c.tui.arena, " · cache {d} read / {d} write", .{ u.cache_read_tokens, u.cache_creation_tokens });
        }
        if (cost.turnCost(c.tui.model, u)) |total| {
            try buf.print(c.tui.arena, " · ${d:.4}", .{total});
        }
        try buf.append(c.tui.arena, '\n');
    }

    // Rolling totals from the persistent log.
    const log_path = cost_log.logPath(c.tui.arena, c.env_map) catch null;
    if (log_path) |p| {
        const entries = cost_log.readAll(c.tui.arena, c.tui.io, p) catch &[_]cost_log.Entry{};
        const now = std.Io.Clock.now(.real, c.tui.io).toSeconds();
        const today = cost_log.aggregate(entries, .today, now);
        const week = cost_log.aggregate(entries, .week, now);
        const month = cost_log.aggregate(entries, .month, now);
        const all = cost_log.aggregate(entries, .all, now);
        try buf.print(c.tui.arena,
            "Today  · {d} turn(s) · ${d:.4}\nWeek   · {d} turn(s) · ${d:.4}\nMonth  · {d} turn(s) · ${d:.4}\nAll    · {d} turn(s) · ${d:.4}",
            .{
                today.turns, today.cost_usd,
                week.turns,  week.cost_usd,
                month.turns, month.cost_usd,
                all.turns,   all.cost_usd,
            },
        );
    }

    try c.tui.pushBlock(.notice, buf.items);
    return .handled;
}

/// Find the most recent assistant text — either an unflushed in-flight
/// buffer (during a turn) or the last `.assistant_text` block.
fn lastAssistantText(tui: *Tui) ?[]const u8 {
    if (tui.has_open_assistant and tui.assistant_buf.items.len > 0) return tui.assistant_buf.items;
    var i = tui.blocks.items.len;
    while (i > 0) {
        i -= 1;
        if (tui.blocks.items[i].kind == .assistant_text) return tui.blocks.items[i].text;
    }
    return null;
}

fn slashCopy(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    const text = lastAssistantText(c.tui) orelse {
        try c.tui.pushBlock(.notice, "Nothing to copy — no assistant message yet.");
        return .handled;
    };
    copyToClipboard(c.tui.arena, c.tty_writer, text) catch |err| {
        const msg = try std.fmt.allocPrint(c.tui.arena, "/copy failed: {s}", .{@errorName(err)});
        try c.tui.pushBlock(.tool_result_error, msg);
        return .handled;
    };
    const msg = try std.fmt.allocPrint(c.tui.arena, "Copied {d} bytes to clipboard.", .{text.len});
    try c.tui.pushBlock(.notice, msg);
    return .handled;
}

fn slashModel(ctx: *anyopaque, args: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    if (args.len == 0) {
        const msg = try std.fmt.allocPrint(c.tui.arena, "Current model: {s}\nUsage: /model <id>", .{c.tui.model});
        try c.tui.pushBlock(.notice, msg);
        return .handled;
    }
    const owned = try c.tui.arena.dupe(u8, args);
    c.tui.model = owned;
    c.tui.sess.config.model = owned;
    const msg = try std.fmt.allocPrint(c.tui.arena, "Model set to {s}.", .{owned});
    try c.tui.pushBlock(.notice, msg);
    return .handled;
}

fn slashSystem(ctx: *anyopaque, args: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    if (args.len == 0) {
        const cur = c.tui.sess.config.system orelse "(none)";
        const msg = try std.fmt.allocPrint(c.tui.arena, "System prompt: {s}\nUsage: /system <text> (or /system clear)", .{cur});
        try c.tui.pushBlock(.notice, msg);
        return .handled;
    }
    if (std.mem.eql(u8, args, "clear")) {
        c.tui.sess.config.system = null;
        try c.tui.pushBlock(.notice, "System prompt cleared.");
        return .handled;
    }
    // Strip a single pair of surrounding quotes so /system "be terse"
    // doesn't store the quotes literally.
    var text = args;
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or
        (text[0] == '\'' and text[text.len - 1] == '\'')))
    {
        text = text[1 .. text.len - 1];
    }
    const owned = try c.tui.arena.dupe(u8, text);
    c.tui.sess.config.system = owned;
    try c.tui.pushBlock(.notice, "System prompt updated.");
    return .handled;
}

fn slashSave(ctx: *anyopaque, args: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    var path: ?[]const u8 = c.tui.sess.save_path;
    if (args.len > 0) {
        path = persist.sessionPath(c.tui.arena, c.env_map, args) catch |err| {
            const msg = try std.fmt.allocPrint(c.tui.arena, "/save: bad name '{s}': {s}", .{ args, @errorName(err) });
            try c.tui.pushBlock(.tool_result_error, msg);
            return .handled;
        };
    }
    const target = path orelse {
        try c.tui.pushBlock(.notice, "Usage: /save <name>  (or launch with --session <name> to set a default)");
        return .handled;
    };
    persist.save(c.tui.arena, c.tui.io, target, c.tui.sess.messages.items) catch |err| {
        const msg = try std.fmt.allocPrint(c.tui.arena, "/save failed: {s}", .{@errorName(err)});
        try c.tui.pushBlock(.tool_result_error, msg);
        return .handled;
    };
    // Promote the path to be the implicit autosave target for the rest
    // of this session.
    c.tui.sess.save_path = target;
    const msg = try std.fmt.allocPrint(c.tui.arena, "Saved {d} message(s) → {s}", .{ c.tui.sess.messages.items.len, target });
    try c.tui.pushBlock(.notice, msg);
    return .handled;
}

fn slashLoad(ctx: *anyopaque, args: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    if (args.len == 0) {
        try c.tui.pushBlock(.notice, "Usage: /load <name>");
        return .handled;
    }
    const path = persist.sessionPath(c.tui.arena, c.env_map, args) catch |err| {
        const msg = try std.fmt.allocPrint(c.tui.arena, "/load: bad name '{s}': {s}", .{ args, @errorName(err) });
        try c.tui.pushBlock(.tool_result_error, msg);
        return .handled;
    };
    const loaded = persist.load(c.tui.arena, c.tui.io, path) catch |err| {
        const msg = try std.fmt.allocPrint(c.tui.arena, "/load failed: {s}", .{@errorName(err)});
        try c.tui.pushBlock(.tool_result_error, msg);
        return .handled;
    };
    const msgs = loaded orelse {
        const msg = try std.fmt.allocPrint(c.tui.arena, "/load: no session named '{s}'", .{args});
        try c.tui.pushBlock(.tool_result_error, msg);
        return .handled;
    };
    c.tui.sess.messages.clearRetainingCapacity();
    try c.tui.sess.messages.appendSlice(c.tui.arena, msgs);
    c.tui.blocks.clearRetainingCapacity();
    c.tui.assistant_buf.clearRetainingCapacity();
    c.tui.has_open_assistant = false;
    c.tui.scroll_offset = 0;
    c.tui.sess.save_path = path;
    const msg = try std.fmt.allocPrint(c.tui.arena, "Loaded session '{s}' ({d} message(s)).", .{ args, msgs.len });
    try c.tui.pushBlock(.notice, msg);
    return .handled;
}

/// Sink used by /compact to harvest the model's summary text.
const CompactSink = struct {
    text: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    fn cb(ctx: ?*anyopaque, t: []const u8) anyerror!void {
        const self: *CompactSink = @ptrCast(@alignCast(ctx.?));
        try self.text.appendSlice(self.arena, t);
    }
    fn noop(_: ?*anyopaque, _: provider_mod.ToolUse) anyerror!void {}
    fn noopUsage(_: ?*anyopaque, _: provider_mod.Usage) anyerror!void {}
    fn noopStop(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

const compact_prompt: []const u8 =
    "Please summarize the conversation so far in 3-6 sentences. " ++
    "Capture the user's goal, key decisions, files touched, " ++
    "and any open questions. Be concrete, no preamble.";

const init_prompt: []const u8 =
    "Generate a concise VELK.md for this project so future agents " ++
    "have project context on launch. Inspect the repo with `ls`, " ++
    "`grep`, and `read_file` first. Pull out:\n" ++
    "  - Toolchain version + how to build / test / lint\n" ++
    "  - Top-level layout (one line per dir, what lives there)\n" ++
    "  - Non-obvious conventions and gotchas (memory invariants, " ++
    "thread boundaries, anything that's bit a reader before)\n" ++
    "  - Out-of-scope explicitly listed\n\n" ++
    "Skip what's already obvious from a `cat` of the source — " ++
    "VELK.md is for what isn't. Aim for under 80 lines. Once the " ++
    "draft is ready, write it to ./VELK.md via the write_file tool.";

fn slashInit(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    if (c.tui.turn != null) {
        try c.tui.pushBlock(.notice, "/init: a turn is in flight — wait for it to finish.");
        return .handled;
    }
    // Hand off to the regular turn machinery: pushes the canned
    // prompt as a user message and starts the agent worker. The
    // worker can call read_file / ls / grep freely; write_file
    // goes through the existing diff-approval flow.
    const prompt_for_history = try c.tui.arena.dupe(u8, init_prompt);
    const prompt_for_worker = try c.tui.gpa.dupe(u8, init_prompt);
    try c.tui.pushBlock(.user_prompt, "/init — generating VELK.md");
    c.tui.busy = true;
    c.tui.startTurn(prompt_for_worker) catch |err| {
        c.tui.gpa.free(prompt_for_worker);
        const msg = try std.fmt.allocPrint(c.tui.arena, "/init: spawn failed: {s}", .{@errorName(err)});
        try c.tui.pushBlock(.tool_result_error, msg);
        c.tui.busy = false;
        return .handled;
    };
    // Append to input history so /init shows up under Up-arrow if
    // the user wants to retry / tweak.
    try c.tui.input_history.append(c.tui.arena, prompt_for_history);
    c.tui.history_idx = null;
    return .handled;
}

fn slashCompact(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    if (c.tui.sess.messages.items.len == 0) {
        try c.tui.pushBlock(.notice, "/compact: no messages to summarize yet.");
        return .handled;
    }
    if (c.tui.turn != null) {
        try c.tui.pushBlock(.notice, "/compact: a turn is in flight — wait for it to finish.");
        return .handled;
    }

    try c.tui.pushBlock(.notice, "/compact: summarizing… (UI is paused for the duration of the call)");
    try c.tui.render();

    // Synchronous call on the main thread for v1. Future work: move
    // to a worker so the spinner keeps animating + Ctrl-C cancels.
    var harvest: CompactSink = .{ .arena = c.tui.arena };

    // Build a request that's the existing history + a synthetic user
    // turn asking for the summary. We deliberately don't pass tools
    // — the summary should be plain text.
    var msgs: std.ArrayList(provider_mod.Message) = .empty;
    try msgs.appendSlice(c.tui.arena, c.tui.sess.messages.items);
    try msgs.append(c.tui.arena, try provider_mod.textMessage(c.tui.arena, .user, compact_prompt));

    const req: provider_mod.Request = .{
        .model = c.tui.model,
        .max_tokens = c.tui.sess.config.max_tokens,
        .system = c.tui.sess.config.system,
        .messages = msgs.items,
        .tools = &.{},
    };

    c.tui.sess.provider.stream(req, .{
        .ctx = &harvest,
        .onText = CompactSink.cb,
        .onToolUse = CompactSink.noop,
        .onUsage = CompactSink.noopUsage,
        .onStop = CompactSink.noopStop,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(c.tui.arena, "/compact failed: {s}", .{@errorName(err)});
        try c.tui.pushBlock(.tool_result_error, msg);
        return .handled;
    };

    if (harvest.text.items.len == 0) {
        try c.tui.pushBlock(.tool_result_error, "/compact: model returned an empty summary.");
        return .handled;
    }

    // Replace history with a single user message containing the
    // summary, prefixed so future turns can tell it's compacted
    // context (not a real user turn). The next /save / autosave
    // captures the new shorter history.
    const summary_owned = try c.tui.arena.dupe(u8, harvest.text.items);
    const synthetic = try std.fmt.allocPrint(
        c.tui.arena,
        "(Previous conversation summary)\n{s}",
        .{summary_owned},
    );
    c.tui.sess.messages.clearRetainingCapacity();
    try c.tui.sess.messages.append(
        c.tui.arena,
        try provider_mod.textMessage(c.tui.arena, .user, synthetic),
    );

    const notice = try std.fmt.allocPrint(
        c.tui.arena,
        "/compact: replaced history with a {d}-char summary.\n\n{s}",
        .{ summary_owned.len, summary_owned },
    );
    try c.tui.pushBlock(.notice, notice);
    return .handled;
}

fn slashDoctor(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(c.tui.arena, "velk diagnostics\n");

    // Env-key presence (we never print the value).
    const keys = [_][]const u8{ "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY" };
    for (keys) |k| {
        const set = c.env_map.get(k) != null;
        const marker: []const u8 = if (set) "✓" else "·";
        try buf.print(c.tui.arena, "  {s} {s}\n", .{ marker, k });
    }

    // Active model + MCP count.
    try buf.print(c.tui.arena, "  · model: {s}\n", .{c.tui.model});
    try buf.print(c.tui.arena, "  · mcp servers attached: {d}\n", .{c.tui.mcp_count});

    // Saved-session count.
    const sessions = persist.listSessions(c.tui.arena, c.tui.io, c.env_map) catch &[_]persist.SessionMeta{};
    try buf.print(c.tui.arena, "  · saved sessions: {d}\n", .{sessions.len});

    // Cost-log size.
    if (cost_log.logPath(c.tui.arena, c.env_map)) |p| {
        const entries = cost_log.readAll(c.tui.arena, c.tui.io, p) catch &[_]cost_log.Entry{};
        try buf.print(c.tui.arena, "  · cost-log entries: {d}", .{entries.len});
    } else |_| {
        try buf.appendSlice(c.tui.arena, "  · cost-log: HOME unset");
    }

    try c.tui.pushBlock(.notice, buf.items);
    return .handled;
}

fn slashResume(ctx: *anyopaque, args: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    if (args.len == 0) {
        const sessions = persist.listSessions(c.tui.arena, c.tui.io, c.env_map) catch |err| {
            const msg = try std.fmt.allocPrint(c.tui.arena, "/resume: {s}", .{@errorName(err)});
            try c.tui.pushBlock(.tool_result_error, msg);
            return .handled;
        };
        if (sessions.len == 0) {
            try c.tui.pushBlock(.notice, "No saved sessions found. Start one with /save <name>.");
            return .handled;
        }
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(c.tui.arena, "Saved sessions (newest first):\n");
        const limit = @min(sessions.len, 10);
        for (sessions[0..limit]) |s| {
            try buf.print(c.tui.arena, "  /resume {s}    ({d} bytes)\n", .{ s.name, s.size_bytes });
        }
        if (sessions.len > limit) {
            try buf.print(c.tui.arena, "  … and {d} more.", .{sessions.len - limit});
        } else if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
            _ = buf.pop();
        }
        try c.tui.pushBlock(.notice, buf.items);
        return .handled;
    }
    // Loading by name reuses /load's exact logic.
    return slashLoad(ctx, args);
}

fn slashMultiline(ctx: *anyopaque, _: []const u8) anyerror!slash.Action {
    const c = slashCtx(ctx);
    c.tui.multiline = !c.tui.multiline;
    const msg: []const u8 = if (c.tui.multiline)
        "Multi-line mode ON — Enter inserts a newline, Ctrl-D submits."
    else
        "Multi-line mode OFF — Enter submits.";
    try c.tui.pushBlock(.notice, msg);
    return .handled;
}

const slash_commands = [_]slash.Command{
    .{ .name = "help", .description = "list available commands", .handler = slashHelp },
    .{ .name = "clear", .description = "clear scrollback and conversation history", .handler = slashClear },
    .{ .name = "exit", .description = "leave the REPL", .handler = slashExit },
    .{ .name = "quit", .description = "alias for /exit", .handler = slashExit },
    .{ .name = "cost", .description = "show cumulative tokens + USD for this session", .handler = slashCost },
    .{ .name = "copy", .description = "copy the last assistant message to the clipboard", .handler = slashCopy },
    .{ .name = "model", .description = "show or change the active model id", .handler = slashModel },
    .{ .name = "system", .description = "show or set the system prompt (use 'clear' to drop it)", .handler = slashSystem },
    .{ .name = "save", .description = "persist the current session to disk", .handler = slashSave },
    .{ .name = "load", .description = "replace the current session with a saved one", .handler = slashLoad },
    .{ .name = "resume", .description = "list saved sessions or resume one by name", .handler = slashResume },
    .{ .name = "doctor", .description = "show env / session / cost-log diagnostics", .handler = slashDoctor },
    .{ .name = "compact", .description = "summarize the conversation so far and replace history with the summary", .handler = slashCompact },
    .{ .name = "init", .description = "generate a VELK.md tailored to this repo (uses tools + write_file)", .handler = slashInit },
    .{ .name = "multiline", .description = "toggle multi-line input (Enter inserts newline, Ctrl-D submits)", .handler = slashMultiline },
};

const slash_registry: slash.Registry = .{ .commands = &slash_commands };

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
    mcp_count: u8,
    approval_gate: *approval.ApprovalGate,
    auto_commit: bool,
) !void {
    // Dedicated arena for TUI-state allocations (blocks, history,
    // input buffer). Separate from `arena` (which the agent worker
    // shares via session.arena) so the two threads never touch the
    // same allocator.
    var tui_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer tui_arena_state.deinit();
    const tui_arena = tui_arena_state.allocator();

    var lines_arena: std.heap.ArenaAllocator = .init(gpa);
    defer lines_arena.deinit();

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

    var tui: Tui = .{
        .arena = tui_arena,
        .gpa = gpa,
        .io = io,
        .vx = &vx,
        .tty = &tty,
        .loop = &loop,
        .sess = sess,
        .model = model,
        .mcp_count = mcp_count,
        .env_map = env_map,
        .lines_arena = &lines_arena,
        .approval_gate = approval_gate,
        .auto_commit = auto_commit,
    };
    // Wire the gate's event-poster so worker-side approval requests
    // surface as `a_approval` events on the main thread.
    approval_gate.post_fn = postApprovalEvent;
    approval_gate.post_ctx = &tui;
    defer tui.cancelTurn() catch {}; // ensure worker is awaited if user exits mid-turn

    // Hydrate input history from disk so up-arrow recall works across
    // launches. Failures are non-fatal — first run, no XDG_STATE_HOME,
    // etc — we just skip persistence and run with an empty history.
    const history_path = persist.historyPath(arena, env_map) catch null;
    if (history_path) |path| {
        if (persist.loadHistory(tui_arena, io, path)) |hist| {
            try tui.input_history.appendSlice(tui_arena, hist);
        } else |_| {}
    }

    try tui.pushBlock(
        .notice,
        "velk REPL — Ctrl-D exit · Ctrl-C abort/cancel · Esc → normal (hjkl, w/b words, 0/$/I/A line, g/G top/bot, Ctrl-u/d page, v/V visual, y yank, i/a insert, q quit) · Enter send",
    );
    // Crash-recovery v1: when launched without --session and at
    // least one saved session exists, point the user at /resume so
    // a forgotten previous session is one keystroke away.
    if (sess.save_path == null) {
        const sessions = persist.listSessions(tui_arena, io, env_map) catch &[_]persist.SessionMeta{};
        if (sessions.len > 0) {
            const recent = sessions[0];
            const msg = try std.fmt.allocPrint(
                tui_arena,
                "Tip: {d} saved session(s). Most recent: '{s}'. Type /resume to list, /resume {s} to load.",
                .{ sessions.len, recent.name, recent.name },
            );
            try tui.pushBlock(.notice, msg);
        }
    }
    try tui.render();

    while (true) {
        // Poll for an event. When idle, drive autoscroll at ~25 Hz so
        // holding the mouse at the edge scrolls continuously.
        const maybe_event: ?Event = try loop.tryEvent();
        const event = maybe_event orelse {
            // Spinner tick: when a turn is in flight, advance the
            // status-line spinner ~every 100ms so it visibly animates
            // even when no events are arriving.
            if (tui.busy) {
                tui.spinner_tick +%= 1;
                // Idle sleep is 50ms; render every 2nd idle tick.
                if (tui.spinner_tick % 2 == 0) try tui.render();
            }
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
                            // Per-call scratch arena: the selection text
                            // lives just long enough to base64-encode and
                            // ship to the clipboard.
                            var sa: std.heap.ArenaAllocator = .init(gpa);
                            defer sa.deinit();
                            const text = try extractSelection(sa.allocator(), tui.all_lines, tui.selection);
                            if (text.len > 0) try copyToClipboard(sa.allocator(), tty.writer(), text);
                        } else {
                            tui.selection.active = false;
                            try tui.render();
                        }
                    },
                    .motion => {},
                }
            },
            .key_press => |key| {
                // Approval prompt has highest precedence — while a
                // diff is awaiting decision, swallow keystrokes and
                // route to the gate. Ctrl-C is handled below as a
                // turn-abort, which also unblocks the worker via
                // cancelTurn (Future.cancel raises Canceled out of
                // gate.cond.wait).
                if (tui.awaiting_prompt_id != 0) {
                    if (key.matches('c', .{ .ctrl = true })) {
                        // Falls through to the Ctrl-C handler below
                        // which cancels the turn.
                    } else if (key.matches('a', .{}) or key.matches(vaxis.Key.enter, .{})) {
                        approval_gate.deliver(.apply);
                        try tui.consumeApprovalPrompt(.apply);
                        try tui.render();
                        continue;
                    } else if (key.matches('s', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        approval_gate.deliver(.skip);
                        try tui.consumeApprovalPrompt(.skip);
                        try tui.render();
                        continue;
                    } else if (key.matches('A', .{ .shift = true })) {
                        approval_gate.deliver(.always_apply);
                        try tui.consumeApprovalPrompt(.always_apply);
                        try tui.render();
                        continue;
                    } else {
                        // Ignore other keys while waiting for approval.
                        continue;
                    }
                }
                // Ctrl-D in insert mode: submits the buffered input
                // when in multi-line mode; otherwise exits the REPL.
                // In normal/visual it's repurposed as a vim-style
                // half-page jump (handled further down).
                if (key.matches('d', .{ .ctrl = true }) and tui.mode == .insert) {
                    if (!tui.multiline) return;
                    if (tui.input.items.len == 0) continue;
                    if ((try submitInputBuffer(
                        &tui,
                        tui_arena,
                        gpa,
                        io,
                        env_map,
                        &tty,
                        history_path,
                    )) == .exit) return;
                    continue;
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    // Order of precedence: abort in-flight turn → clear
                    // selection → clear input → exit on empty.
                    if (tui.turn != null) {
                        try tui.cancelTurn();
                        try tui.pushBlock(.notice, "[aborted]");
                        try tui.render();
                        continue;
                    }
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

                // ── Vim-mode toggle, normal & visual navigation ──
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (tui.mode == .insert) {
                        tui.mode = .normal;
                        // Plant cursor at the bottom-most line so j/k
                        // immediately make sense.
                        if (tui.all_lines.len > 0) {
                            tui.nav_cursor = .{ .line = tui.all_lines.len - 1, .col = 0 };
                        }
                        try tui.render();
                    } else if (tui.mode == .visual or tui.mode == .visual_line) {
                        tui.mode = .normal;
                        tui.selection.active = false;
                        try tui.render();
                    }
                    continue;
                }
                if (tui.mode == .normal or tui.mode == .visual or tui.mode == .visual_line) {
                    // Mode switches first.
                    if (tui.mode == .normal and (key.matches('i', .{}) or key.matches('a', .{}))) {
                        tui.mode = .insert;
                        try tui.render();
                        continue;
                    }
                    // Shift-I / Shift-A: jump the nav cursor to start
                    // / end of the current scrollback line. (Pure
                    // navigation — no mode switch.)
                    if (tui.mode == .normal and key.matches('I', .{ .shift = true })) {
                        tui.nav_cursor.col = 0;
                        try tui.render();
                        continue;
                    }
                    if (tui.mode == .normal and key.matches('A', .{ .shift = true })) {
                        const len = tui.lineLen(tui.nav_cursor.line);
                        tui.nav_cursor.col = if (len == 0) 0 else @intCast(len - 1);
                        try tui.render();
                        continue;
                    }
                    if (tui.mode == .normal and key.matches('v', .{})) {
                        tui.mode = .visual;
                        tui.selection = .{
                            .anchor = tui.nav_cursor,
                            .cursor = tui.nav_cursor,
                            .active = true,
                        };
                        try tui.render();
                        continue;
                    }
                    // Shift-V toggles visual_line; pressing it again
                    // returns to normal.
                    if (key.matches('V', .{ .shift = true })) {
                        if (tui.mode == .visual_line) {
                            tui.mode = .normal;
                            tui.selection.active = false;
                        } else {
                            tui.mode = .visual_line;
                            tui.visual_line_anchor = tui.nav_cursor.line;
                            tui.syncVisualLineSelection();
                        }
                        try tui.render();
                        continue;
                    }
                    if ((tui.mode == .visual or tui.mode == .visual_line) and key.matches('y', .{})) {
                        var sa: std.heap.ArenaAllocator = .init(gpa);
                        defer sa.deinit();
                        const text = try extractSelection(sa.allocator(), tui.all_lines, tui.selection);
                        if (text.len > 0) try copyToClipboard(sa.allocator(), tty.writer(), text);
                        tui.mode = .normal;
                        tui.selection.active = false;
                        try tui.pushBlock(.notice, "[yanked to clipboard]");
                        try tui.render();
                        continue;
                    }
                    if (tui.mode == .normal and key.matches('q', .{})) return;

                    // Tab in normal mode toggles the collapsed state
                    // of the tool block under the cursor. No-op for
                    // non-collapsible blocks (assistant text, notice,
                    // user_prompt).
                    if (tui.mode == .normal and key.matches(vaxis.Key.tab, .{})) {
                        if (tui.toggleCollapseAtCursor()) try tui.render();
                        continue;
                    }

                    // Movement — applied to nav_cursor; in visual mode
                    // we mirror it onto the selection cursor too.
                    var moved = false;
                    if (key.matches('h', .{})) {
                        if (tui.nav_cursor.col > 0) tui.nav_cursor.col -= 1;
                        moved = true;
                    } else if (key.matches('l', .{})) {
                        const len = tui.lineLen(tui.nav_cursor.line);
                        if (len > 0 and tui.nav_cursor.col + 1 < len) tui.nav_cursor.col += 1;
                        moved = true;
                    } else if (key.matches('j', .{})) {
                        if (tui.nav_cursor.line + 1 < tui.all_lines.len) tui.nav_cursor.line += 1;
                        tui.clampNavCol();
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('k', .{})) {
                        if (tui.nav_cursor.line > 0) tui.nav_cursor.line -= 1;
                        tui.clampNavCol();
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('0', .{})) {
                        tui.nav_cursor.col = 0;
                        moved = true;
                    } else if (key.matches('$', .{ .shift = true })) {
                        const len = tui.lineLen(tui.nav_cursor.line);
                        tui.nav_cursor.col = if (len == 0) 0 else @intCast(len - 1);
                        moved = true;
                    } else if (key.matches('g', .{})) {
                        tui.nav_cursor = .{ .line = 0, .col = 0 };
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('G', .{ .shift = true })) {
                        tui.nav_cursor = .{
                            .line = if (tui.all_lines.len == 0) 0 else tui.all_lines.len - 1,
                            .col = 0,
                        };
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('d', .{ .ctrl = true })) {
                        const half: usize = @max(1, tui.visible_h / 2);
                        tui.nav_cursor.line = @min(tui.all_lines.len -| 1, tui.nav_cursor.line + half);
                        tui.clampNavCol();
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('u', .{ .ctrl = true })) {
                        const half: usize = @max(1, tui.visible_h / 2);
                        tui.nav_cursor.line -|= half;
                        tui.clampNavCol();
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('w', .{})) {
                        tui.moveWordForward();
                        tui.ensureCursorVisible();
                        moved = true;
                    } else if (key.matches('b', .{})) {
                        tui.moveWordBackward();
                        tui.ensureCursorVisible();
                        moved = true;
                    }

                    if (moved) {
                        if (tui.mode == .visual) tui.selection.cursor = tui.nav_cursor;
                        if (tui.mode == .visual_line) tui.syncVisualLineSelection();
                        try tui.render();
                        continue;
                    }
                    // Swallow anything else in normal/visual mode so
                    // typed characters don't leak into the input buffer.
                    continue;
                }

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
                    try tui.input.appendSlice(tui_arena, entry);
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
                            try tui.input.appendSlice(tui_arena, entry);
                        }
                        try tui.render();
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    // Multi-line mode: Enter inserts a literal \n
                    // and stays put; submit happens on Ctrl-D.
                    if (tui.multiline and tui.mode == .insert) {
                        try tui.input.append(tui_arena, '\n');
                        try tui.render();
                        continue;
                    }
                    if ((try submitInputBuffer(
                        &tui,
                        tui_arena,
                        gpa,
                        io,
                        env_map,
                        &tty,
                        history_path,
                    )) == .exit) return;
                    continue;
                }
                if (key.matches(vaxis.Key.backspace, .{})) {
                    if (tui.input.items.len > 0) _ = tui.input.pop();
                    try tui.render();
                    continue;
                }
                if (key.text) |t| {
                    try tui.input.appendSlice(tui_arena, t);
                    try tui.render();
                }
            },

            // ── agent-thread events ───────────────────────────────
            // Discard if the turn was canceled out from under us
            // (events queued before cancel arrived are stale).
            .a_text => |text| {
                defer gpa.free(text);
                if (tui.turn == null) continue;
                try tui.appendAssistantText(text);
                try tui.render();
            },
            .a_tool_call => |tc| {
                defer gpa.free(tc.name);
                defer gpa.free(tc.input);
                if (tui.turn == null) continue;
                var preview = tc.input;
                if (preview.len > 200) preview = preview[0..200];
                const line = try std.fmt.allocPrint(tui_arena, "→ {s}({s})", .{ tc.name, preview });
                try tui.pushBlock(.tool_call, line);
                try tui.render();
            },
            .a_tool_result => |tr| {
                defer gpa.free(tr.text);
                if (tui.turn == null) continue;
                var preview = tr.text;
                if (preview.len > 200) preview = preview[0..200];
                const ellipsis: []const u8 = if (tr.text.len > 200) "…" else "";
                const line = try std.fmt.allocPrint(tui_arena, "← {s}{s}", .{ preview, ellipsis });
                try tui.pushBlock(if (tr.is_error) .tool_result_error else .tool_result, line);
                try tui.render();
            },
            .a_usage => |usage| {
                if (tui.turn == null) continue;
                try tui.pushUsageNotice(usage);
                try tui.render();
            },
            .a_approval => |req| {
                // Worker is now blocked in gate.cond.wait; we own the
                // gpa-allocated path/diff_text and must free them once
                // we've copied the contents into our tui_arena. If
                // the turn was canceled out from under us, deliver
                // skip and free.
                defer gpa.free(req.path);
                defer gpa.free(req.diff_text);
                if (tui.turn == null) {
                    approval_gate.deliver(.skip);
                    continue;
                }
                const diff_owned = try tui_arena.dupe(u8, req.diff_text);
                try tui.pushBlock(.diff, diff_owned);
                const prompt_text = try std.fmt.allocPrint(
                    tui_arena,
                    "Apply edit to {s}? [a]pply  [s]kip  [A]lways apply  Esc=skip",
                    .{req.path},
                );
                try tui.pushBlock(.approval_prompt, prompt_text);
                tui.awaiting_prompt_id = tui.blocks.items[tui.blocks.items.len - 1].id;
                try tui.render();
            },
            .a_done => |result| {
                if (tui.turn == null) continue;
                const started_at = tui.turn.?.started_at;
                try tui.finishTurn();
                // Fire a desktop notification if the turn was long
                // enough (default 10s, override via VELK_NOTIFY_AFTER_MS).
                // Skipped for canceled turns and on errors — only
                // success notifications.
                if (result.err == null) {
                    const elapsed = started_at.untilNow(io, .awake);
                    const elapsed_ms: u64 = @intCast(@max(@as(i96, 0), @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms)));
                    const summary = lastAssistantText(&tui) orelse "(turn complete)";
                    notify.maybe(tui_arena, io, env_map, "velk: turn complete", summary, elapsed_ms);

                    // Auto-commit hook: only on successful turns,
                    // only when enabled, only when the tree is
                    // dirty (git_commit.maybeCommit checks). Best-
                    // effort — failures are surfaced as a notice
                    // but never propagated.
                    if (tui.auto_commit) {
                        const cap: usize = @min(tui.last_prompt.len, 80);
                        const subject = tui.last_prompt[0..cap];
                        const msg = try std.fmt.allocPrint(tui_arena, "velk: {s}", .{subject});
                        const outcome = git_commit.maybeCommit(io, gpa, msg);
                        switch (outcome) {
                            .committed => try tui.pushBlock(.notice, "[auto-commit] git commit succeeded"),
                            .failed => try tui.pushBlock(.tool_result_error, "[auto-commit] git commit failed (no repo, hook rejected, or git missing)"),
                            .clean => {}, // nothing changed — silent
                        }
                    }
                }
                if (result.err) |err| switch (err) {
                    error.Canceled => try tui.pushBlock(.notice, "[aborted]"),
                    else => {
                        // Try to extract `error.message` from the
                        // provider's captured response body so the
                        // user sees *why* it failed, not just the
                        // error name.
                        const detail = sess.provider.lastErrorBody();
                        const msg = if (detail) |body| blk: {
                            const Shape = struct {
                                @"error": struct {
                                    type: ?[]const u8 = null,
                                    message: ?[]const u8 = null,
                                } = .{},
                            };
                            const parsed = std.json.parseFromSlice(Shape, gpa, body, .{ .ignore_unknown_fields = true }) catch
                                break :blk try std.fmt.allocPrint(tui_arena, "error: {s}\n{s}", .{ @errorName(err), body });
                            defer parsed.deinit();
                            const m = parsed.value.@"error".message orelse
                                break :blk try std.fmt.allocPrint(tui_arena, "error: {s}\n{s}", .{ @errorName(err), body });
                            const t = parsed.value.@"error".type orelse "";
                            break :blk try std.fmt.allocPrint(tui_arena, "error ({s}): {s}", .{ t, m });
                        } else try std.fmt.allocPrint(tui_arena, "error: {s}", .{@errorName(err)});
                        try tui.pushBlock(.tool_result_error, msg);
                    },
                };
                try tui.render();
            },
        }
    }
}

// ───────── tests ─────────

const testing = std.testing;

test "naturalLineCount: empty is one row" {
    try testing.expectEqual(@as(usize, 1), naturalLineCount(""));
}

test "naturalLineCount: single line no newline" {
    try testing.expectEqual(@as(usize, 1), naturalLineCount("hello"));
}

test "naturalLineCount: single line trailing newline" {
    try testing.expectEqual(@as(usize, 1), naturalLineCount("hello\n"));
}

test "naturalLineCount: two lines no trailing newline" {
    try testing.expectEqual(@as(usize, 2), naturalLineCount("a\nb"));
}

test "naturalLineCount: two lines trailing newline" {
    try testing.expectEqual(@as(usize, 2), naturalLineCount("a\nb\n"));
}

test "naturalLineCount: many lines" {
    try testing.expectEqual(@as(usize, 5), naturalLineCount("a\nb\nc\nd\ne"));
}

test "collapseSummary: tool_call shows arrow + name + count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const block: Block = .{
        .id = 1,
        .kind = .tool_call,
        .text = "→ bash({\"cmd\":\"ls\"})\nbig\nlong\noutput\nrun\nlots\nof\nlines\nhere",
        .collapsed = true,
    };
    const s = try collapseSummary(arena.allocator(), block);
    try testing.expect(std.mem.startsWith(u8, s, "→ "));
    try testing.expect(std.mem.indexOf(u8, s, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, s, "9 lines") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Tab to expand") != null);
}

test "collapseSummary: tool_result strips prior arrow before re-prefixing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const block: Block = .{
        .id = 1,
        .kind = .tool_result,
        .text = "← stdout line\nline 2\nline 3",
        .collapsed = true,
    };
    const s = try collapseSummary(arena.allocator(), block);
    try testing.expect(std.mem.startsWith(u8, s, "← stdout line"));
    // Should NOT contain a doubled arrow ("← ← ").
    try testing.expect(std.mem.indexOf(u8, s, "← ← ") == null);
    try testing.expect(std.mem.indexOf(u8, s, "3 lines") != null);
}

test "collapseSummary: tool_result_error gets (error) prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const block: Block = .{
        .id = 1,
        .kind = .tool_result_error,
        .text = "← (error) bash failed\nstack\ntrace\nhere",
        .collapsed = true,
    };
    const s = try collapseSummary(arena.allocator(), block);
    try testing.expect(std.mem.indexOf(u8, s, "(error)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "bash failed") != null);
}

test "wrapBlockInto: collapsed tool block emits one row with summary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(RenderedLine) = .empty;
    const block: Block = .{
        .id = 7,
        .kind = .tool_result,
        .text = "← line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9",
        .collapsed = true,
    };
    try wrapBlockInto(arena, &lines, block, 120);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqual(@as(u32, 7), lines.items[0].block_id);
    try testing.expect(std.mem.indexOf(u8, lines.items[0].text, "9 lines") != null);
}

test "wrapBlockInto: not-collapsed tool block emits all rows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(RenderedLine) = .empty;
    const block: Block = .{
        .id = 9,
        .kind = .tool_result,
        .text = "a\nb\nc",
        .collapsed = false,
    };
    try wrapBlockInto(arena, &lines, block, 120);
    try testing.expectEqual(@as(usize, 3), lines.items.len);
    for (lines.items) |line| {
        try testing.expectEqual(@as(u32, 9), line.block_id);
    }
}

test "wrapBlockInto: collapsed flag ignored on non-collapsible kinds" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(RenderedLine) = .empty;
    // assistant_text isn't collapsible — even with collapsed=true,
    // wrapBlockInto must emit the full text.
    const block: Block = .{
        .id = 3,
        .kind = .assistant_text,
        .text = "alpha\nbeta\ngamma",
        .collapsed = true,
    };
    try wrapBlockInto(arena, &lines, block, 120);
    try testing.expectEqual(@as(usize, 3), lines.items.len);
}

test "Block.isCollapsible: only tool kinds" {
    try testing.expect((Block{ .id = 1, .kind = .tool_call, .text = "" }).isCollapsible());
    try testing.expect((Block{ .id = 1, .kind = .tool_result, .text = "" }).isCollapsible());
    try testing.expect((Block{ .id = 1, .kind = .tool_result_error, .text = "" }).isCollapsible());
    try testing.expect(!(Block{ .id = 1, .kind = .assistant_text, .text = "" }).isCollapsible());
    try testing.expect(!(Block{ .id = 1, .kind = .user_prompt, .text = "" }).isCollapsible());
    try testing.expect(!(Block{ .id = 1, .kind = .notice, .text = "" }).isCollapsible());
}
