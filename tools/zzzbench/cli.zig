//! Command-line parsing for zzzbench.
//!
//! Parsing and reporting are split: `parse` decides, `Diagnostic`
//! describes what went wrong, and only the caller prints. That keeps
//! the whole surface testable without a probe — and without a test run
//! spraying diagnostics at stderr.

const std = @import("std");

const comparison = @import("comparison.zig");
const engine_mod = @import("engine.zig");
const run_policy = @import("run_policy.zig");
const logos = @import("ui/logos.zig");
const peer_mod = @import("peer.zig");
const Peer = peer_mod.Peer;

/// Up to 4 peers (5 devices total) is plenty for one bench window;
/// more won't fit at typical terminal heights.
pub const max_peers: usize = 4;
pub const max_engine_dirs: usize = 8;
/// Comparators named by `--vs`, on top of the `zzz` baseline. More than
/// a handful of engines on one device stops being a comparison and
/// starts being a sweep, which has its own harness.
pub const max_comparators: usize = 4;

/// The engine every ratio is taken against. Named here so the flag that
/// refuses it and the arm order that assumes it cannot drift apart.
pub const baseline_engine_id = "zzz";

/// Default endpoint. `tcp:PORT` is the Android-friendly choice since
/// `adb forward tcp:7779 tcp:7779` bridges the on-device probe to the
/// host bench transparently.
pub const default_endpoint = "tcp:7779";

pub const Options = struct {
    command: Command = .dashboard,
    endpoint: []const u8 = default_endpoint,
    /// The user named an endpoint; it remains primary when combined
    /// with discovered devices.
    explicit_endpoint: bool = false,
    auto: bool = false,
    platform: PlatformFilter = .all,
    devices: []const u8 = "",
    select_all: bool = false,
    /// `--replace-probe`: stop a probe another workspace left on an
    /// Android device's port instead of refusing to start. Without it,
    /// a terminal session asks and anything else refuses.
    replace_probe: bool = false,
    json: bool = false,
    engine_dirs: [max_engine_dirs][]const u8 = @splat(""),
    engine_dir_count: usize = 0,
    /// `--vs ID[,ID...]`: engine manifests to measure against the `zzz`
    /// baseline. Distinct from `--engine`/`--compare`, which are manual
    /// display numbers and run nothing.
    comparators: [max_comparators][]const u8 = @splat(""),
    comparator_count: usize = 0,
    /// Measured repetitions per engine, excluding the warm-up.
    reps: u8 = 3,
    /// How repetitions become one number. Owned by the run, applied
    /// identically to every engine in it.
    stat: comparison.Stat = .mean,
    threads: u32 = 4,
    /// Whether `--threads` was actually given. An unset default is a
    /// placeholder the device is allowed to overwrite with its own
    /// core count; a value the operator typed is not.
    threads_set: bool = false,
    n_prompt: u32 = 16,
    n_generate: u32 = 32,
    /// `--kernel`: request a kernel-selection mode for each device.
    /// Scope depends on the supplied engine; a selected mode may not
    /// affect every operation. `auto` leaves selection to the engine.
    kernel: run_policy.Kernel = .auto,
    engine: engine_mod.Engine = .{ .name = "zzz", .tok_s = 0 },
    compare: ?engine_mod.Engine = null,
    /// `--model NAME|PATH`: choose without the picker, for scripted
    /// captures. Empty leaves the choice to `m`.
    model: []const u8 = "",
    engine_bin: []const u8 = "",
    engine_bin_override: bool = false,
    engine_model: []const u8 = "",
    probe_test: bool = false,
    /// Draw the block-art marks and exit — no probe, no dashboard.
    logos: bool = false,
    /// `--logo NAME`: which baked mark to credit on the dashboard.
    /// Empty means no plate.
    logo: []const u8 = "",
    /// Where that plate goes. Three placements because which one reads
    /// best is a question about the whole frame, not one that can be
    /// settled by argument — so it is a flag, not a constant.
    logo_at: LogoAt = .right,
    /// `--credit TEXT`: the plate's middle line. Defaults to the mark's
    /// own label when unset.
    credit: []const u8 = "",
    /// How a multi-device window is laid out.
    multi: Multi = .bands,
    /// `--prompt TEXT`: what the engine is asked to continue. Empty
    /// leaves the engine on its synthetic token sequence, which is the
    /// reproducible timing path — real text is opt-in because it
    /// changes what gets prefilled.
    prompt: []const u8 = "",
    /// `--show-output`: start with the OUTPUT panel open. Off by
    /// default; `[o]` toggles it either way.
    show_output: bool = false,
    peer_count: usize = 0,
};

pub const Command = enum { dashboard, devices, models, engines, compare, help };

