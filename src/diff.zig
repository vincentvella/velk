//! Line-level unified diff. Backs the upcoming "diff preview before
//! apply" flow for the `edit` and `write_file` tools — before a tool
//! mutates a file, the TUI renders the diff produced here so the user
//! can approve or reject.
//!
//! The core is the Myers O(ND) diff algorithm walking the edit-script
//! D-paths in the forward direction. We then slice the resulting
//! per-line ops into hunks padded by `Options.context` lines of
//! surrounding context, merging hunks whose context windows touch.
//!
//! Output ownership: every byte and slice returned lives in the arena
//! the caller passes in. Pass an `ArenaAllocator.allocator()` and free
//! with one `arena.deinit()`.

const std = @import("std");

pub const Hunk = struct {
    /// 1-based start line in `old`. When the hunk is pure-add (no
    /// removed lines) this points at the line just before the
    /// insertion, matching `diff -u`. When `old_count == 0` and the
    /// insertion is at the top of the file, this is 0 (also matching
    /// `diff -u`).
    old_start: usize,
    old_count: usize,
    /// 1-based start line in `new`. Same edge-case rules as
    /// `old_start`.
    new_start: usize,
    new_count: usize,
    /// One display line per entry: `+`, `-`, or ` ` prefix followed by
    /// the content (no trailing newline). Owned by the arena passed to
    /// `unified`.
    lines: []const []const u8,
};

pub const Options = struct {
    /// Lines of unchanged context shown around each change. Standard
    /// `diff -u` default.
    context: usize = 3,
};

/// Per-line edit op produced by Myers. Internal — collapsed into
/// hunks before returning.
const Op = enum { equal, delete, insert };

const Edit = struct {
    op: Op,
    /// Index into the input line slice. `delete`/`equal` index into
    /// `old`; `insert` indexes into `new`.
    idx: usize,
};

/// Produce a unified diff of `old` vs `new`. Splits both inputs on
/// `\n`, runs Myers, then groups the resulting edit script into hunks
/// with `opts.context` lines of surrounding context. Hunks whose
/// context windows touch or overlap are merged into one — that
/// matches GNU `diff -u` and is what the TUI wants for a clean
/// preview.
///
/// Empty input is allowed on either side (whole-file add / remove).
/// A final line without a trailing `\n` is handled the same as one
/// with a trailing `\n` — we don't emit a "\ No newline at end of
/// file" marker; the TUI doesn't need it for the preview, and
/// upstream tooling doesn't depend on it.
pub fn unified(
    arena: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
    opts: Options,
) ![]const Hunk {
    const old_lines = try splitLines(arena, old);
    const new_lines = try splitLines(arena, new);

    const script = try myers(arena, old_lines, new_lines);
    return try groupHunks(arena, old_lines, new_lines, script, opts.context);
}

/// Convenience wrapper: produce the canonical `diff -u`-style block
/// as one flat string with `--- a/<old_label>` / `+++ b/<new_label>`
/// file headers and `@@ -X,Y +A,B @@` hunk headers. The label is
/// glued under the conventional `a/` and `b/` prefixes — pass e.g.
/// `"src/foo.zig"` for both, and you'll get `--- a/src/foo.zig` and
/// `+++ b/src/foo.zig`. Pass `""` for an unlabelled diff (`--- a/`
/// / `+++ b/`).
pub fn unifiedString(
    arena: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
    opts: Options,
) ![]const u8 {
    return try unifiedStringLabeled(arena, old, new, "", "", opts);
}

/// Same as `unifiedString` but lets the caller override the path
/// labels written into the `--- a/...` / `+++ b/...` headers. Useful
/// when the TUI knows the real path of the file being edited.
pub fn unifiedStringLabeled(
    arena: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
    old_label: []const u8,
    new_label: []const u8,
    opts: Options,
) ![]const u8 {
    const hunks = try unified(arena, old, new, opts);
    if (hunks.len == 0) return "";

    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "--- a/{s}\n", .{old_label});
    try buf.print(arena, "+++ b/{s}\n", .{new_label});

    for (hunks) |h| {
        try buf.print(arena, "@@ -{d},{d} +{d},{d} @@\n", .{
            h.old_start, h.old_count, h.new_start, h.new_count,
        });
        for (h.lines) |line| {
            try buf.print(arena, "{s}\n", .{line});
        }
    }
    return buf.items;
}

// ───────── line splitter ─────────

