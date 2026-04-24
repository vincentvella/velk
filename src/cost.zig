//! Per-million-token pricing for known models, and a helper that
//! turns a Usage tally into a USD cost. Prices are hardcoded snapshots
//! from public docs (Anthropic + OpenAI) and may drift — patches
//! welcome. Unknown models return null and the caller skips the cost
//! display.

const std = @import("std");
const provider = @import("provider.zig");

/// Prices in USD per 1,000,000 tokens.
pub const PriceMillion = struct {
    input: f64,
    output: f64,
    /// Anthropic-style cache hit rate (0 if not applicable).
    cache_read: f64 = 0,
    /// Anthropic-style 5-minute cache write rate.
    cache_write_5m: f64 = 0,
};

const Entry = struct {
    prefix: []const u8,
    price: PriceMillion,
};

/// Match by case-sensitive prefix so versioned IDs (e.g.
/// "claude-opus-4-7-20260101") line up with their family entry. Order
/// matters — first match wins, so put longer/more-specific prefixes
/// first.
const table = [_]Entry{
    // Anthropic — newest Opus pricing tier
    .{ .prefix = "claude-opus-4-5", .price = .{ .input = 5, .output = 25, .cache_read = 0.50, .cache_write_5m = 6.25 } },
    .{ .prefix = "claude-opus-4-6", .price = .{ .input = 5, .output = 25, .cache_read = 0.50, .cache_write_5m = 6.25 } },
    .{ .prefix = "claude-opus-4-7", .price = .{ .input = 5, .output = 25, .cache_read = 0.50, .cache_write_5m = 6.25 } },
    // Anthropic — older Opus 4 pricing tier
    .{ .prefix = "claude-opus-4-1", .price = .{ .input = 15, .output = 75, .cache_read = 1.50, .cache_write_5m = 18.75 } },
    .{ .prefix = "claude-opus-4", .price = .{ .input = 15, .output = 75, .cache_read = 1.50, .cache_write_5m = 18.75 } },
    // Anthropic — Sonnet
    .{ .prefix = "claude-sonnet-4", .price = .{ .input = 3, .output = 15, .cache_read = 0.30, .cache_write_5m = 3.75 } },
    // Anthropic — Haiku 4.5
    .{ .prefix = "claude-haiku-4-5", .price = .{ .input = 1, .output = 5, .cache_read = 0.10, .cache_write_5m = 1.25 } },
    // Anthropic — Haiku 3.5 (deprecated but still callable)
    .{ .prefix = "claude-haiku-3-5", .price = .{ .input = 0.80, .output = 4, .cache_read = 0.08, .cache_write_5m = 1.0 } },
    // OpenAI — GPT-5 family (no cache pricing exposed via streaming)
    .{ .prefix = "gpt-5", .price = .{ .input = 1.25, .output = 10 } },
    .{ .prefix = "gpt-4o", .price = .{ .input = 2.50, .output = 10 } },
    .{ .prefix = "gpt-4.1", .price = .{ .input = 2, .output = 8 } },
    .{ .prefix = "o1", .price = .{ .input = 15, .output = 60 } },
    .{ .prefix = "o3", .price = .{ .input = 2, .output = 8 } },
};

pub fn priceFor(model: []const u8) ?PriceMillion {
    for (table) |entry| {
        if (std.mem.startsWith(u8, model, entry.prefix)) return entry.price;
    }
    return null;
}

/// USD cost for a turn. Cache reads are billed at the cache_read rate;
/// cache writes at the cache_write_5m rate; everything else at the base
/// input rate. Output is straight output rate. Returns null for unknown
/// models so the caller can suppress the display rather than print 0.
pub fn turnCost(model: []const u8, usage: provider.Usage) ?f64 {
    const p = priceFor(model) orelse return null;
    const m: f64 = 1_000_000;
    const input_cost = (@as(f64, @floatFromInt(usage.input_tokens)) * p.input) / m;
    const cache_read_cost = (@as(f64, @floatFromInt(usage.cache_read_tokens)) * p.cache_read) / m;
    const cache_write_cost = (@as(f64, @floatFromInt(usage.cache_creation_tokens)) * p.cache_write_5m) / m;
    const output_cost = (@as(f64, @floatFromInt(usage.output_tokens)) * p.output) / m;
    return input_cost + cache_read_cost + cache_write_cost + output_cost;
}

const testing = std.testing;

test "priceFor: matches versioned anthropic ids" {
    const p = priceFor("claude-sonnet-4-5-20260101") orelse return error.TestFailed;
    try testing.expectEqual(@as(f64, 3), p.input);
}

test "priceFor: returns null for unknown" {
    try testing.expectEqual(@as(?PriceMillion, null), priceFor("model-from-the-future"));
}

test "turnCost: opus 4.7 simple turn" {
    const u: provider.Usage = .{ .input_tokens = 1000, .output_tokens = 500 };
    const cost = turnCost("claude-opus-4-7", u).?;
    // 1000 * 5/1M + 500 * 25/1M = 0.005 + 0.0125 = 0.0175
    try testing.expectApproxEqAbs(@as(f64, 0.0175), cost, 1e-9);
}

test "turnCost: cache reads are cheap" {
    const u: provider.Usage = .{ .input_tokens = 100, .cache_read_tokens = 10000, .output_tokens = 200 };
    // Sonnet 4.5: 100 * 3/1M + 10000 * 0.30/1M + 200 * 15/1M = 0.0003 + 0.003 + 0.003 = 0.0063
    const cost = turnCost("claude-sonnet-4-5", u).?;
    try testing.expectApproxEqAbs(@as(f64, 0.0063), cost, 1e-9);
}
