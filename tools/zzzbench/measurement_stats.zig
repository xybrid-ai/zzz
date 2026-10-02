//! Descriptive statistics over measured repetitions, never over progress ticks.
//! A range describes observed variation; it is not a confidence interval.
const std = @import("std");

pub const Summary = struct {
    count: usize,
    min: f64,
    max: f64,
    mean: f64,
    /// (max - min) / mean * 100. Unknown with fewer than two samples.
    spread_pct: ?f64,
};

pub fn summarize(values: []const f64) ?Summary {
    if (values.len == 0) return null;
    var low = values[0];
    var high = values[0];
    var mean: f64 = 0;
    for (values, 0..) |value, i| {
        if (!std.math.isFinite(value) or value <= 0) return null;
        low = @min(low, value);
        high = @max(high, value);
        mean += (value - mean) / @as(f64, @floatFromInt(i + 1));
    }
    return .{
        .count = values.len,
        .min = low,
        .max = high,
        .mean = mean,
        .spread_pct = if (values.len > 1) (high - low) / mean * 100 else null,
    };
}

test "observed spread is independent of the selected headline statistic" {
    const result = summarize(&.{ 90, 100, 110 }).?;
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(@as(f64, 100), result.mean);
    try std.testing.expectEqual(@as(?f64, 20), result.spread_pct);
}

test "one repetition cannot establish stability and invalid samples cannot become zero" {
    try std.testing.expect(summarize(&.{100}).?.spread_pct == null);
    try std.testing.expect(summarize(&.{}) == null);
    try std.testing.expect(summarize(&.{ 100, 0 }) == null);
    try std.testing.expect(summarize(&.{ 100, std.math.nan(f64) }) == null);
    try std.testing.expect(summarize(&.{ 100, std.math.inf(f64) }) == null);
}