/// Split `data` on `\n` into a slice of line views (no trailing
/// newline on each). An empty input yields an empty slice (zero
/// lines). A trailing newline is treated as a terminator, not a
/// separator: "a\n" is one line ("a"), "a\nb" is two lines ("a",
/// "b"), "a\nb\n" is two lines. This matches what `diff -u` shows.
fn splitLines(arena: std.mem.Allocator, data: []const u8) ![]const []const u8 {
    if (data.len == 0) return &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            try lines.append(arena, data[start..i]);
            start = i + 1;
        }
    }
    // Trailing partial line (no final \n) → still a line.
    if (start < data.len) {
        try lines.append(arena, data[start..]);
    }
    return lines.items;
}

// ───────── Myers O(ND) diff ─────────

/// Forward Myers diff. Returns the edit script as a list of `Edit`s
/// in input order. The classic algorithm finds the shortest sequence
/// of insertions/deletions to transform `a` into `b`; "equal" entries
/// are filled in by walking the snake at each D-path step.
///
/// Memory: O(N+M) per stored V trace + the script. We allocate every
/// `v` row into the arena so we can backtrack at the end. Fine for
/// the file sizes velk's edit tool will see (a few hundred KiB at
/// the upper bound).
fn myers(
    arena: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) ![]const Edit {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max: isize = n + m;

    // V is indexed by k in [-max, +max]; we offset by `max` to fit
    // into a non-negative array index. Length is 2*max+1.
    const v_len: usize = @intCast(2 * max + 1);

    // Save a snapshot of V at each D so we can backtrack. This is
    // the straight-from-the-paper approach; memory is O(D*(N+M)).
    var traces: std.ArrayList([]isize) = .empty;

    // Edge case: both empty → no edits.
    if (n == 0 and m == 0) return &.{};

    // Working V row, reused per D and copied into `traces` at the
    // end of each iteration.
    const v = try arena.alloc(isize, v_len);
    @memset(v, 0);

    var d: isize = 0;
    var found = false;
    while (d <= max) : (d += 1) {
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const k_idx: usize = @intCast(k + max);
            const down = (k == -d) or (k != d and v[k_idx - 1] < v[k_idx + 1]);
            var x: isize = if (down) v[k_idx + 1] else v[k_idx - 1] + 1;
            var y: isize = x - k;

            // Follow the diagonal as far as the inputs match.
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }

            v[k_idx] = x;

            if (x >= n and y >= m) {
                found = true;
                break;
            }
        }

        // Snapshot V before the next iteration overwrites it.
        const snap = try arena.dupe(isize, v);
        try traces.append(arena, snap);

        if (found) break;
    }

    return try backtrack(arena, traces.items, a, b, max);
}

/// Walk the saved V traces in reverse to produce the edit script.
/// `traces[d]` is the snapshot of V at the END of forward iteration
/// d, so `traces[d-1]` describes the state we came from when we did
/// iteration d. At each D we figure out which diagonal we entered
/// from (the larger of v_{d-1}[k-1], v_{d-1}[k+1]), emit the
/// diagonal "equal" run that bridged the gap, then emit the single
/// insert or delete that produced the move.
fn backtrack(
    arena: std.mem.Allocator,
    traces: []const []isize,
    a: []const []const u8,
    b: []const []const u8,
    max: isize,
) ![]const Edit {
    var edits: std.ArrayList(Edit) = .empty;

    var x: isize = @intCast(a.len);
    var y: isize = @intCast(b.len);

    // traces.len is D+1 (one snapshot per completed iteration,
    // including D=0). Iterate d = D, D-1, ..., 1; at d=0 there's no
    // previous step, only the leading equal run.
    var d: isize = @intCast(traces.len);
    d -= 1;
    while (d > 0) : (d -= 1) {
        const prev_v = traces[@intCast(d - 1)];
        const k = x - y;

        // The forward step at level d chose `down` if k was at the
        // top diagonal of d, OR if v_{d-1}[k-1] < v_{d-1}[k+1].
        const lo_k = -d;
        const hi_k = d;
        const down = (k == lo_k) or
            (k != hi_k and prev_v[@intCast(k - 1 + max)] < prev_v[@intCast(k + 1 + max)]);

        const prev_k = if (down) k + 1 else k - 1;
        const prev_x = prev_v[@intCast(prev_k + max)];
        const prev_y = prev_x - prev_k;

        // Diagonal run leading up to the move (in reverse).
        while (x > prev_x and y > prev_y) {
            try edits.append(arena, .{ .op = .equal, .idx = @intCast(x - 1) });
            x -= 1;
            y -= 1;
        }

        if (down) {
            // Came from k+1 → y advanced by 1: an insertion of
            // b[y-1] (== b[prev_y]).
            try edits.append(arena, .{ .op = .insert, .idx = @intCast(y - 1) });
        } else {
            // Came from k-1 → x advanced by 1: a deletion of
            // a[x-1] (== a[prev_x]).
            try edits.append(arena, .{ .op = .delete, .idx = @intCast(x - 1) });
        }

        x = prev_x;
        y = prev_y;
    }

    // Any remaining diagonal at the top (D=0 prefix common to both).
    while (x > 0 and y > 0) {
        try edits.append(arena, .{ .op = .equal, .idx = @intCast(x - 1) });
        x -= 1;
        y -= 1;
    }

    // The script was built tail-first; reverse in place.
    std.mem.reverse(Edit, edits.items);
    return edits.items;
}

