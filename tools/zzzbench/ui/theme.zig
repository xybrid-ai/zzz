//! Design tokens for the zzzbench dashboard.
//!
//! Every hex here comes from the `zzzbench TUI.dc.html` mock, so the
//! terminal matches it 1:1: muted teal-greys for chrome, one gold
//! accent, and three data ramps. This is the *only* file that names a
//! colour — the `tuiz` toolkit ships none, and every widget takes the
//! colours it draws with as arguments.

const tui = @import("tuiz");

pub const bold = tui.color.bold;
pub const reset = tui.color.reset;

const fg = tui.color.fg;

pub const text_hex = "#f5f7f7";
pub const export_background = "#0a1418";
pub const text = fg(text_hex); // headline + primary values
pub const sub = fg("#8fb3ba"); // secondary values
pub const mid = fg("#6f959c"); // row labels
pub const label = fg("#4d777f"); // section labels / captions
pub const faint = fg("#37565c"); // denominators, hints, idle chrome
pub const disabled = fg("#6f7d82"); // unavailable actions and model choices
pub const sep = fg("#2c525a"); // title-bar separators, idle units
pub const idle_number = fg("#2f5c64"); // hero number while idle (last run)
pub const accent = fg("#f5c518"); // gold — title, hero number, keys
pub const accent_dark = fg("#8a6f1e"); // unit under the hero number
pub const green = fg("#37d67a"); // status dot while running
pub const teal = fg("#2dd4bf"); // thermals-nominal verdict
pub const orange = fg("#fb923c"); // soc-warm verdict
pub const red = fg("#ef4444"); // throttling / disconnected
/// The three `z`s of the wordmark in the title bar, left to right.
///
/// Sampled from the zzz icon rather than picked: the icon is a
/// neon wordmark whose identity is the blue-to-magenta ramp across the
/// letters, and these are the three dominant hues of that ramp.
///
/// The mark is set as *text* here, not as block art, and that is not a
/// shortcut. The icon is a picture of the letters `ZZZ`, and a title
/// bar is one row — two subpixels — where it renders as solid noise;
/// it takes about eleven rows to read at all. A terminal already draws
/// letters perfectly at one row, so the thing worth carrying up here is
/// the colour, not the letterforms.
///
/// One ramp, not two: the title bar's left half is identity, and
/// `ui/title_bar.zig` records that making identity track run state was
/// wrong twice over. A wordmark that switched on partway through a
/// session would be the same mistake a third time.
pub const logo = [3][]const u8{ fg("#328AE6"), fg("#A641D3"), fg("#EC46F4") };

pub const rule = fg("#14343a"); // horizontal rules
pub const axis = fg("#1e4249"); // chart axis

/// Race-column sparklines. The leader takes the accent; the rest take
/// a teal that has to stay *readable* rather than recede — a race
/// where the also-rans are drawn in the axis colour reads as one
/// device with decoration, which is the opposite of the layout's
/// point. `axis` was that mistake.
pub const spark_lead = accent;
pub const spark_rest = fg("#3d7b85");

/// The prime-load lane under each race column's decode lane. Dimmer
/// than either decode tone on purpose: the race is about throughput,
/// and load is the context you read second. Still well clear of
/// `axis`, which is what made the first attempt disappear.
pub const spark_prime = fg("#26535e");

/// Hero chart ramp — light gold at the baseline, through the accent,
/// into deep teal at the peaks (t=0 is the first stop).
pub const chart_ramp = tui.Ramp{ .stops = &.{
    tui.Rgb.hex("#ffe08a"),
    tui.Rgb.hex("#f5c518"),
    tui.Rgb.hex("#c98a12"),
    tui.Rgb.hex("#2a6a78"),
} };

/// Idle chart ramp — the prime% telemetry backdrop in dim teals,
/// brightest at the baseline.
pub const idle_ramp = tui.Ramp{ .stops = &.{
    tui.Rgb.hex("#2a6a78"),
    tui.Rgb.hex("#1f5561"),
    tui.Rgb.hex("#17454f"),
    tui.Rgb.hex("#123840"),
} };

/// Utilisation / temperature ramp, cool teal → red.
pub const heat_ramp = tui.Ramp{ .stops = &.{
    tui.Rgb.hex("#2dd4bf"),
    tui.Rgb.hex("#a3e635"),
    tui.Rgb.hex("#f5c518"),
    tui.Rgb.hex("#fb923c"),
    tui.Rgb.hex("#ef4444"),
} };

/// Memory bar fill: sky blue while a run is live, dim teal at idle.
pub const memory_fill = tui.Rgb.hex("#38bdf8");
pub const memory_fill_idle = tui.Rgb.hex("#1f5561");

/// Ink for synthetic monochrome renderer fixtures.
pub const logo_ink = tui.Rgb.hex("#a855f7");

/// Unfilled meter remainder: faint dots, so a near-zero reading still
/// shows the slot it could fill.
pub const meter_track = tui.meter.Track{ .glyph = "·", .sgr = faint };

/// Outer gutter approximating the mock's card padding. Every row
/// starts this far in, and rules plus right-aligned content stop the
/// same distance before the terminal edge.
pub const margin: usize = 2;
pub const margin_pad = "  ";

comptime {
    @import("std").debug.assert(margin_pad.len == margin);
}

/// Chrome colours handed to the canvas.
pub const canvas_style = tui.Style{ .rule = rule, .label = label };

/// Size limits for the open layout. The stacked header + hero + stats
/// needs both a minimum width and a minimum height: below 20 rows the
/// hero number and its chart can't coexist, so the bench bails to the
/// too-small message rather than drawing a broken frame.
pub const limits = tui.Limits{
    .min_cols = 56,
    .min_rows = 20,
    .max_cols = 200,
    .margin = margin,
};