/// Printed by `zzzbench --help`. Lists the documented options; a test
/// checks that every option named here is one `parse` accepts.
pub const usage =
    \\Usage:
    \\  zzzbench [OPTIONS]                Discover devices and open the dashboard
    \\  zzzbench [OPTIONS] ENDPOINT       Connect to a running probe, e.g. tcp:7779
    \\  zzzbench devices [--json]         List available devices
    \\  zzzbench models [--json]          List catalogued models
    \\  zzzbench engines [--json]         List engine adapters
    \\  zzzbench compare ENDPOINT --model PATH --vs ID [OPTIONS]
    \\                                    Benchmark zzz against other engines
    \\
    \\Devices:
    \\  --platform all|android|host       Limit discovery
    \\  --devices ID[,ID...]              Select devices without the picker
    \\  --all                             Select every available device, up to five
    \\  --replace-probe                   Stop another workspace's probe on an Android phone
    \\
    \\Run:
    \\  --model NAME|PATH                 Model from the catalogue
    \\  --threads N                       Engine threads
    \\  --n-prompt-tokens N               Prompt tokens (default 16)
    \\  --n-generate-tokens N             Generated tokens (default 32)
    \\  --prompt TEXT                     Generate from text instead of benchmark tokens
    \\  --show-output                     Show generated text
    \\  --engine-bin PATH                 Host engine executable
    \\
    \\Compare:
    \\  --vs ID[,ID...]                   Engines measured against zzz
    \\  --reps N                          Measured repetitions per engine (default 3)
    \\  --engine-dir DIR                  Additional adapter manifest directory
    \\
    \\  -h, --help                        Show this help
    \\
    \\Guide: https://github.com/xybrid-ai/zzz/blob/main/docs/usage.md
    \\
;
pub const PlatformFilter = enum { all, android, ios, host };

pub const LogoAt = enum { right, left, top };

/// `bands` keeps the primary device as the subject and lists the rest
/// beneath it; `race` drops the hero and gives every device an equal
/// column. Which one reads better depends on whether you are watching
/// one device or comparing several, so it is a flag rather than a
/// guess made from the peer count.
pub const Multi = enum { bands, race };

/// Why `parse` returned null. `report()` is the only thing here that
/// touches stderr.
pub const Diagnostic = union(enum) {
    none,
    bad_engine_spec: []const u8,
    bad_compare_spec: []const u8,
    bad_probe_spec: []const u8,
    too_many_probes: usize,
    missing_value: []const u8,
    unknown_option: []const u8,
    bad_platform: []const u8,
    bad_logo: []const u8,
    logo_has_no_plate: []const u8,
    bad_logo_at: []const u8,
    bad_multi: []const u8,
    bad_positive_integer: struct { flag: []const u8, value: []const u8 },
    bad_kernel: []const u8,
    too_many_engine_dirs: usize,
    too_many_comparators: usize,
    bad_stat: []const u8,
    unknown_comparator: []const u8,
    baseline_comparator: []const u8,
    duplicate_comparator: []const u8,

    pub fn report(self: Diagnostic) void {
        switch (self) {
            .none => {},
            .bad_engine_spec => |s| std.debug.print("zzzbench: bad --engine spec '{s}', expected NAME:TOK_S\n", .{s}),
            .bad_compare_spec => |s| std.debug.print("zzzbench: bad --compare spec '{s}', expected NAME:TOK_S\n", .{s}),
            .bad_probe_spec => |s| std.debug.print("zzzbench: bad --probe spec '{s}', expected LABEL:ENDPOINT\n", .{s}),
            .too_many_probes => |n| std.debug.print("zzzbench: too many --probe entries (max {d})\n", .{n}),
            .missing_value => |flag| std.debug.print("zzzbench: {s} requires a value\n", .{flag}),
            .unknown_option => |flag| std.debug.print("zzzbench: unknown option '{s}'\n", .{flag}),
            .bad_platform => |s| std.debug.print("zzzbench: bad --platform '{s}', expected all, android, ios, or host\n", .{s}),
            .bad_logo => |s| {
                if (logos.catalog.len == 0) {
                    std.debug.print("zzzbench: artwork is not included in this build; omit --logo '{s}'.\n", .{s});
                } else {
                    var buf: [512]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&buf);
                    logos.writeIds(&w) catch {};
                    std.debug.print("zzzbench: unknown --logo '{s}'. Available: {s}\n", .{ s, w.buffered() });
                }
            },
            .logo_has_no_plate => |s| std.debug.print(
                "zzzbench: --logo '{s}' has no plate-sized art — it is too detailed to" ++
                    " shrink beside the headline number. See it with --logos.\n",
                .{s},
            ),
            .bad_logo_at => |s| std.debug.print(
                "zzzbench: bad --logo-at '{s}', expected right, left, or top\n",
                .{s},
            ),
            .bad_multi => |s| std.debug.print(
                "zzzbench: bad --multi '{s}', expected bands or race\n",
                .{s},
            ),
            .bad_kernel => |s| std.debug.print(
                "zzzbench: bad --kernel '{s}', expected auto|sdot|vector|scalar\n",
                .{s},
            ),
            .too_many_engine_dirs => |count| std.debug.print(
                "zzzbench: too many --engine-dir entries (max {d})\n",
                .{count},
            ),
            .too_many_comparators => |count| std.debug.print(
                "zzzbench: too many --vs engines (max {d})\n",
                .{count},
            ),
            .bad_stat => |s| std.debug.print(
                "zzzbench: bad --stat '{s}', expected mean or best\n",
                .{s},
            ),
            .unknown_comparator => |s| std.debug.print(
                "zzzbench: --vs '{s}' is empty; expected engine ids, e.g. --vs llamacpp\n",
                .{s},
            ),
            .baseline_comparator => |s| std.debug.print(
                "zzzbench: --vs '{s}' is the baseline every ratio is taken against;" ++
                    " name a different engine\n",
                .{s},
            ),
            .duplicate_comparator => |s| std.debug.print(
                "zzzbench: --vs '{s}' named twice — one arm per engine\n",
                .{s},
            ),
            .bad_positive_integer => |bad| std.debug.print(
                "zzzbench: {s} requires a positive integer (got '{s}')\n",
                .{ bad.flag, bad.value },
            ),
        }
    }
};