// ───────── hunk grouping ─────────

/// Group an edit script into hunks padded by `context` lines on each
/// side, merging hunks whose padding overlaps.
fn groupHunks(
    arena: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    script: []const Edit,
    context: usize,
) ![]const Hunk {
    if (script.len == 0) return &.{};

    // Find the index ranges of "change runs" — contiguous spans of
    // non-equal edits. Then expand each run by `context` on either
    // side and merge overlaps.
    var change_starts: std.ArrayList(usize) = .empty;
    var change_ends: std.ArrayList(usize) = .empty; // exclusive

    var i: usize = 0;
    while (i < script.len) {
        if (script[i].op == .equal) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < script.len and script[i].op != .equal) i += 1;
        try change_starts.append(arena, start);
        try change_ends.append(arena, i);
    }

    if (change_starts.items.len == 0) return &.{};

    // Expand each change run by `context` on each side, then merge
    // overlaps. We work in script-index space.
    var hunk_lo: std.ArrayList(usize) = .empty;
    var hunk_hi: std.ArrayList(usize) = .empty; // exclusive

    var j: usize = 0;
    while (j < change_starts.items.len) : (j += 1) {
        const lo = saturatingSub(change_starts.items[j], context);
        var hi = change_ends.items[j] + context;
        if (hi > script.len) hi = script.len;

        if (hunk_lo.items.len > 0 and lo <= hunk_hi.items[hunk_lo.items.len - 1]) {
            // Merge into the previous hunk.
            const last = hunk_hi.items.len - 1;
            if (hi > hunk_hi.items[last]) hunk_hi.items[last] = hi;
        } else {
            try hunk_lo.append(arena, lo);
            try hunk_hi.append(arena, hi);
        }
    }

    // Materialise each hunk: render display lines, count old/new
    // touched lines, compute 1-based start positions.
    var out: std.ArrayList(Hunk) = .empty;
    for (hunk_lo.items, hunk_hi.items) |lo, hi| {
        try out.append(arena, try buildHunk(arena, old_lines, new_lines, script, lo, hi));
    }
    return out.items;
}

fn saturatingSub(a: usize, b: usize) usize {
    return if (b >= a) 0 else a - b;
}

fn buildHunk(
    arena: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    script: []const Edit,
    lo: usize,
    hi: usize,
) !Hunk {
    var lines: std.ArrayList([]const u8) = .empty;

    // Find the 1-based old/new start positions by counting how many
    // old / new lines preceded this hunk's first edit.
    var old_seen: usize = 0;
    var new_seen: usize = 0;
    var k: usize = 0;
    while (k < lo) : (k += 1) {
        switch (script[k].op) {
            .equal => { old_seen += 1; new_seen += 1; },
            .delete => old_seen += 1,
            .insert => new_seen += 1,
        }
    }

    var old_count: usize = 0;
    var new_count: usize = 0;

    var idx = lo;
    while (idx < hi) : (idx += 1) {
        const e = script[idx];
        switch (e.op) {
            .equal => {
                const line = try std.fmt.allocPrint(arena, " {s}", .{old_lines[e.idx]});
                try lines.append(arena, line);
                old_count += 1;
                new_count += 1;
            },
            .delete => {
                const line = try std.fmt.allocPrint(arena, "-{s}", .{old_lines[e.idx]});
                try lines.append(arena, line);
                old_count += 1;
            },
            .insert => {
                const line = try std.fmt.allocPrint(arena, "+{s}", .{new_lines[e.idx]});
                try lines.append(arena, line);
                new_count += 1;
            },
        }
    }

    // 1-based: if a side has zero lines in this hunk, `diff -u`
    // emits the index of the line *before* the insertion (which can
    // be 0 for top-of-file insertions). Otherwise it emits the
    // 1-based index of the first touched line.
    const old_start: usize = if (old_count == 0) old_seen else old_seen + 1;
    const new_start: usize = if (new_count == 0) new_seen else new_seen + 1;

    return .{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
        .lines = lines.items,
    };
}

