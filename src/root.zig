pub const version = "0.0.1";

// Pull in modules whose tests should run under `zig build test` even
// though no other file imports them yet. (`diff.zig` will be consumed
// by the upcoming edit/write_file diff-preview flow.)
comptime {
    _ = @import("diff.zig");
}