/// Parse `args` (including argv[0]) into options, filling `peer_buf`
/// with any `--probe` entries. On failure returns null and sets
/// `diag`; the caller decides whether and how to report it.
pub fn parse(args: []const []const u8, peer_buf: []Peer, diag: *Diagnostic) ?Options {
    var opts = Options{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i == 1 and std.mem.eql(u8, a, "devices")) {
            opts.command = .devices;
            opts.auto = true;
        } else if (i == 1 and std.mem.eql(u8, a, "models")) {
            opts.command = .models;
        } else if (i == 1 and std.mem.eql(u8, a, "engines")) {
            opts.command = .engines;
        } else if (i == 1 and std.mem.eql(u8, a, "compare")) {
            // The scriptable half of `--vs`: same coordinator, no TUI.
            opts.command = .compare;
        } else if ((i == 1 and std.mem.eql(u8, a, "help")) or isFlag(a, "--help") or isFlag(a, "-h")) {
            opts.command = .help;
        } else if (isFlag(a, "--vs") and i + 1 < args.len) {
            i += 1;
            switch (appendComparators(&opts, args[i])) {
                .ok => {},
                .empty => return reject(diag, .{ .unknown_comparator = args[i] }),
                .full => return reject(diag, .{ .too_many_comparators = max_comparators }),
                .baseline => |id| return reject(diag, .{ .baseline_comparator = id }),
                .duplicate => |id| return reject(diag, .{ .duplicate_comparator = id }),
            }
        } else if (isFlag(a, "--reps") and i + 1 < args.len) {
            i += 1;
            const reps = parsePositive(args[i]) orelse
                return reject(diag, .{ .bad_positive_integer = .{ .flag = a, .value = args[i] } });
            if (reps > comparison.reps_max) {
                return reject(diag, .{ .bad_positive_integer = .{ .flag = a, .value = args[i] } });
            }
            opts.reps = @intCast(reps);
        } else if (isFlag(a, "--stat") and i + 1 < args.len) {
            i += 1;
            opts.stat = comparison.Stat.parse(args[i]) orelse
                return reject(diag, .{ .bad_stat = args[i] });
        } else if (isFlag(a, "--vs") or isFlag(a, "--reps") or isFlag(a, "--stat")) {
            return reject(diag, .{ .missing_value = a });
        } else if (isFlag(a, "--threads") and i + 1 < args.len) {
            i += 1;
            opts.threads = parsePositive(args[i]) orelse
                return reject(diag, .{ .bad_positive_integer = .{ .flag = a, .value = args[i] } });
            opts.threads_set = true;
        } else if (isFlag(a, "--n-prompt-tokens") and i + 1 < args.len) {
            i += 1;
            opts.n_prompt = parsePositive(args[i]) orelse
                return reject(diag, .{ .bad_positive_integer = .{ .flag = a, .value = args[i] } });
        } else if (isFlag(a, "--n-generate-tokens") and i + 1 < args.len) {
            i += 1;
            opts.n_generate = parsePositive(args[i]) orelse
                return reject(diag, .{ .bad_positive_integer = .{ .flag = a, .value = args[i] } });
        } else if (isFlag(a, "--kernel") and i + 1 < args.len) {
            i += 1;
            opts.kernel = run_policy.Kernel.parse(args[i]) orelse
                return reject(diag, .{ .bad_kernel = args[i] });
        } else if (isFlag(a, "--threads") or isFlag(a, "--n-prompt-tokens") or
            isFlag(a, "--n-generate-tokens") or isFlag(a, "--kernel"))
        {
            return reject(diag, .{ .missing_value = a });
        } else if (isFlag(a, "--engine") and i + 1 < args.len) {
            i += 1;
            opts.engine = engine_mod.parseSpec(args[i]) orelse
                return reject(diag, .{ .bad_engine_spec = args[i] });
        } else if (isFlag(a, "--compare") and i + 1 < args.len) {
            i += 1;
            opts.compare = engine_mod.parseSpec(args[i]) orelse
                return reject(diag, .{ .bad_compare_spec = args[i] });
        } else if (isFlag(a, "--probe") and i + 1 < args.len) {
            i += 1;
            if (opts.peer_count >= peer_buf.len) {
                return reject(diag, .{ .too_many_probes = peer_buf.len });
            }
            const spec = peer_mod.parseSpec(args[i]) orelse
                return reject(diag, .{ .bad_probe_spec = args[i] });
            peer_buf[opts.peer_count] = .{ .label = spec.label, .endpoint = spec.endpoint };
            opts.peer_count += 1;
        } else if (isFlag(a, "--model") and i + 1 < args.len) {
            i += 1;
            opts.model = args[i];
        } else if (isFlag(a, "--model")) {
            return reject(diag, .{ .missing_value = a });
        } else if (isFlag(a, "--engine-bin") and i + 1 < args.len) {
            i += 1;
            opts.engine_bin = args[i];
        } else if (isFlag(a, "--engine-model") and i + 1 < args.len) {
            i += 1;
            opts.engine_model = args[i];
        } else if (isFlag(a, "--engine-dir") and i + 1 < args.len) {
            i += 1;
            if (opts.engine_dir_count >= opts.engine_dirs.len) {
                return reject(diag, .{ .too_many_engine_dirs = opts.engine_dirs.len });
            }
            opts.engine_dirs[opts.engine_dir_count] = args[i];
            opts.engine_dir_count += 1;
        } else if (isFlag(a, "--engine-dir")) {
            return reject(diag, .{ .missing_value = a });
        } else if (isFlag(a, "--probe-test")) {
            opts.probe_test = true;
        } else if (isFlag(a, "--logos")) {
            opts.logos = true;
        } else if (isFlag(a, "--logo") and i + 1 < args.len) {
            i += 1;
            opts.logo = args[i];
        } else if (isFlag(a, "--logo-at") and i + 1 < args.len) {
            i += 1;
            opts.logo_at = std.meta.stringToEnum(LogoAt, args[i]) orelse
                return reject(diag, .{ .bad_logo_at = args[i] });
        } else if (isFlag(a, "--credit") and i + 1 < args.len) {
            i += 1;
            opts.credit = args[i];
        } else if (isFlag(a, "--multi") and i + 1 < args.len) {
            i += 1;
            opts.multi = std.meta.stringToEnum(Multi, args[i]) orelse
                return reject(diag, .{ .bad_multi = args[i] });
        } else if (isFlag(a, "--prompt") and i + 1 < args.len) {
            i += 1;
            opts.prompt = args[i];
        } else if (isFlag(a, "--show-output")) {
            opts.show_output = true;
        } else if (isFlag(a, "--auto")) {
            opts.auto = true;
        } else if (isFlag(a, "--auto-android")) {
            opts.auto = true;
            opts.platform = if (opts.platform == .ios) .all else .android;
        } else if (isFlag(a, "--auto-ios")) {
            opts.auto = true;
            opts.platform = if (opts.platform == .android) .all else .ios;
        } else if (isFlag(a, "--platform") and i + 1 < args.len) {
            i += 1;
            opts.platform = std.meta.stringToEnum(PlatformFilter, args[i]) orelse
                return reject(diag, .{ .bad_platform = args[i] });
            opts.auto = true;
        } else if (std.mem.startsWith(u8, a, "--platform=")) {
            const value = a["--platform=".len..];
            opts.platform = std.meta.stringToEnum(PlatformFilter, value) orelse
                return reject(diag, .{ .bad_platform = value });
            opts.auto = true;
        } else if (isFlag(a, "--platform")) {
            return reject(diag, .{ .missing_value = a });
        } else if (isFlag(a, "--devices") and i + 1 < args.len) {
            i += 1;
            opts.devices = args[i];
            opts.auto = true;
        } else if (isFlag(a, "--devices")) {
            return reject(diag, .{ .missing_value = a });
        } else if (isFlag(a, "--all")) {
            opts.select_all = true;
            opts.auto = true;
        } else if (isFlag(a, "--replace-probe")) {
            // Only discovery bootstraps an Android probe, so the flag
            // means nothing without it.
            opts.replace_probe = true;
            opts.auto = true;
        } else if (isFlag(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a, "--engine-bin") or isFlag(a, "--engine-model") or
            isFlag(a, "--engine") or isFlag(a, "--compare") or isFlag(a, "--probe") or
            isFlag(a, "--logo") or isFlag(a, "--logo-at") or isFlag(a, "--credit") or
            isFlag(a, "--multi") or isFlag(a, "--prompt"))
        {
            return reject(diag, .{ .missing_value = a });
        } else if (std.mem.startsWith(u8, a, "-")) {
            return reject(diag, .{ .unknown_option = a });
        } else {
            opts.endpoint = a;
            opts.explicit_endpoint = true;
        }
    }

    // Dashboard options keep the same discovery flow as a bare launch.
    // Explicit connections, diagnostics, and comparisons use their endpoint.
    if (opts.command == .dashboard and !opts.explicit_endpoint and opts.peer_count == 0 and
        !opts.probe_test and !opts.logos and opts.comparator_count == 0)
    {
        opts.auto = true;
    }

    // Resolve the mark now rather than at first draw: a typo should
    // fail before the terminal goes into alt-screen, not blank a plate
    // silently forty frames in.
    if (opts.logo.len > 0) {
        const named = logos.byName(opts.logo) orelse
            return reject(diag, .{ .bad_logo = opts.logo });
        // A mark with no plate-sized art would parse and then draw
        // nothing, which reads as a broken flag rather than a mark
        // that cannot be drawn small enough.
        if (named.plate == null) return reject(diag, .{ .logo_has_no_plate = opts.logo });
    }
    return opts;
}