// ───────── tests ─────────

const testing = std.testing;

test "unified: empty old + empty new → no hunks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunks = try unified(arena.allocator(), "", "", .{});
    try testing.expectEqual(@as(usize, 0), hunks.len);
}

test "unified: empty old + non-empty new → single all-add hunk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunks = try unified(arena.allocator(), "", "alpha\nbeta\ngamma\n", .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    const h = hunks[0];
    try testing.expectEqual(@as(usize, 0), h.old_start);
    try testing.expectEqual(@as(usize, 0), h.old_count);
    try testing.expectEqual(@as(usize, 1), h.new_start);
    try testing.expectEqual(@as(usize, 3), h.new_count);
    try testing.expectEqual(@as(usize, 3), h.lines.len);
    for (h.lines) |line| try testing.expect(line[0] == '+');
    try testing.expectEqualStrings("+alpha", h.lines[0]);
    try testing.expectEqualStrings("+beta", h.lines[1]);
    try testing.expectEqualStrings("+gamma", h.lines[2]);
}

test "unified: non-empty old + empty new → single all-delete hunk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunks = try unified(arena.allocator(), "alpha\nbeta\n", "", .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    const h = hunks[0];
    try testing.expectEqual(@as(usize, 1), h.old_start);
    try testing.expectEqual(@as(usize, 2), h.old_count);
    try testing.expectEqual(@as(usize, 0), h.new_start);
    try testing.expectEqual(@as(usize, 0), h.new_count);
    try testing.expectEqual(@as(usize, 2), h.lines.len);
    try testing.expectEqualStrings("-alpha", h.lines[0]);
    try testing.expectEqualStrings("-beta", h.lines[1]);
}

test "unified: identical inputs → no hunks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunks = try unified(arena.allocator(), "a\nb\nc\n", "a\nb\nc\n", .{});
    try testing.expectEqual(@as(usize, 0), hunks.len);
}

test "unified: single-line change with surrounding context" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old =
        "one\ntwo\nthree\nfour\nfive\n";
    const new =
        "one\ntwo\nTHREE\nfour\nfive\n";
    const hunks = try unified(arena.allocator(), old, new, .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    const h = hunks[0];
    try testing.expectEqual(@as(usize, 1), h.old_start);
    try testing.expectEqual(@as(usize, 5), h.old_count);
    try testing.expectEqual(@as(usize, 1), h.new_start);
    try testing.expectEqual(@as(usize, 5), h.new_count);

    // Expect: " one\n two\n-three\n+THREE\n four\n five\n"
    try testing.expectEqualStrings(" one", h.lines[0]);
    try testing.expectEqualStrings(" two", h.lines[1]);
    try testing.expectEqualStrings("-three", h.lines[2]);
    try testing.expectEqualStrings("+THREE", h.lines[3]);
    try testing.expectEqualStrings(" four", h.lines[4]);
    try testing.expectEqualStrings(" five", h.lines[5]);
}

test "unified: two adjacent changes within context merge into one hunk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Changes at lines 3 and 5, with context=3 the windows overlap
    // through line 4 → single hunk.
    const old = "1\n2\n3\n4\n5\n6\n7\n";
    const new = "1\n2\nTHREE\n4\nFIVE\n6\n7\n";
    const hunks = try unified(arena.allocator(), old, new, .{ .context = 3 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
}

test "unified: two changes far apart produce two hunks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Changes at lines 2 and 10 with default context=3 → no overlap.
    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n";
    const new = "1\nTWO\n3\n4\n5\n6\n7\n8\n9\nTEN\n11\n";
    const hunks = try unified(arena.allocator(), old, new, .{ .context = 3 });
    try testing.expectEqual(@as(usize, 2), hunks.len);
}

