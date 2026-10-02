//! Test aggregator for zzzbench.
//!
//! `zig build test` roots one test artifact here so every unit
//! is reachable from a single run. Tests live next to the code they
//! cover, not in this file.

test {
    _ = @import("bundle.zig");
    _ = @import("measurement_stats.zig");
    _ = @import("comparison_report.zig");
    _ = @import("main.zig");
    _ = @import("device_comparison.zig");
    _ = @import("cli.zig");
    _ = @import("engine.zig");
    _ = @import("engine_command.zig");
    _ = @import("engine_manifest.zig");
    _ = @import("engine_registry.zig");
    _ = @import("output.zig");
    _ = @import("comparison.zig");
    _ = @import("compare_command.zig");
    _ = @import("comparison_receipt.zig");
    _ = @import("engine_parser.zig");
    _ = @import("exec_client.zig");
    _ = @import("logos_preview.zig");
    _ = @import("peer.zig");
    _ = @import("series.zig");
    _ = @import("wire.zig");
    _ = @import("discovery/android.zig");
    _ = @import("discovery/bootstrap_android.zig");
    _ = @import("discovery/catalog.zig");
    _ = @import("discovery/device.zig");
    _ = @import("discovery/ios.zig");
    _ = @import("discovery/setup.zig");
    _ = @import("device_picker.zig");
    _ = @import("keys.zig");
    _ = @import("model_catalog.zig");
    _ = @import("model_picker.zig");
    _ = @import("model_sync.zig");
    _ = @import("params_editor.zig");
    _ = @import("run_policy.zig");
    _ = @import("ui/comparison_screen.zig");
    _ = @import("ui/credit.zig");
    _ = @import("ui/picker_screen.zig");
    _ = @import("ui/dashboard.zig");
    _ = @import("ui/hero.zig");
    _ = @import("ui/logos.zig");
    _ = @import("ui/output.zig");
    _ = @import("ui/peer_band.zig");
    _ = @import("ui/race.zig");
    _ = @import("ui/splash.zig");
    _ = @import("ui/state.zig");
    _ = @import("ui/export.zig");
    _ = @import("ui/stats.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/title_bar.zig");
}