fn isFlag(arg: []const u8, flag: []const u8) bool {
    return std.mem.eql(u8, arg, flag);
}

const ComparatorResult = union(enum) {
    ok,
    empty,
    full,
    /// The baseline is already arm 0; naming it again would produce a
    /// run that reports 1.00x against itself having measured nothing.
    baseline: []const u8,
    /// Two arms with one id would write the same receipt paths.
    duplicate: []const u8,
};

/// `--vs a,b` and `--vs a --vs b` mean the same thing.
fn appendComparators(opts: *Options, list: []const u8) ComparatorResult {
    var added: usize = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const id = std.mem.trim(u8, raw, " ");
        if (id.len == 0) continue;
        if (std.mem.eql(u8, id, baseline_engine_id)) return .{ .baseline = id };
        for (opts.comparators[0..opts.comparator_count]) |existing| {
            if (std.mem.eql(u8, id, existing)) return .{ .duplicate = id };
        }
        if (opts.comparator_count >= max_comparators) return .full;
        opts.comparators[opts.comparator_count] = id;
        opts.comparator_count += 1;
        added += 1;
    }
    return if (added > 0) .ok else .empty;
}

fn parsePositive(value: []const u8) ?u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return null;
    return if (parsed > 0) parsed else null;
}

/// Record the diagnostic and evaluate to null, so call sites can write
/// `orelse return reject(...)` inline.
fn reject(diag: *Diagnostic, d: Diagnostic) ?Options {
    diag.* = d;
    return null;
}