test "unified: file with no trailing newline does not crash and produces no spurious diff" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Same content, one with trailing \n one without — this should
    // NOT produce a diff: the trailing-newline distinction is
    // ignored at this layer (the TUI doesn't need to surface it).
    const hunks_a = try unified(arena.allocator(), "a\nb\nc", "a\nb\nc", .{});
    try testing.expectEqual(@as(usize, 0), hunks_a.len);

    // Real change in a no-trailing-newline file should still work.
    const hunks_b = try unified(arena.allocator(), "a\nb\nc", "a\nB\nc", .{});
    try testing.expectEqual(@as(usize, 1), hunks_b.len);
    try testing.expectEqualStrings("-b", hunks_b[0].lines[1]);
    try testing.expectEqualStrings("+B", hunks_b[0].lines[2]);
}

test "unified: multi-line addition mid-file — line numbers in the @@ header are correct" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old = "1\n2\n3\n4\n5\n";
    // Insert two new lines between 3 and 4.
    const new = "1\n2\n3\nthree.5a\nthree.5b\n4\n5\n";
    const hunks = try unified(arena.allocator(), old, new, .{ .context = 3 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
    const h = hunks[0];
    // Old side: lines 1..5 are touched as context (5 lines, all of them).
    try testing.expectEqual(@as(usize, 1), h.old_start);
    try testing.expectEqual(@as(usize, 5), h.old_count);
    // New side: lines 1..7 are touched (7 lines, all of them).
    try testing.expectEqual(@as(usize, 1), h.new_start);
    try testing.expectEqual(@as(usize, 7), h.new_count);
    // Two `+` lines for the additions.
    var plus: usize = 0;
    for (h.lines) |line| {
        if (line[0] == '+') plus += 1;
    }
    try testing.expectEqual(@as(usize, 2), plus);
}

test "unifiedString: produces standard diff -u shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old = "alpha\nbeta\ngamma\n";
    const new = "alpha\nBETA\ngamma\ndelta\n";
    const out = try unifiedString(arena.allocator(), old, new, .{});
    // Headers
    try testing.expect(std.mem.startsWith(u8, out, "--- a/\n+++ b/\n"));
    // A hunk header with the expected shape.
    try testing.expect(std.mem.indexOf(u8, out, "@@ -1,3 +1,4 @@") != null);
    // Body has the changed lines.
    try testing.expect(std.mem.indexOf(u8, out, "-beta\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+BETA\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+delta\n") != null);
}

test "unifiedString: empty when inputs identical" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try unifiedString(arena.allocator(), "x\ny\n", "x\ny\n", .{});
    try testing.expectEqualStrings("", out);
}

test "unifiedStringLabeled: paths flow into headers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try unifiedStringLabeled(
        arena.allocator(),
        "a\n",
        "b\n",
        "src/foo.zig",
        "src/foo.zig",
        .{},
    );
    try testing.expect(std.mem.startsWith(u8, out, "--- a/src/foo.zig\n+++ b/src/foo.zig\n"));
}

test "unified: pure insertion at top of file → old_start is 0" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunks = try unified(arena.allocator(), "", "first\n", .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(usize, 0), hunks[0].old_start);
    try testing.expectEqual(@as(usize, 0), hunks[0].old_count);
    try testing.expectEqual(@as(usize, 1), hunks[0].new_start);
    try testing.expectEqual(@as(usize, 1), hunks[0].new_count);
}

test "unified: pure deletion → new_start is 0" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunks = try unified(arena.allocator(), "only\n", "", .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(usize, 1), hunks[0].old_start);
    try testing.expectEqual(@as(usize, 1), hunks[0].old_count);
    try testing.expectEqual(@as(usize, 0), hunks[0].new_start);
    try testing.expectEqual(@as(usize, 0), hunks[0].new_count);
}

test "unified: context=0 only emits the changed lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old = "a\nb\nc\n";
    const new = "a\nB\nc\n";
    const hunks = try unified(arena.allocator(), old, new, .{ .context = 0 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
    const h = hunks[0];
    try testing.expectEqual(@as(usize, 2), h.lines.len);
    try testing.expectEqualStrings("-b", h.lines[0]);
    try testing.expectEqualStrings("+B", h.lines[1]);
    try testing.expectEqual(@as(usize, 2), h.old_start);
    try testing.expectEqual(@as(usize, 1), h.old_count);
    try testing.expectEqual(@as(usize, 2), h.new_start);
    try testing.expectEqual(@as(usize, 1), h.new_count);
}
