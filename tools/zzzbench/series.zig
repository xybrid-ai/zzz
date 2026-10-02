//! The one place the bench decides how much sample history it keeps.
//!
//! Capacity bounds how far back `peak`/`avg` can see, and — because
//! the hero chart draws one cell per sample — how much of a wide chart
//! a filled history can cover. It must therefore exceed the widest
//! chart the layout can ask for, which is bounded by
//! `theme.limits.max_cols`; short of that, a full history would still
//! leave blank columns on the left of a 200-column terminal forever.

const tui = @import("tuiz");

pub const capacity: usize = 256;

comptime {
    // Not an import of `theme` — that would make the wire-facing half
    // of the bench depend on its palette. The bound is restated here
    // and asserted against the same number.
    @import("std").debug.assert(capacity > 200);
}

pub const Series = tui.Series(capacity);