fn parseForTest(args: []const []const u8, peer_buf: []Peer) ?Options {
    var diag: Diagnostic = .none;
    return parse(args, peer_buf, &diag);
}

test "help is a command, not an endpoint or an unknown option" {
    var peers: [max_peers]Peer = undefined;
    for ([_][]const u8{ "help", "--help", "-h" }) |arg| {
        const opts = parseForTest(&.{ "zzzbench", arg }, &peers).?;
        try std.testing.expectEqual(Command.help, opts.command);
        try std.testing.expect(!opts.auto);
        try std.testing.expect(!opts.explicit_endpoint);
    }
    const after_command = parseForTest(&.{ "zzzbench", "compare", "--help" }, &peers).?;
    try std.testing.expectEqual(Command.help, after_command.command);
}

test "every option in the help text is one the parser accepts" {
    var peers: [max_peers]Peer = undefined;
    var checked: usize = 0;
    var words = std.mem.tokenizeAny(u8, usage, " \n[],|");
    while (words.next()) |word| {
        if (!std.mem.startsWith(u8, word, "--")) continue;
        var diag: Diagnostic = .none;
        _ = parse(&.{ "zzzbench", word, "1" }, &peers, &diag);
        try std.testing.expect(std.meta.activeTag(diag) != .unknown_option);
        checked += 1;
    }
    try std.testing.expect(checked >= 15);
}

test "a bare endpoint is positional and marks itself explicit" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{ "zzzbench", "tcp:9000" }, &peers).?;
    try std.testing.expectEqualStrings("tcp:9000", opts.endpoint);
    try std.testing.expect(opts.explicit_endpoint);
    try std.testing.expectEqual(@as(usize, 0), opts.peer_count);
}

test "probe entries fill the peer buffer in order" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{ "zzzbench", "--probe", "pixel:tcp:7780", "--probe", "mac:tcp:7781" }, &peers).?;
    try std.testing.expectEqual(@as(usize, 2), opts.peer_count);
    try std.testing.expectEqualStrings("pixel", peers[0].label);
    try std.testing.expectEqualStrings("tcp:7781", peers[1].endpoint);
    try std.testing.expectEqualStrings(default_endpoint, opts.endpoint);
}

test "platform filters can be combined with manual targets" {
    var peers: [max_peers]Peer = undefined;
    const both = parseForTest(&.{ "zzzbench", "--auto-android", "--auto-ios" }, &peers).?;
    try std.testing.expectEqual(PlatformFilter.all, both.platform);
    const mixed = parseForTest(&.{ "zzzbench", "--auto-android", "tcp:9000", "--probe", "p:tcp:1" }, &peers).?;
    try std.testing.expect(mixed.explicit_endpoint);
    try std.testing.expectEqual(@as(usize, 1), mixed.peer_count);
}

test "--logos is a standalone mode, not an endpoint" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{ "zzzbench", "--logos" }, &peers).?;
    try std.testing.expect(opts.logos);
    try std.testing.expect(!opts.explicit_endpoint);
}

test "deferred --logo requests fail before device discovery" {
    var peers: [max_peers]Peer = undefined;
    var diag: Diagnostic = .none;
    for ([_][]const u8{ "zzz", "prismml", "gemma", "nope" }) |id| {
        try std.testing.expect(parse(&.{ "zzzbench", "--logo", id }, &peers, &diag) == null);
        try std.testing.expectEqualStrings(id, diag.bad_logo);
    }
    try std.testing.expectEqualStrings("", parseForTest(&.{"zzzbench"}, &peers).?.logo);
    try std.testing.expect(parse(&.{ "zzzbench", "--logo-at", "sideways" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("sideways", diag.bad_logo_at);
    const left = parseForTest(&.{ "zzzbench", "--logo-at", "left" }, &peers).?;
    try std.testing.expectEqual(LogoAt.left, left.logo_at);
}

test "--multi picks a layout and defaults to bands" {
    var peers: [max_peers]Peer = undefined;
    var diag: Diagnostic = .none;

    try std.testing.expectEqual(Multi.bands, parseForTest(&.{"zzzbench"}, &peers).?.multi);
    try std.testing.expectEqual(
        Multi.race,
        parseForTest(&.{ "zzzbench", "--multi", "race" }, &peers).?.multi,
    );
    try std.testing.expect(parse(&.{ "zzzbench", "--multi", "grid" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("grid", diag.bad_multi);
}

test "a malformed engine spec is rejected rather than defaulted" {
    var peers: [max_peers]Peer = undefined;
    var diag: Diagnostic = .none;
    try std.testing.expect(parse(&.{ "zzzbench", "--engine", "zzz" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("zzz", diag.bad_engine_spec);

    const opts = parseForTest(&.{ "zzzbench", "--engine", "zzz:20.41" }, &peers).?;
    try std.testing.expectEqualStrings("zzz", opts.engine.name);
}

test "unified discovery flags compose with manual peers" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{ "zzzbench", "--auto", "--probe", "pi:tcp:192.0.2.2:7779" }, &peers).?;
    try std.testing.expect(opts.auto);
    try std.testing.expectEqual(@as(usize, 1), opts.peer_count);
    try std.testing.expectEqualStrings("pi", peers[0].label);
}

test "auto flags select platform-filtered discovery" {
    var peers: [max_peers]Peer = undefined;
    const android = parseForTest(&.{ "zzzbench", "--auto-android" }, &peers).?;
    try std.testing.expect(android.auto);
    try std.testing.expectEqual(PlatformFilter.android, android.platform);

    const ios = parseForTest(&.{ "zzzbench", "--auto-ios" }, &peers).?;
    try std.testing.expect(ios.auto);
    try std.testing.expectEqual(PlatformFilter.ios, ios.platform);
}

test "devices subcommand and selectors parse without becoming endpoints" {
    var peers: [max_peers]Peer = undefined;
    const listed = parseForTest(&.{ "zzzbench", "devices", "--json" }, &peers).?;
    try std.testing.expectEqual(Command.devices, listed.command);
    try std.testing.expect(listed.json);
    try std.testing.expect(!listed.explicit_endpoint);

    const selected = parseForTest(&.{ "zzzbench", "--devices", "pixel,iphone" }, &peers).?;
    try std.testing.expect(selected.auto);
    try std.testing.expectEqualStrings("pixel,iphone", selected.devices);

    const all = parseForTest(&.{ "zzzbench", "--all" }, &peers).?;
    try std.testing.expect(all.auto);
    try std.testing.expect(all.select_all);
}

test "--replace-probe opts in to stopping a foreign probe and keeps discovery on" {
    var peers: [max_peers]Peer = undefined;
    try std.testing.expect(!parseForTest(&.{"zzzbench"}, &peers).?.replace_probe);

    const opts = parseForTest(&.{ "zzzbench", "--replace-probe" }, &peers).?;
    try std.testing.expect(opts.replace_probe);
    // Any other argument turns bare discovery off; this one only
    // matters to discovery, so it must not.
    try std.testing.expect(opts.auto);
    try std.testing.expect(!opts.explicit_endpoint);
}

test "--kernel pins the dispatcher and rejects a name the engine lacks" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{ "zzzbench", "--kernel", "SDOT" }, &peers).?;
    try std.testing.expectEqual(run_policy.Kernel.sdot, opts.kernel);
    try std.testing.expectEqual(run_policy.Kernel.auto, parseForTest(&.{"zzzbench"}, &peers).?.kernel);

    var diag: Diagnostic = .none;
    try std.testing.expect(parse(&.{ "zzzbench", "--kernel", "neon" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("neon", diag.bad_kernel);

    diag = .none;
    try std.testing.expect(parse(&.{ "zzzbench", "--kernel" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("--kernel", diag.missing_value);
}

test "--model names a choice the picker would otherwise have to make" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{ "zzzbench", "--model", "Sample-8B" }, &peers).?;
    try std.testing.expectEqualStrings("Sample-8B", opts.model);
    try std.testing.expect(!opts.explicit_endpoint);

    var diag: Diagnostic = .none;
    try std.testing.expect(parse(&.{ "zzzbench", "--model" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("--model", diag.missing_value);
}

test "models subcommand and run policy flags remain CLI controlled" {
    var peers: [max_peers]Peer = undefined;
    const listed = parseForTest(&.{ "zzzbench", "models", "--json" }, &peers).?;
    try std.testing.expectEqual(Command.models, listed.command);
    try std.testing.expect(listed.json);
    try std.testing.expect(!listed.explicit_endpoint);

    const run = parseForTest(&.{
        "zzzbench", "--threads", "6", "--n-prompt-tokens", "256", "--n-generate-tokens", "64",
    }, &peers).?;
    try std.testing.expectEqual(@as(u32, 6), run.threads);
    try std.testing.expectEqual(@as(u32, 256), run.n_prompt);
    try std.testing.expectEqual(@as(u32, 64), run.n_generate);
}

test "engines subcommand accepts JSON and ordered override directories" {
    var peers: [max_peers]Peer = undefined;
    const listed = parseForTest(&.{
        "zzzbench", "engines", "--json", "--engine-dir", "/team", "--engine-dir", "/local",
    }, &peers).?;
    try std.testing.expectEqual(Command.engines, listed.command);
    try std.testing.expect(listed.json);
    try std.testing.expectEqual(@as(usize, 2), listed.engine_dir_count);
    try std.testing.expectEqualStrings("/team", listed.engine_dirs[0]);
    try std.testing.expectEqualStrings("/local", listed.engine_dirs[1]);
    try std.testing.expect(!listed.explicit_endpoint);
}

test "bare invocation enters unified discovery" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{"zzzbench"}, &peers).?;
    try std.testing.expect(opts.auto);
}

test "dashboard parameters keep automatic device discovery" {
    var peers: [max_peers]Peer = undefined;
    for ([_][]const []const u8{
        &.{ "zzzbench", "--model", "example-model" },
        &.{ "zzzbench", "--threads", "6" },
        &.{ "zzzbench", "--engine-bin", "/runtime/zzz" },
        &.{ "zzzbench", "--prompt", "Hello", "--show-output" },
    }) |args| {
        try std.testing.expect(parseForTest(args, &peers).?.auto);
    }
}

test "automatic discovery preserves explicit connections and standalone commands" {
    var peers: [max_peers]Peer = undefined;
    for ([_][]const []const u8{
        &.{ "zzzbench", "tcp:9000", "--threads", "6" },
        &.{ "zzzbench", "--probe", "phone:tcp:9000" },
        &.{ "zzzbench", "--probe-test" },
        &.{ "zzzbench", "--logos" },
        &.{ "zzzbench", "models", "--json" },
        &.{ "zzzbench", "engines", "--json" },
        &.{ "zzzbench", "compare", "--model", "/models/test.gguf", "--vs", "llamacpp" },
        &.{ "zzzbench", "--model", "/models/test.gguf", "--vs", "llamacpp" },
    }) |args| {
        try std.testing.expect(!parseForTest(args, &peers).?.auto);
    }
    try std.testing.expect(parseForTest(&.{ "zzzbench", "devices", "--json" }, &peers).?.auto);
    try std.testing.expect(parseForTest(&.{ "zzzbench", "--auto", "tcp:9000" }, &peers).?.auto);
}

test "discovery flags report missing values instead of becoming endpoints" {
    var peers: [max_peers]Peer = undefined;
    var diag: Diagnostic = .none;
    try std.testing.expect(parse(&.{ "zzzbench", "--devices" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("--devices", diag.missing_value);
    try std.testing.expect(parse(&.{ "zzzbench", "--platform" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("--platform", diag.missing_value);
}

test "invalid dashboard flags are rejected before connecting to a probe" {
    var peers: [max_peers]Peer = undefined;
    var diag: Diagnostic = .none;
    for ([_][]const u8{
        "--engine-bin", "--engine-model", "--engine", "--compare", "--probe",
        "--logo",       "--logo-at",      "--credit", "--multi",   "--prompt",
    }) |flag| {
        try std.testing.expect(parse(&.{ "zzzbench", flag }, &peers, &diag) == null);
        try std.testing.expectEqualStrings(flag, diag.missing_value);
    }
    try std.testing.expect(parse(&.{ "zzzbench", "--platfrom", "android" }, &peers, &diag) == null);
    try std.testing.expectEqualStrings("--platfrom", diag.unknown_option);
}

test "compare takes a run policy, and --vs accepts either spelling" {
    var peers: [max_peers]Peer = undefined;
    const opts = parseForTest(&.{
        "zzzbench", "compare",         "--model", "/data/local/tmp/model.gguf",
        "--vs",     "llamacpp,cactus", "--vs",    "mystery",
        "--reps",   "5",               "--stat",  "best",
        "--json",
    }, &peers).?;

    try std.testing.expectEqual(Command.compare, opts.command);
    try std.testing.expectEqual(@as(usize, 3), opts.comparator_count);
    try std.testing.expectEqualStrings("llamacpp", opts.comparators[0]);
    try std.testing.expectEqualStrings("cactus", opts.comparators[1]);
    try std.testing.expectEqualStrings("mystery", opts.comparators[2]);
    try std.testing.expectEqual(@as(u8, 5), opts.reps);
    try std.testing.expectEqual(comparison.Stat.best, opts.stat);
    try std.testing.expect(opts.json);
}

test "a comparison refuses a policy it cannot apply" {
    var peers: [max_peers]Peer = undefined;
    var diag: Diagnostic = .none;
    try std.testing.expect(parse(
        &.{ "zzzbench", "compare", "--stat", "median" },
        &peers,
        &diag,
    ) == null);
    try std.testing.expectEqualStrings("median", diag.bad_stat);

    diag = .none;
    try std.testing.expect(parse(
        &.{ "zzzbench", "compare", "--vs", "a,b,c,d,e" },
        &peers,
        &diag,
    ) == null);
    try std.testing.expectEqual(@as(usize, max_comparators), diag.too_many_comparators);

    // 0 repetitions is not a faster comparison, it is no comparison.
    diag = .none;
    try std.testing.expect(parse(
        &.{ "zzzbench", "compare", "--reps", "0" },
        &peers,
        &diag,
    ) == null);

    // The baseline is arm 0 already; `--vs zzz` would report 1.00x
    // against itself having measured no comparator.
    diag = .none;
    try std.testing.expect(parse(
        &.{ "zzzbench", "compare", "--vs", "llamacpp,zzz" },
        &peers,
        &diag,
    ) == null);
    try std.testing.expectEqualStrings(baseline_engine_id, diag.baseline_comparator);

    // Two arms with one id would write the same receipt paths.
    diag = .none;
    try std.testing.expect(parse(
        &.{ "zzzbench", "compare", "--vs", "llamacpp", "--vs", "llamacpp" },
        &peers,
        &diag,
    ) == null);
    try std.testing.expectEqualStrings("llamacpp", diag.duplicate_comparator);
}
