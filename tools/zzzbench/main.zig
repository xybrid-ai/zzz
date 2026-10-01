//! zzzbench — TUI bench client.
//!
//! Connects to one or more `zzzprobe` telemetry daemons, renders a
//! live dashboard, and can ask each probe (or a host-local binary) to
//! run a benchmark.
//!
//! Structure:
//!   cli.zig            argument parsing
//!   compare_command.zig  headless `compare` and the dashboard's `--vs`
//!   wire.zig           socket plumbing + frame extraction
//!   engine.zig         engine state and the host-local runner
//!   peer.zig           one comparison device
//!   discovery/         --auto-android / --auto-ios device discovery
//!   probe_test.zig     --probe-test wire diagnostic
//!   logos_preview.zig  --logos artwork availability
//!   ui/                everything that draws (see ui/dashboard.zig)
//!   tuiz package      the reusable terminal toolkit ui/ draws with
//!
//! This file is the event loop: poll sockets, stdin, and the engine
//! pipe; fold what arrives into `Session`; redraw on event edges.
//!
//! Run:
//!   # terminal A:
//!   /absolute/path/to/zzzprobe /tmp/zzzprobe.sock
//!   # terminal B:
//!   zig build zzzbench -- /tmp/zzzprobe.sock

const std = @import("std");
const proto = @import("proto");
const net = @import("net_compat");
const time_compat = @import("time_compat");
const tui = @import("tuiz");

const cli = @import("cli.zig");
const compare_command = @import("compare_command.zig");
const comparison = @import("comparison.zig");
const device_picker = @import("device_picker.zig");
const engine_mod = @import("engine.zig");
const engine_manifest = @import("engine_manifest.zig");
const engine_registry = @import("engine_registry.zig");
const device_comparison = @import("device_comparison.zig");
const device = @import("discovery/device.zig");
const logos_preview = @import("logos_preview.zig");
const model_catalog = @import("model_catalog.zig");
const model_picker = @import("model_picker.zig");
const params_editor = @import("params_editor.zig");
const picker_screen = @import("ui/picker_screen.zig");
const model_sync = @import("model_sync.zig");
const peer_mod = @import("peer.zig");
const probe_test = @import("probe_test.zig");
const run_policy = @import("run_policy.zig");
const RunPolicy = run_policy.RunPolicy;
const tty = @import("tty.zig");
const wire = @import("wire.zig");
const Peer = peer_mod.Peer;
const Series = @import("series.zig").Series;
const Output = @import("output.zig").Output;

const catalog = @import("discovery/catalog.zig");
const discovery_setup = @import("discovery/setup.zig");

const credit_mod = @import("ui/credit.zig");
const dashboard = @import("ui/dashboard.zig");
const logos = @import("ui/logos.zig");
const theme = @import("ui/theme.zig");
const UiState = @import("ui/state.zig").UiState;

/// Poll ceiling, so flash messages expire and the screen stays
/// responsive even when every probe is silent.
const poll_timeout_ms: i32 = 100;

/// Engine reports arrive faster than renders when a slow terminal
/// gates the loop through stdout backpressure. A one-frame buffer
/// drained 64 B per cycle falls minutes behind and the TUI replays a
/// long-dead run; this holds a burst and the drain loop catches up.
const report_burst_frames: usize = 64;

/// How long `--model` waits for peers to finish connecting before
/// planning where the model goes. Long enough for an adb-forwarded
/// probe to answer, short enough that a genuinely absent peer does not
/// stall a scripted capture.
const settle_deadline_ms: usize = 3000;
const settle_step_ms: usize = 50;

/// Fallback size when the winsize ioctl fails (non-tty stdout, odd
/// harness), so piped runs still produce readable output.
const default_winsize = std.posix.winsize{ .col = 86, .row = 24, .xpixel = 0, .ypixel = 0 };

pub fn main(init: std.process.Init) !void {
    // Debug builds get the leak-checking allocator; release builds a fast one.
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var peer_buf: [cli.max_peers]Peer = undefined;
    var diag: cli.Diagnostic = .none;
    var opts = cli.parse(args, &peer_buf, &diag) orelse {
        diag.report();
        std.process.exit(2);
    };

    if (opts.command == .help) {
        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
        try stdout.interface.writeAll(cli.usage);
        try stdout.interface.flush();
        return;
    }

    // Report artwork availability before any probe or device discovery.
    if (opts.logos) {
        logos_preview.run() catch |e| {
            std.debug.print("zzzbench --logos: {s}\n", .{@errorName(e)});
            std.process.exit(2);
        };
        return;
    }

    // The working directory: relative run output and the development
    // engine fallback (`zig-out/bin/zzz`) resolve against it.
    const workspace_path = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(workspace_path);

    if (opts.command == .devices) {
        try listDevices(allocator, init.arena.allocator(), init.io, opts);
        return;
    }
    if (opts.command == .models) {
        listModels(allocator, init.arena.allocator(), init.io, workspace_path, init.environ_map, opts.json) catch |err| {
            std.debug.print("zzzbench: model discovery failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        return;
    }
    if (opts.command == .engines) {
        var diagnostic: engine_manifest.Diagnostic = .{};
        listEngines(
            allocator,
            init.arena.allocator(),
            init.io,
            init.environ_map,
            opts,
            &diagnostic,
        ) catch |err| {
            compare_command.reportEngineRegistryError(err, diagnostic);
            std.process.exit(2);
        };
        return;
    }

    // Both the build launcher and an installed TUI can find the local
    // runner automatically. An explicit CLI path always wins.
    if (opts.engine_bin.len == 0) {
        if (init.environ_map.get("ZZZBENCH_ENGINE_BIN")) |path| opts.engine_bin = path;
    }
    opts.engine_bin_override = opts.engine_bin.len > 0;
    var engine_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (opts.engine_bin.len == 0) {
        // Where this executable is, not what it was called. Started by
        // name through `PATH`, argv[0] is a bare `zzzbench` with no
        // directory in it, and the runner installed beside it was never
        // looked for.
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = if (std.process.executablePath(init.io, &exe_buf)) |len| exe_buf[0..len] else |_| args[0];
        if (engine_mod.defaultBin(init.io, exe_path, workspace_path, null, &engine_bin_buf)) |p| opts.engine_bin = p;
    }

    // `--vs` on the dashboard is the same coordinator with a screen in
    // front of it, not a second implementation.
    if (opts.command == .dashboard and opts.comparator_count > 0) {
        compare_command.runComparisonScreen(
            allocator,
            init.arena.allocator(),
            init.io,
            init.environ_map,
            workspace_path,
            opts,
            peer_buf[0..opts.peer_count],
        ) catch |err| {
            compare_command.reportComparisonError(err);
            std.process.exit(2);
        };
        return;
    }

    if (opts.command == .compare) {
        compare_command.runComparison(
            allocator,
            init.arena.allocator(),
            init.io,
            init.environ_map,
            workspace_path,
            opts,
            peer_buf[0..opts.peer_count],
        ) catch |err| {
            compare_command.reportComparisonError(err);
            std.process.exit(2);
        };
        return;
    }

    var model_target_buf: [model_sync.max_targets]model_sync.Target = @splat(.{ .kind = .unsupported });
    var model_target_count: usize = @min(opts.peer_count + 1, model_target_buf.len);
    if (opts.auto) {
        const discovered = discovery_setup.run(
            allocator,
            init.arena.allocator(),
            init.io,
            workspace_path,
            opts,
            &peer_buf,
        ) catch |err| {
            reportDiscoveryError(err, opts);
            if (err == error.SelectionCancelled) return;
            std.process.exit(2);
        };
        opts.endpoint = discovered.endpoint;
        opts.peer_count = discovered.peer_count;
        model_target_buf = discovered.model_targets;
        model_target_count = discovered.model_target_count;
        std.debug.print("zzzbench: selected {d} discovered device{s}", .{
            discovered.discovered_count,
            if (discovered.discovered_count == 1) @as([]const u8, "") else "s",
        });
        if (discovered.bootstrapped_count > 0) {
            std.debug.print(" ({d} probe{s} bootstrapped)", .{
                discovered.bootstrapped_count,
                if (discovered.bootstrapped_count == 1) @as([]const u8, "") else "s",
            });
        }
        std.debug.print("\n", .{});
    }

    const peers: []Peer = peer_buf[0..opts.peer_count];

    if (opts.probe_test) {
        const code = probe_test.run(opts.endpoint, peers) catch |e| {
            std.debug.print("zzzbench probe-test: {s}\n", .{@errorName(e)});
            std.process.exit(2);
        };
        std.process.exit(code);
    }

    // `Session` holds `hello_buf`, and `engine.model` slices into it,
    // so it must never be copied after `connect()`. Declared here and
    // only ever used through a pointer.
    const cache_root = try cacheRoot(init.arena.allocator(), workspace_path, init.environ_map);
    var session = Session.init(
        opts,
        peers,
        model_target_buf[0..model_target_count],
        allocator,
        init.arena.allocator(),
        init.io,
        workspace_path,
        cache_root,
        init.environ_map,
    );
    // Armed before `connect()`, not after: discovery hands over peers
    // that already hold open sockets, and the session owns them from
    // here whether or not the primary turns out to be reachable.
    defer session.deinit();
    session.connect() catch |e| {
        // The endpoint can carry a discovery-supplied hostname.
        var endpoint_buf: [256]u8 = undefined;
        std.debug.print(
            "zzzbench: cannot connect to {s}: {s}\n  is zzzprobe running?\n",
            .{ tui.sanitize.into(&endpoint_buf, opts.endpoint), @errorName(e) },
        );
        std.process.exit(2);
    };

    run(&session) catch |err| switch (err) {
        // Already explained on stderr by the code that raised it. A
        // stack trace would bury that, and a scripted capture wants a
        // non-zero exit it can test.
        error.ModelNotFound,
        error.ModelScanFailed,
        error.ModelSyncFailed,
        error.ModelSelectFailed,
        error.ModelSelectionUnavailable,
        error.UnsupportedDecodeModel,
        => std.process.exit(2),
        else => return err,
    };
}

fn listModels(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    environ: *const std.process.Environ.Map,
    json: bool,
) !void {
    const models = try model_catalog.scan(gpa, arena, io, .{
        .workspace_path = workspace_path,
        .home = environ.get("HOME"),
        .config_home = environ.get("XDG_CONFIG_HOME"),
    });
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    if (json) try model_catalog.writeJson(&stdout.interface, models) else try model_catalog.writeTable(&stdout.interface, models);
    try stdout.interface.flush();
}

fn listEngines(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    opts: cli.Options,
    diagnostic: *engine_manifest.Diagnostic,
) !void {
    const manifests = try engine_registry.load(gpa, arena, io, .{
        .home = environ.get("HOME"),
        .config_home = environ.get("XDG_CONFIG_HOME"),
        .engine_dirs = opts.engine_dirs[0..opts.engine_dir_count],
    }, diagnostic);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    if (opts.json) {
        try engine_registry.writeJson(&stdout.interface, manifests);
    } else {
        try engine_registry.writeTable(&stdout.interface, manifests);
    }
    try stdout.interface.flush();
}

/// Parent of the `zzzbench/` cache directory, which records models already
/// pushed to devices. Follows XDG; without `HOME` it falls back to `./.cache`.
fn cacheRoot(
    arena: std.mem.Allocator,
    workspace_path: []const u8,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("XDG_CACHE_HOME")) |path| return path;
    if (environ.get("HOME")) |home| return std.fs.path.join(arena, &.{ home, ".cache" });
    return std.fs.path.join(arena, &.{ workspace_path, ".cache" });
}

fn listDevices(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    opts: cli.Options,
) !void {
    const filter: catalog.Filter = switch (opts.platform) {
        .all => .all,
        .android => .android,
        .ios => .ios,
        .host => .host,
    };
    const scope: []const u8 = switch (opts.platform) {
        .all => "Android · iOS · this Mac",
        .android => "Android",
        .ios => "iOS",
        .host => "this Mac",
    };
    var search_status = device_picker.SearchStatus.begin(scope);
    defer search_status.clear();
    const candidates = catalog.scan(gpa, arena, io, filter) catch |err| {
        reportDiscoveryError(err, opts);
        return;
    };
    search_status.clear();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    if (opts.json) {
        try catalog.writeJson(&stdout.interface, candidates);
    } else {
        try catalog.writeTable(&stdout.interface, candidates);
    }
    try stdout.interface.flush();
}

fn reportDiscoveryError(err: anyerror, opts: cli.Options) void {
    switch (err) {
        error.InteractiveSelectionNeedsTty => std.debug.print(
            "zzzbench: device selection needs a terminal; use --devices ID[,ID...] or --all\n",
            .{},
        ),
        error.DeviceNotFound => std.debug.print(
            "zzzbench: --devices contains an unknown id ('{s}'); run `zzzbench devices`\n",
            .{opts.devices},
        ),
        error.DeviceUnavailable => std.debug.print(
            "zzzbench: selected device is not ready ('{s}'); run `zzzbench devices` to inspect its transport state\n",
            .{opts.devices},
        ),
        error.AdbMissing => std.debug.print("zzzbench: Android discovery requires `adb` on PATH\n", .{}),
        error.AdbDevicesFailed => std.debug.print("zzzbench: `adb devices -l` failed\n", .{}),
        error.DevicectlMissing => std.debug.print("zzzbench: iOS discovery requires `xcrun devicectl`\n", .{}),
        error.DevicectlDevicesFailed => std.debug.print("zzzbench: `xcrun devicectl list devices` failed\n", .{}),
        error.NoDevices, error.NoDevicesSelected => std.debug.print(
            "zzzbench: no selectable devices found; run `zzzbench devices` to inspect discovery\n",
            .{},
        ),
        error.TooManyDevices => std.debug.print(
            "zzzbench: selection exceeds the five-device dashboard limit\n",
            .{},
        ),
        error.SelectionCancelled => std.debug.print("zzzbench: device selection cancelled\n", .{}),
        error.ProbeBootstrapFailed => std.debug.print(
            "zzzbench: Android probe launch did not pass its Hello handshake; inspect the workspace probe.log under /data/local/tmp/zzz-*\n",
            .{},
        ),
        error.IncompatibleProbeRunning => std.debug.print(
            "zzzbench: another probe is still holding this Android port. It does not match\n" ++
                "  the supplied runtime, so it cannot be reused for this benchmark.\n" ++
                "  Stop it on the device and retry.\n",
            .{},
        ),
        else => std.debug.print("zzzbench: device setup failed: {s}\n", .{@errorName(err)}),
    }
}

/// Live state for one bench session: the primary connection, the
/// sample histories, the engine, and everything the UI reads.
const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    endpoint: []const u8,
    peers: []Peer,
    model_targets: []const model_sync.Target,
    model_paths: [model_sync.max_targets][]const u8 = @splat(""),
    workspace_path: []const u8,
    cache_root: []const u8,
    home: ?[]const u8,
    config_home: ?[]const u8,
    environ: *const std.process.Environ.Map,
    launch_options: cli.Options,

    engine: engine_mod.Engine,
    compare: ?engine_mod.Engine,
    runner: engine_mod.Runner,
    engine_bin: []const u8,
    engine_model: []const u8,
    selected_model: ?model_catalog.Model = null,
    model_sync_required: bool = false,
    /// Title-bar model name to use when the probe's Hello carries
    /// none. Held separately rather than assigned once, because
    /// `engine.model` is overwritten with a slice into `hello_buf` on
    /// every Hello — on a reconnect whose Hello has no name, the old
    /// slice would point into a refilled buffer and render garbage.
    fallback_model_name: []const u8,

    /// The mark `--logo` named, resolved once at parse time.
    logo: ?logos.Named,
    logo_at: cli.LogoAt,
    /// `--credit` override for the plate's middle line.
    credit_line: []const u8,
    /// Which multi-device layout to draw.
    multi: cli.Multi,
    /// `--prompt`: what every engine in the window is asked to
    /// continue. Empty leaves them on their synthetic sequence, in
    /// which case there is no text worth showing.
    prompt: []const u8,
    /// What each device is asked to run, indexed like `model_targets`
    /// and the socket list. One per device on purpose — see
    /// `run_policy.zig`.
    policies: [model_sync.max_targets]RunPolicy,
    /// `--model`: a choice made on the command line instead of through
    /// the picker, applied once the alternate screen is up.
    pending_model: []const u8,
    /// Set once the host engine's build mode has been reported, so a
    /// long session does not repeat the warning every poll.
    warned_build_mode: bool = false,
    /// Whether this device's thread count was chosen by the operator
    /// (`--threads`, or the params grid) rather than left at the
    /// default. A chosen value is never overwritten by what the device
    /// reports about itself.
    threads_pinned: [model_sync.max_targets]bool,

    ui: UiState = .{},

    /// An empty Hello until a probe sends one, never `undefined`: the
    /// dashboard reads the names in here on every frame, and a session
    /// installed by `c` is drawn before its primary has connected — or
    /// if it never does. Undefined, that frame showed whatever the
    /// previous session left in this memory, under the new device.
    hello_buf: [@sizeOf(proto.Hello)]u8 align(@alignOf(proto.Hello)) = std.mem.toBytes(proto.Hello{}),
    sock_opt: ?std.posix.fd_t = null,
    read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = undefined,
    read_pos: usize = 0,
    next_retry_at_ns: i128 = 0,
    backoff_ms: i64 = wire.reconnect_min_ms,

    /// Sentinel frame (dashes everywhere) rather than zeroes, so the
    /// first paint reads "no data yet" instead of fake 0% / 0°C.
    current: proto.TelemetryFrame = proto.sentinelFrame(0),
    hardware_info: proto.HardwareInfo = .{},
    have_hardware_info: bool = false,

    /// The hero's two lanes. Both are pushed on the same telemetry
    /// tick, so column N of one lane covers the same instant as column
    /// N of the other and the pair can be read against each other
    /// vertically.
    tok_lane: Series = .{},
    prime_lane: Series = .{},
    /// Per-report throughput for split view, retained after completion just
    /// like each peer's history. A fast Mac can finish between telemetry ticks.
    race_tok_series: Series = .{},

    /// Owns the device set a `c` press installed: the peer array, the
    /// targets, and their labels and endpoints. One generation at a
    /// time — `deinit` releases it, and `replaceDevices` runs `deinit`.
    /// Null while the session is still on the devices it was launched
    /// with, which `main` owns.
    device_arena: ?std.heap.ArenaAllocator = null,

    /// Burst buffer for the host-local engine's stdout. Sized to hold a
    /// run of reports *and* at least one whole frame of any kind — a
    /// buffer smaller than the largest legal frame would stall the pump
    /// on a frame it could never assemble.
    report_buf: [@max(report_burst_frames * @sizeOf(proto.EngineReport), proto.max_frame_bytes)]u8 align(@alignOf(proto.TelemetryFrame)) = undefined,
    report_pos: usize = 0,

    /// Text the host-local engine generated this run.
    output: Output = .{},

    fn init(
        opts: cli.Options,
        peers: []Peer,
        model_targets: []const model_sync.Target,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        io: std.Io,
        workspace_path: []const u8,
        cache_root: []const u8,
        environ: *const std.process.Environ.Map,
    ) Session {
        // Local-engine fallback name: when the bench connects to a
        // probe with no engine of its own but is configured with
        // --engine-bin/--engine-model for the host dev loop, derive
        // the title-bar model name from the local engine path.
        const fallback = if (opts.engine_model.len > 0)
            proto.deriveModelName(opts.engine_model)
        else
            "";
        var engine = opts.engine;
        engine.model = fallback;
        return .{
            .io = io,
            .allocator = allocator,
            .arena = arena,
            .endpoint = opts.endpoint,
            .peers = peers,
            .model_targets = model_targets,
            .workspace_path = workspace_path,
            .cache_root = cache_root,
            .home = environ.get("HOME"),
            .config_home = environ.get("XDG_CONFIG_HOME"),
            .environ = environ,
            .launch_options = opts,
            .engine = engine,
            .compare = opts.compare,
            .runner = .{ .allocator = allocator, .io = io },
            .engine_bin = opts.engine_bin,
            .engine_model = opts.engine_model,
            .fallback_model_name = fallback,
            .logo = if (opts.logo.len > 0) logos.byName(opts.logo) else null,
            .logo_at = opts.logo_at,
            .credit_line = opts.credit,
            .multi = opts.multi,
            .prompt = opts.prompt,
            .policies = @splat(.{
                .threads = opts.threads,
                .n_prompt = opts.n_prompt,
                .n_generate = opts.n_generate,
                .kernel = opts.kernel,
            }),
            .threads_pinned = @splat(opts.threads_set),
            .pending_model = opts.model,
            .ui = .{ .show_output = opts.show_output },
        };
    }

    fn deinit(self: *Session) void {
        self.runner.stop();
        for (self.peers) |*peer| peer.deinit();
        if (self.sock_opt) |s| net.close(s);
        self.sock_opt = null;
        // Last: `peers` and `endpoint` may live in it.
        if (self.device_arena) |*owned| owned.deinit();
        self.device_arena = null;
    }

    fn helloPtr(self: *const Session) *const proto.Hello {
        return @ptrCast(@alignCast(&self.hello_buf));
    }

    /// Hello's model name wins over the local-engine fallback — the
    /// probe knows what file it is actually going to spawn. The slice
    /// points into `hello_buf`, which lives as long as the session.
    fn adoptHelloModelName(self: *Session) void {
        const name = proto.Hello.nameSlice(&self.helloPtr().model_name);
        self.engine.model = if (name.len > 0) name else self.fallback_model_name;
        self.adoptCoreCount(0, self.helloPtr());
    }

    /// Say so, once, when the host-local engine is not a ReleaseFast
    /// build.
    ///
    /// The engine is a supplied binary, and `zzz` defaults to Debug,
    /// so a bare `zig build` leaves exactly the engine this catches at
    /// `zig-out/bin/zzz`. A Debug binary benched against a phone is not
    /// a comparison, and nothing else in the session could tell. Host
    /// only: an Android engine's banner goes to the probe's stderr.
    fn warnDebugEngine(self: *Session) bool {
        if (self.warned_build_mode) return false;
        const mode = self.runner.buildMode() orelse return false;
        self.warned_build_mode = true;
        if (std.mem.eql(u8, mode, "ReleaseFast")) return false;
        self.ui.flashFmt("host engine is a {s} build — rebuild with -Doptimize=ReleaseFast", .{mode});
        return true;
    }

    /// Give peers a moment to finish connecting.
    ///
    /// `--model` plans its sinks from what each device says it can do,
    /// and a peer that has not answered yet is refused — which would
    /// turn a scripted capture into a silent no-op.
    ///
    /// The not-ready state is `sock_opt == null`, not "connected but
    /// silent": `Peer.tryReconnect` publishes the socket only *after*
    /// `connectAndReadHello` has read the whole Hello, so a peer still
    /// dialling has no socket at all. Waiting on the other condition
    /// returned immediately and made this whole function a no-op.
    fn settlePeers(self: *Session) void {
        var waited_ms: usize = 0;
        while (waited_ms < settle_deadline_ms) : (waited_ms += settle_step_ms) {
            var pending = false;
            for (self.peers) |*peer| {
                if (peer.sock_opt == null) {
                    peer.tryReconnect();
                    if (peer.sock_opt == null) pending = true;
                } else if (!peer.have_hello) {
                    _ = pumpPeer(peer, std.posix.POLL.IN);
                    if (!peer.have_hello) pending = true;
                }
            }
            if (!pending) return;
            std.Io.sleep(self.io, .fromMilliseconds(settle_step_ms), .awake) catch return;
        }
    }

    /// Fold every connected peer's reported core count into its
    /// policy. Cheap enough to run on any dirty frame: at most four
    /// peers, each a couple of comparisons.
    fn adoptPeerCoreCounts(self: *Session) void {
        for (self.peers, 0..) |*peer, peer_index| {
            if (!peer.have_hello) continue;
            self.adoptCoreCount(peer_index + 1, peer.helloPtr());
        }
    }

    /// Take the device's own performance-core count as this device's
    /// thread default. Only while the operator has not chosen one, and
    /// only when the probe reports it. Zero means unknown, including
    /// on the synthetic macOS path.
    fn adoptCoreCount(self: *Session, index: usize, hello: *const proto.Hello) void {
        if (index >= self.policies.len) return;
        if (self.threads_pinned[index]) return;
        if (hello.perf_cores == 0) return;
        self.policies[index].threads = hello.perf_cores;
    }

    fn connect(self: *Session) !void {
        const sock = try wire.connectAndReadHello(self.endpoint, &self.hello_buf);
        wire.requestHardwareInfo(sock) catch {};
        self.sock_opt = sock;
        self.adoptHelloModelName();
    }

    /// Mark the probe as disconnected and arm the next reconnect
    /// attempt. Idempotent on `sock_opt` already being null.
    fn scheduleReconnect(self: *Session) void {
        if (self.sock_opt) |s| net.close(s);
        self.sock_opt = null;
        self.read_pos = 0;
        if (!self.runner.isRunning() and self.engine.progress.isRunning()) self.engine.progress.markFailed();
        self.engine.progress.connectionLost();
        self.ui.setStatus("probe disconnected — reconnecting...");
        self.next_retry_at_ns = time_compat.nanoTimestamp() +
            @as(i128, self.backoff_ms) * std.time.ns_per_ms;
        self.backoff_ms = @min(self.backoff_ms * 2, wire.reconnect_max_ms);
    }

    /// Retry the primary connection if the backoff window has elapsed.
    /// Returns true when something render-visible changed.
    fn tryReconnect(self: *Session) bool {
        if (self.sock_opt != null) return false;
        const now_ns = time_compat.nanoTimestamp();
        if (now_ns < self.next_retry_at_ns) return false;

        if (wire.connectAndReadHello(self.endpoint, &self.hello_buf)) |fd| {
            wire.requestHardwareInfo(fd) catch {};
            self.sock_opt = fd;
            self.backoff_ms = wire.reconnect_min_ms;
            self.ui.clearStatus();
            self.ui.flash("probe reconnected");
            self.read_pos = 0;
            self.hardware_info = .{};
            self.have_hardware_info = false;
            self.adoptHelloModelName();
            return true;
        } else |_| {
            self.next_retry_at_ns = now_ns + @as(i128, self.backoff_ms) * std.time.ns_per_ms;
            self.backoff_ms = @min(self.backoff_ms * 2, wire.reconnect_max_ms);
            return false;
        }
    }

    /// Fold one wire frame from the primary probe into session state.
    fn applyFrame(self: *Session, frame: wire.Frame) void {
        switch (frame) {
            .none, .desync => {},
            .hello => |hello| {
                const bytes: *const [@sizeOf(proto.Hello)]u8 = @ptrCast(&hello);
                @memcpy(&self.hello_buf, bytes);
                self.adoptHelloModelName();
            },
            .telemetry => |t| {
                self.current = t;
                self.sampleLanes();
            },
            .hardware_info => |hw| {
                self.hardware_info = hw;
                self.have_hardware_info = true;
            },
            // Probe-side engine spawn: the bench reads tok/s from the
            // probe's forwarded EngineReport stream instead of running
            // the engine itself. Same history the local-engine path
            // drives, different source.
            .engine_report => |rep| self.applyEngineReport(rep),
            .token_text => |chunk| {
                if (!self.engine.progress.abandoned) _ = self.output.push(chunk);
            },
        }
    }

    /// Append one column to each hero lane.
    ///
    /// Driven by telemetry arrivals and nothing else, which is what
    /// puts the two lanes on a shared time axis: the probe ticks at a
    /// fixed rate, so column N means the same instant in both, and a
    /// spike in load can be read directly against the throughput above
    /// it. Sampling each lane on its own source's arrival instead
    /// would scroll them at different speeds — engine reports come
    /// three times faster than telemetry on a quick host.
    ///
    /// Both lanes are pushed every tick even when a lane has nothing
    /// to say. A zero draws as an empty column, which is the honest
    /// reading of "no run in progress", and it keeps the two rings the
    /// same length; skipping the push would slide them out of step and
    /// silently break the alignment the layout promises.
    ///
    /// The corollary is that both lanes freeze while the probe is
    /// disconnected, even though a host-local engine may still be
    /// reporting and still moving the headline figure. That is
    /// deliberate: without telemetry there is no clock to place those
    /// samples on, and appending them anyway would put the two lanes
    /// at different instants for the same column — the one property
    /// the layout exists to guarantee. The title bar says
    /// `reconnecting` throughout, which is the honest account of why
    /// the chart is not moving.
    fn sampleLanes(self: *Session) void {
        const rate = if (self.engine.progress.isRunning() and
            engine_mod.validTokS(self.engine.tok_s)) self.engine.tok_s else 0;
        self.tok_lane.push(rate);
        const util = self.current.cpu_util_pct[0];
        self.prime_lane.push(if (std.math.isNan(util)) 0 else util);
    }

    fn applyEngineReport(self: *Session, rep: proto.EngineReport) void {
        // Not the run on screen if the operator abandoned the one this
        // device is still finishing — see `Progress.take`.
        if (!self.engine.progress.take(rep)) return;
        if (self.multi == .race and engine_mod.validTokS(rep.decode_tok_s)) self.race_tok_series.push(rep.decode_tok_s);
        if (engine_mod.validTokS(rep.decode_tok_s) or rep.phase == engine_mod.phase_done) {
            self.engine.tok_s = rep.decode_tok_s;
        }
        if (rep.phase == engine_mod.phase_done) self.noteRunFinished(rep.decode_tok_s);
    }

    /// Frames the host-local engine can emit besides reports. The
    /// telemetry and hardware frames are a probe's to send, so they are
    /// ignored here rather than folded in — a device's own numbers
    /// arriving down its engine's stdout pipe would be a lie about
    /// where they came from.
    fn applyLocalEngineFrame(self: *Session, frame: wire.Frame) bool {
        return switch (frame) {
            .token_text => |chunk| self.output.push(chunk),
            else => false,
        };
    }

    /// Settle engine state after a host-local run ends without a
    /// phase=2 report — the user pressed `r` again, or the child died.
    ///
    /// `Runner.stop()` only clears the child; `engine.progress` keeps
    /// its last mid-run values, so `isRunning()` stays true. The title
    /// bar then reads `decoding` forever, and — since the decode lane
    /// samples `engine.tok_s` on every telemetry tick — the chart goes
    /// on extending a flat line at the final rate with no engine
    /// behind it.
    /// The host-local engine went away without a final report — it
    /// crashed, failed to load a model, or the user pressed `r` to
    /// stop it. Whatever the cause, the run produced no result.
    ///
    /// This used to force `phase_done`, which was enough while the
    /// dashboard only asked "running or not". Once the header started
    /// saying `✓ complete` and the hero captioning `RUN AVERAGE`, that
    /// same forcing dressed a killed run's last partial running
    /// average as the finished figure.
    fn noteLocalRunStopped(self: *Session) void {
        if (!self.engine.progress.isRunning()) return;
        self.engine.progress.markFailed();
        self.ui.last_done_ns = time_compat.nanoTimestamp();
    }

    fn noteRunFinished(self: *Session, tok_s: f32) void {
        self.ui.last_done_ns = time_compat.nanoTimestamp();
        if (self.multi == .race) {
            self.noteComparisonProgress();
            return;
        }
        // Neither lane is touched: the run's columns stay on screen
        // and scroll off the left over the following seconds while
        // load keeps ticking below them. Clearing a lane here — or
        // swapping the panel to a different series — is what made the
        // chart jump at the end of every run.
        self.ui.flashFmt("engine done — {d:.2} tok/s", .{tok_s});
    }

    /// Counted against the devices that took the run, not the devices
    /// on screen. `r` skips a device whose probe is stale, has no
    /// engine, or is not connected yet, and that device stays
    /// `never_ran`; measured against every column, a comparison with
    /// one such device read `waiting for remaining devices` for good.
    fn noteComparisonProgress(self: *Session) void {
        var started: usize = 0;
        var finished: usize = 0;
        var failed: usize = 0;
        for (0..self.peers.len + 1) |index| {
            switch (self.progressFor(index).state()) {
                .never_ran => continue,
                .running => {},
                .complete => finished += 1,
                .failed => {
                    finished += 1;
                    failed += 1;
                },
            }
            started += 1;
        }
        const idle = self.peers.len + 1 - started;
        if (failed > 0) {
            self.ui.flashFmt("{d}/{d} finished · {d} failed", .{ finished, started, failed });
        } else if (finished < started) {
            self.ui.flashFmt("{d}/{d} finished · waiting for remaining devices", .{ finished, started });
        } else if (idle > 0) {
            self.ui.flashFmt("comparison complete · {d} of {d} devices ran", .{ started, started + idle });
        } else {
            self.ui.flashFmt("comparison complete · {d} devices", .{started});
        }
    }

    /// Clear per-run state so the visual fresh start lines up with the
    /// first inbound report.
    ///
    /// Per device, and only for devices that are not mid-run. A probe
    /// treats a RunRequest during an active run as a no-op, so `r`
    /// pressed twice must not wipe that device's output and progress:
    /// the stream keeps arriving with its sequence intact, and a reset
    /// here made the panel go blank and then flag a false gap when the
    /// next chunk's seq was no longer the zero a fresh run expects.
    fn resetRun(self: *Session) void {
        self.report_pos = 0;
        if (!self.engine.progress.isRunning()) {
            self.engine.tok_s = 0;
            self.engine.progress.reset();
            self.race_tok_series = .{};
            self.output.reset();
        }
        for (self.peers) |*p| {
            if (!p.engine_progress.isRunning()) p.resetRun();
        }
    }

    /// Draws the sync screen on demand. Owns nothing but the spinner
    /// position, so a phase that reports no measurable progress still
    /// visibly moves between frames.
    const SyncPainter = struct {
        tick: usize = 0,
        render: bool = true,

        fn reporter(self: *SyncPainter) model_sync.Reporter {
            return .{ .ctx = self, .paint = paintErased };
        }

        fn paintErased(ctx: *anyopaque, status: model_sync.Status) void {
            const self: *SyncPainter = @ptrCast(@alignCast(ctx));
            self.paint(status);
        }

        fn paint(self: *SyncPainter, status: model_sync.Status) void {
            if (!self.render) return;
            self.tick += 1;
            var shown = status;
            shown.tick = self.tick;
            // A frame that cannot be drawn must not abort a sync that
            // is already uploading; the flash reports the outcome.
            picker_screen.renderSync(shown) catch {};
        }
    };

    /// One place a selected model can land. `socket` is the connection
    /// to configure, or null for the host-local runner in a session
    /// that has no discovery metadata to attach it to.
    const Sink = struct { target: model_sync.Target, socket: ?usize };

    const SinkPlan = struct {
        sinks: [model_sync.max_targets]Sink = undefined,
        len: usize = 0,
        /// Set instead of any sinks: what to tell the operator, in the
        /// terms of the thing they would have to fix.
        refusal: ?[]const u8 = null,
    };

    /// Where a selection would go, or why it cannot go anywhere.
    /// Some targets can be handed a model and some cannot. Pushing to
    /// the subset that can would leave the rest benching something
    /// else, which is worse than refusing.
    fn mixesModelSupport(targets: []const model_sync.Target) bool {
        var known: usize = 0;
        for (targets) |target| {
            if (target.kind != .unsupported) known += 1;
        }
        return known > 0 and known < targets.len;
    }

    fn planSinks(self: *const Session) SinkPlan {
        var plan: SinkPlan = .{};
        for (self.model_targets, 0..) |target, index| {
            if (target.kind == .unsupported) continue;
            if (!self.canSelectFor(target, index)) {
                plan.refusal = switch (target.kind) {
                    .android => "model picker unavailable: update/reconnect this probe first",
                    .host => engine_mod.setup_hint,
                    .unsupported => unreachable,
                };
                return plan;
            }
            plan.sinks[plan.len] = .{ .target = target, .socket = index };
            plan.len += 1;
        }
        if (mixesModelSupport(self.model_targets)) {
            plan.refusal = "model picker unavailable: a manual or iOS target is in this session";
            return plan;
        }
        if (plan.len > 0) return plan;
        // No discovery metadata at all — a manual endpoint session
        // (`zzzbench tcp:7779`). The host-local runner is still a real
        // place to put a model, and it is exactly what `r` falls back
        // to, so the picker has to be able to configure it.
        if (self.engine_bin.len > 0) {
            plan.sinks[0] = .{ .target = .{ .kind = .host }, .socket = null };
            plan.len = 1;
            return plan;
        }
        plan.refusal = engine_mod.setup_hint;
        return plan;
    }

    /// Open the run-params grid. Nothing is pushed and no probe is
    /// restarted — the numbers ride the next `r` in its `RunSpec`.
    fn editParams(self: *Session) void {
        if (self.isAnyRunning()) {
            self.ui.flash("finish the current benchmark before changing params");
            return;
        }
        const count = @min(self.peers.len + 1, self.policies.len);
        var label_buf: [model_sync.max_targets][]const u8 = undefined;
        for (0..count) |index| label_buf[index] = self.deviceLabel(index);

        var managed_buf: [model_sync.max_targets]bool = undefined;
        for (0..count) |index| managed_buf[index] = self.policyManaged(index);

        var edited: [model_sync.max_targets]RunPolicy = self.policies;
        const applied = params_editor.interactive(
            label_buf[0..count],
            edited[0..count],
            managed_buf[0..count],
        ) catch |err| {
            self.ui.flashFmt("params editor failed: {s}", .{@errorName(err)});
            return;
        };
        if (!applied) {
            self.ui.flash("params unchanged");
            return;
        }
        // Pin only the thread counts the operator actually moved.
        // Pinning all of them would mean that opening `p` to nudge a
        // token count freezes every device at whatever placeholder was
        // on screen — including a peer still connecting, whose real
        // core count would then never be adopted and which would run
        // the next `r` at the default 4.
        for (self.policies[0..count], edited[0..count], 0..) |before, after, index| {
            if (before.threads != after.threads) self.threads_pinned[index] = true;
        }
        var changed = false;
        for (self.policies[0..count], edited[0..count]) |before, after| {
            if (!before.eql(after)) changed = true;
        }
        self.policies = edited;
        if (changed) {
            // The numbers on screen were produced by the old settings.
            // Leaving them beside the new ones would attribute a
            // finished run to a policy it never ran under — which is
            // the whole failure the policy display exists to prevent.
            self.resetRun();
        }
        self.ui.flash("run params updated — press r");
    }

    /// What to call device `index` in the params grid: the name its
    /// probe reported, falling back to the peer's label and then its
    /// endpoint, so a column is never blank.
    fn deviceLabel(self: *const Session, index: usize) []const u8 {
        if (self.helloFor(index)) |hello| {
            const name = proto.Hello.nameSlice(&hello.device_name);
            if (name.len > 0) return name;
        }
        if (index == 0) return "primary";
        const peer = &self.peers[index - 1];
        return if (peer.label.len > 0) peer.label else peer.endpoint;
    }

    fn openComparison(self: *Session) void {
        if (self.isAnyRunning()) {
            self.ui.flash("finish the current benchmark before changing devices");
            return;
        }
        self.chooseComparisonDevices() catch |err| {
            if (err == error.SelectionCancelled) {
                self.ui.flash("device selection cancelled");
            } else {
                self.ui.flashFmt("device comparison setup failed: {s}", .{@errorName(err)});
            }
        };
    }

    fn isAnyRunning(self: *Session) bool {
        if (self.runner.isRunning() or self.engine.progress.isRunning()) return true;
        for (self.peers) |*peer| if (peer.engine_progress.isRunning()) return true;
        return false;
    }

    fn chooseComparisonDevices(self: *Session) !void {
        try device_picker.searching();
        // The candidate lists are needed until the selection is
        // installed and no longer. `self.arena` lives as long as the
        // process, so taking them from it kept every list from every
        // `c` press — cancelled ones included — for the whole session.
        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const current = try self.currentDevices(scratch);
        // The platforms this session was launched to look at. Devices
        // already on screen are merged in ahead of the scan, so the
        // filter narrows what can be added, never what is kept.
        const filter = discovery_setup.catalogFilter(self.launch_options.platform);
        const discovered = try catalog.scan(self.allocator, scratch, self.io, filter);
        const candidates = try device_comparison.merge(scratch, current, discovered);
        var initial: device_picker.Selection = .{};
        for (0..current.len) |index| try initial.append(index);
        const picked = try device_picker.compare(candidates, initial);
        const selected = device_comparison.hostFirst(candidates, picked);
        try self.installComparisonDevices(current, candidates, selected);
    }

    fn currentDevices(self: *const Session, arena: std.mem.Allocator) ![]device.Candidate {
        const current = try arena.alloc(device.Candidate, self.peers.len + 1);
        for (current, 0..) |*candidate, index| {
            const target = self.targetFor(index);
            const endpoint = if (index == 0) self.endpoint else self.peers[index - 1].endpoint;
            const hello = self.helloFor(index);
            const platform: device.Platform = if (target.kind == .android)
                .android
            else if (hello != null and wire.isIosProbe(hello.?))
                .ios
            else if (hello != null and std.mem.eql(u8, proto.Hello.sourceSlice(&hello.?.source), "linux sysfs"))
                .android
            else
                .host;
            const local_runner = target.kind == .host or (index == 0 and hello != null and
                std.mem.eql(u8, proto.Hello.sourceSlice(&hello.?.source), "synthetic") and
                self.engine_bin.len > 0 and isLocalEndpoint(endpoint));
            candidate.* = .{
                .platform = platform,
                .id = if (local_runner) "localhost" else if (target.id.len > 0) target.id else endpoint,
                // Hello labels point into buffers replaced at the transition.
                .name = try arena.dupe(u8, self.deviceLabel(index)),
                .soc = if (hello) |h| try arena.dupe(u8, proto.Hello.nameSlice(&h.soc_name)) else "",
                .transport = if (local_runner) "local" else if (target.kind == .android) "adb" else "manual",
                .endpoint = endpoint,
                .probe_state = if (hello != null) .live else .unknown,
            };
        }
        return current;
    }

    fn targetFor(self: *const Session, index: usize) model_sync.Target {
        return if (index < self.model_targets.len) self.model_targets[index] else .{ .kind = .unsupported };
    }

    /// Everything `replaceDevices` needs, allocated out of one arena so
    /// the whole set can be released together.
    const DeviceSet = struct {
        endpoint: []const u8 = "",
        peers: []Peer,
        targets: []model_sync.Target,
        paths: [model_sync.max_targets][]const u8 = @splat(""),
        policies: [model_sync.max_targets]RunPolicy,
        pinned: [model_sync.max_targets]bool,
    };

    fn installComparisonDevices(
        self: *Session,
        current: []const device.Candidate,
        candidates: []const device.Candidate,
        selected: device_picker.Selection,
    ) !void {
        // Each device set gets an arena of its own, released when the
        // next one replaces it. Out of the process arena, every change
        // of devices left the last peer array behind for good.
        var owned = std.heap.ArenaAllocator.init(self.allocator);
        // Prepare additions before closing live connections. Cancel or setup
        // failure leaves the original dashboard and its model intact.
        const set = self.prepareDeviceSet(owned.allocator(), current, candidates, selected) catch |err| {
            owned.deinit();
            return err;
        };
        // The selected model has to reach every device, and `planSinks`
        // will refuse this set. Finding that out after the swap traded
        // a working session for one where `r` and `m` both repeat the
        // refusal, with no way out but removing the device again.
        if (self.selected_model != null and mixesModelSupport(set.targets)) {
            owned.deinit();
            self.ui.flash("devices unchanged — a manual or iOS device cannot take the selected model");
            return;
        }
        self.replaceDevices(set.endpoint, set.peers, set.targets, set.paths, set.policies, set.pinned);
        // The session is running on `set` now, so it owns the arena —
        // no error below this line may release it.
        self.device_arena = owned;
        self.connect() catch {
            self.scheduleReconnect();
            return;
        };
        self.settlePeers();
        self.adoptPeerCoreCounts();
        if (self.selected_model) |model| {
            const plan = self.planSinks();
            if (plan.refusal) |why| {
                self.ui.flash(why);
                return;
            }
            var painter: SyncPainter = .{};
            try self.applyModel(plan, model, &painter);
        }
        self.ui.flash("split view ready — r runs all selected devices");
    }

    /// A device already in the comparison keeps its endpoint — unless it
    /// is an Android one that has dropped off. After a replug its `adb
    /// forward` is gone, discovery folds the phone back into this same
    /// row, and the old endpoint is a dead port: reselecting the phone
    /// then retried it for the rest of the session, with no gesture left
    /// that could repair it. Its settings are kept either way.
    fn needsPreparing(self: *const Session, index: usize) bool {
        return self.targetFor(index).kind == .android and self.socketFor(index) == null;
    }

    fn prepareDeviceSet(
        self: *Session,
        arena: std.mem.Allocator,
        current: []const device.Candidate,
        candidates: []const device.Candidate,
        selected: device_picker.Selection,
    ) !DeviceSet {
        // A device new to the comparison shares its token counts and
        // kernel, so the columns stay comparable — but not the primary's
        // thread count. That is the primary's own core count, or the
        // operator's choice for it, and seeding a phone with it (pinned,
        // if the Mac's was edited) kept the phone from ever adopting its
        // own: a four-core device benched at t12 under a label saying
        // someone had asked for that. Only `--threads` pins everything.
        var seed = self.policyFor(0);
        seed.threads = self.launch_options.threads;
        var set: DeviceSet = .{
            .peers = try arena.alloc(Peer, selected.len - 1),
            .targets = try arena.alloc(model_sync.Target, selected.len),
            .policies = @splat(seed),
            .pinned = @splat(self.launch_options.threads_set),
        };
        var bootstrapped: usize = 0;
        for (selected.indices[0..selected.len], 0..) |choice, index| {
            const candidate = candidates[choice];
            const previous = device_comparison.find(current, candidate);
            const kept = if (previous) |old| !self.needsPreparing(old) else false;
            if (!kept) try device_picker.preparing(candidate.name);
            const prepared: discovery_setup.Target = if (kept) .{
                .label = candidate.name,
                .endpoint = candidate.endpoint,
                .model = if (std.mem.eql(u8, candidate.id, "localhost"))
                    .{ .kind = .host, .id = "localhost" }
                else
                    self.targetFor(previous.?),
            } else try discovery_setup.prepareCandidate(self.allocator, arena, self.io, self.workspace_path, candidate, &bootstrapped);
            // Copied, not borrowed: `candidate` lives in the caller's
            // scratch arena, and a kept device's strings in the set
            // this one is about to replace.
            set.targets[index] = .{ .kind = prepared.model.kind, .id = try arena.dupe(u8, prepared.model.id) };
            const label = try arena.dupe(u8, prepared.label);
            const endpoint = try arena.dupe(u8, prepared.endpoint);
            if (index == 0) set.endpoint = endpoint else set.peers[index - 1] = .{ .label = label, .endpoint = endpoint };
            if (previous) |old| {
                set.paths[index] = self.model_paths[old];
                set.policies[index] = self.policies[old];
                set.pinned[index] = self.threads_pinned[old];
            }
        }
        return set;
    }

    fn replaceDevices(
        self: *Session,
        endpoint: []const u8,
        peers: []Peer,
        targets: []const model_sync.Target,
        paths: [model_sync.max_targets][]const u8,
        policies: [model_sync.max_targets]RunPolicy,
        pinned: [model_sync.max_targets]bool,
    ) void {
        var options = self.launch_options;
        options.endpoint = endpoint;
        options.peer_count = peers.len;
        options.model = "";
        options.engine_bin = self.engine_bin;
        options.engine_model = if (targets[0].kind == .host) self.engine_model else "";
        options.prompt = self.prompt;
        options.show_output = self.ui.show_output;
        options.multi = .race;
        const chosen_model = self.selected_model;
        // No live object is copied: close the old sockets and construct fresh
        // state in place, then connect only after its buffers are stable.
        self.deinit();
        self.* = Session.init(options, peers, targets, self.allocator, self.arena, self.io, self.workspace_path, self.cache_root, self.environ);
        self.model_paths = paths;
        self.policies = policies;
        self.threads_pinned = pinned;
        self.selected_model = chosen_model;
        self.model_sync_required = chosen_model != null;
    }

    /// True only after every target has accepted the selection. A run
    /// requested through the picker must not continue on cancel or failure.
    fn selectModel(self: *Session) bool {
        if (self.isAnyRunning()) {
            self.ui.flash("finish the current benchmark before changing model");
            return false;
        }
        const plan = self.planSinks();
        if (plan.refusal) |why| {
            self.ui.flash(why);
            return false;
        }

        // Scanning maps and parses every GGUF header under three
        // roots; on a full Hugging Face cache that is long enough to
        // read as a hang if the dashboard just sits there.
        var painter: SyncPainter = .{};
        painter.paint(.{ .phase = .scanning });
        const models = model_catalog.scan(self.allocator, self.arena, self.io, .{
            .workspace_path = self.workspace_path,
            .home = self.home,
            .config_home = self.config_home,
        }) catch |err| {
            self.ui.flashFmt("model scan failed: {s}", .{@errorName(err)});
            return false;
        };
        if (models.len == 0) {
            self.ui.flash("no models found — run `zzzbench models`");
            return false;
        }
        const selected = model_picker.interactive(models) catch |err| {
            if (err == error.SelectionCancelled) {
                self.ui.flash("model selection cancelled");
            } else {
                self.ui.flashFmt("model picker failed: {s}", .{@errorName(err)});
            }
            return false;
        };
        // The picker is interactive, so a failure here is a flash and
        // a return to the dashboard — unlike `--model`, which aborts.
        self.applyModel(plan, models[selected], &painter) catch return false;
        return true;
    }

    /// Select a model by name or path, without the picker.
    ///
    /// Same scan, same sink plan, same upload path `m` uses — the only
    /// difference is where the choice comes from. This makes scripted
    /// runs deterministic: encoding the choice as `j`/`j`/`enter` would
    /// depend on whatever happens to be in the operator's model cache
    /// that day.
    /// Errors are returned, not flashed: `--model` is the scripted
    /// path, and a capture that could not apply the model it was told
    /// to must not carry on. A probe that already advertises a
    /// `Hello.model_name` would otherwise run *that* model on the next
    /// `r`, so the launch line would name one model while the GIF
    /// measured another — the exact failure `--model` exists to
    /// remove.
    fn selectModelNamed(self: *Session, wanted: []const u8) !void {
        const plan = self.planSinks();
        if (plan.refusal) |why| {
            self.ui.flash(why);
            try tty.diagLine("zzzbench: --model {s}: {s}\n", .{ wanted, why });
            return error.ModelSelectionUnavailable;
        }
        var painter: SyncPainter = .{};
        painter.paint(.{ .phase = .scanning });
        const models = model_catalog.scan(self.allocator, self.arena, self.io, .{
            .workspace_path = self.workspace_path,
            .home = self.home,
            .config_home = self.config_home,
        }) catch |err| {
            self.ui.flashFmt("model scan failed: {s}", .{@errorName(err)});
            try tty.diagLine("zzzbench: model scan failed: {s}\n", .{@errorName(err)});
            return error.ModelScanFailed;
        };
        // A path first, resolved on both sides, so an ordinary relative
        // path works and a symlink and its target are one answer.
        const model = model_catalog.matchPath(self.allocator, self.io, models, wanted) orelse
            model_catalog.match(models, wanted) orelse
            {
                self.ui.flashFmt("no model matches '{s}'", .{wanted});
                try tty.diagLine(
                    "zzzbench: --model '{s}' matched no model, or matched more than one.\n" ++
                        "  `zzzbench models` lists them; pass a full path to disambiguate.\n",
                    .{wanted},
                );
                return error.ModelNotFound;
            };
        try self.applyModel(plan, model, &painter);
    }

    fn applyModel(
        self: *Session,
        plan: SinkPlan,
        model: model_catalog.Model,
        painter: *SyncPainter,
    ) !void {
        if (model.unavailableReason()) |reason| {
            self.ui.flashFmt("{s}: {s}", .{ model.name, reason });
            try tty.diagLine("zzzbench: {s}: {s}\n", .{ model.name, reason });
            return error.UnsupportedDecodeModel;
        }
        // Keep the requested choice across a partial sync failure. Until all
        // devices accept it, r retries this selection instead of racing a
        // mixture of the old and new models.
        self.selected_model = model;
        self.model_sync_required = true;
        var targets: [model_sync.max_targets]model_sync.Target = undefined;
        for (plan.sinks[0..plan.len], 0..) |sink, i| targets[i] = sink.target;
        const prepared = model_sync.prepare(
            self.allocator,
            self.arena,
            self.io,
            self.workspace_path,
            self.cache_root,
            targets[0..plan.len],
            model,
            painter.reporter(),
        ) catch |err| {
            self.ui.flashFmt("model sync failed: {s}", .{@errorName(err)});
            try tty.diagLine("zzzbench: model sync failed: {s}\n", .{@errorName(err)});
            return error.ModelSyncFailed;
        };

        painter.paint(.{ .phase = .pointing, .model = model.name });
        for (plan.sinks[0..plan.len], 0..) |sink, i| {
            switch (sink.target.kind) {
                .host => {
                    self.engine_model = prepared.paths[i];
                    // The title bar names the *primary*. A host peer
                    // sharing that field would relabel the phone.
                    if (sink.socket == null or sink.socket.? == 0) {
                        self.fallback_model_name = model.name;
                        self.engine.model = model.name;
                    }
                },
                .android => {
                    const socket = sink.socket.?;
                    self.model_paths[socket] = prepared.paths[i];
                    self.configureRemote(socket, prepared.paths[i]) catch |err| {
                        self.ui.flashFmt("model select failed: {s}", .{@errorName(err)});
                        try tty.diagLine("zzzbench: model select failed: {s}\n", .{@errorName(err)});
                        return error.ModelSelectFailed;
                    };
                },
                .unsupported => unreachable,
            }
        }
        self.model_sync_required = false;
        self.ui.flashFmt("model selected: {s}", .{model.name});
    }

    fn canSelectFor(self: *const Session, target: model_sync.Target, index: usize) bool {
        return switch (target.kind) {
            .host => self.engine_bin.len > 0,
            .unsupported => false,
            .android => if (self.helloFor(index)) |hello|
                hello.has_engine == 1 and hello.proto_version >= proto.run_spec_min_version
            else
                false,
        };
    }

    fn helloFor(self: *const Session, index: usize) ?*const proto.Hello {
        if (index == 0) {
            if (self.sock_opt == null) return null;
            return self.helloPtr();
        }
        if (index - 1 >= self.peers.len) return null;
        const peer = &self.peers[index - 1];
        if (peer.sock_opt == null or !peer.have_hello) return null;
        return peer.helloPtr();
    }

    fn socketFor(self: *const Session, index: usize) ?std.posix.fd_t {
        if (index == 0) return self.sock_opt;
        if (index - 1 >= self.peers.len) return null;
        return self.peers[index - 1].sock_opt;
    }

    /// The policy for one socket. Indexes past the array fall back to
    /// the primary's, which is also what a manual session with no
    /// discovery metadata gets.
    fn policyFor(self: *const Session, index: usize) RunPolicy {
        return self.policies[@min(index, self.policies.len - 1)];
    }

    /// Whether this device's policy actually reaches it.
    ///
    /// Only the `RunSpec` path carries threads and token counts. A
    /// probe launched by hand with `--engine --model`, and never
    /// pointed at a model through `m`, uses the fixed-size
    /// `RunRequest` — which carries none of them, so the device keeps
    /// its own startup settings. Showing an editable `t8 · 128/60` for
    /// that device would be a number the bench does not control.
    ///
    /// This mirrors `startRun` exactly, and has to: the question it
    /// answers is "will the next `r` use this device's policy", and any
    /// disagreement between the two shows up as a figure on screen that
    /// nothing sent.
    fn policyManaged(self: *const Session, index: usize) bool {
        if (self.remoteTakesPolicy(index)) return true;
        // Everything below is the host-local runner, which reads policy
        // 0 and writes into the primary's state. There is exactly one
        // of it, so a host target sitting at a peer index does not get
        // its own run — `startRun` skips it — and must not advertise a
        // policy it will never use.
        if (index != 0 or self.engine_bin.len == 0 or self.engine_model.len == 0) return false;
        const host_is_primary = self.model_targets.len > 0 and self.model_targets[0].kind == .host;
        return host_is_primary or !self.anyRemoteWillRun();
    }

    /// Whether device `index` would receive a `RunSpec`, which is the
    /// only frame that carries the policy.
    fn remoteTakesPolicy(self: *const Session, index: usize) bool {
        const hello = self.helloFor(index) orelse return false;
        if (hello.has_engine != 1) return false;
        if (hello.proto_version < proto.run_spec_min_version) return false;
        return index < self.model_paths.len and self.model_paths[index].len > 0;
    }

    /// Whether any probe would start on `r`. This is what decides
    /// whether the local runner is the engine path at all — it only
    /// runs as the fallback when nothing remote can.
    fn anyRemoteWillRun(self: *const Session) bool {
        for (0..@min(self.peers.len + 1, self.policies.len)) |index| {
            const hello = self.helloFor(index) orelse continue;
            if (hello.has_engine != 1) continue;
            // Either a model this bench selected, or one the probe was
            // launched with — both make it runnable.
            if (index < self.model_paths.len and self.model_paths[index].len > 0) return true;
            if (proto.Hello.nameSlice(&hello.model_name).len > 0) return true;
        }
        return false;
    }

    /// A selected model remains runnable after the engine unloads its
    /// weights. Use the launch configuration, not resident memory or
    /// the last run's display name, for both the hint and the run action.
    fn hasRunModel(self: *const Session) bool {
        if (self.model_sync_required) return false;
        if (self.multi == .race) {
            for (0..self.peers.len + 1) |index| {
                const local_fallback = index == 0 and self.targetFor(index).kind == .unsupported and !self.anyRemoteWillRun();
                if (self.targetFor(index).kind == .host or local_fallback) {
                    if (self.engine_bin.len == 0 or self.engine_model.len == 0) return false;
                    continue;
                }
                const hello = self.helloFor(index) orelse return false;
                if (hello.has_engine != 1) return false;
                if (self.model_paths[index].len == 0 and proto.Hello.nameSlice(&hello.model_name).len == 0) return false;
            }
            return true;
        }
        return self.anyRemoteWillRun() or
            (self.engine_bin.len > 0 and self.engine_model.len > 0);
    }

    fn configureRemote(self: *Session, index: usize, model_path: []const u8) !void {
        const fd = self.socketFor(index) orelse return error.ProbeDisconnected;
        const policy = self.policyFor(index);
        try wire.sendRunSpec(fd, .{
            .model = model_path,
            .prompt = self.prompt,
            .threads = policy.threads,
            .n_prompt = policy.n_prompt,
            .n_generate = policy.n_generate,
            .kernel = @intFromEnum(policy.kernel),
        });
    }

    const RemoteStart = enum {
        started,
        unavailable,
        needs_model,
        /// The probe does not advertise kernel selection and would run `auto`.
        needs_newer_probe,
        /// The probe uses the fixed-size `RunRequest` path, which carries
        /// no policy — `m` moves it onto `RunSpec`.
        needs_model_for_pin,
        /// Still busy with a run the operator abandoned. It would
        /// ignore this request and keep reporting the old one.
        finishing_abandoned,
    };

    fn startRemote(self: *Session, index: usize, want_text: bool) RemoteStart {
        if (self.progressFor(index).abandoned) return .finishing_abandoned;
        const fd = self.socketFor(index) orelse return .unavailable;
        const hello = self.helloFor(index) orelse return .unavailable;
        if (hello.has_engine != 1) return .unavailable;
        // Re-read the capability from the Hello in hand rather than
        // trusting that a path was cached earlier: this socket may
        // have reconnected to a probe without RunSpec support,
        // which reads the RunSpec magic as a desync and hangs up —
        // while the dashboard counts the run as started.
        const speaks_run_spec = hello.proto_version >= proto.run_spec_min_version;
        if (speaks_run_spec and self.model_paths[index].len > 0) {
            const policy = self.policyFor(index);
            // A version-1 probe reads the kernel byte as reserved and
            // runs `auto` anyway, while the dashboard would label the
            // result with the kernel that was asked for. Refuse the
            // run rather than publish a mislabelled A/B.
            if (policy.kernel != .auto and hello.proto_version < proto.kernel_pin_min_version) {
                return .needs_newer_probe;
            }
            wire.sendRunSpec(fd, .{
                .model = self.model_paths[index],
                .prompt = self.prompt,
                .threads = policy.threads,
                .n_prompt = policy.n_prompt,
                .n_generate = policy.n_generate,
                .kernel = @intFromEnum(policy.kernel),
                .run_now = true,
                .want_text = want_text,
            }) catch return .unavailable;
            self.markRunStarted(index, policy.n_generate);
            return .started;
        }
        // A probe this bench bootstrapped can spawn an engine but was
        // started model-less, and says so by leaving Hello.model_name
        // empty. Sending it a RunRequest would be dropped on the
        // device while the dashboard claimed a run was in flight — so
        // report the real state and let `m` fix it.
        if (proto.Hello.nameSlice(&hello.model_name).len == 0) return .needs_model;
        // `RunRequest` carries no policy at all, so this probe will run
        // its own startup configuration — including `auto`. Accepting a
        // pinned kernel here and then labelling the result with it
        // would publish an A/B that never happened.
        if (self.policyFor(index).kernel != .auto) return .needs_model_for_pin;
        wire.sendRunRequest(fd, want_text) catch return .unavailable;
        self.markRunStarted(index, 0);
        return .started;
    }

    fn markRunStarted(self: *Session, index: usize, tokens_total: u32) void {
        self.progressFor(index).markStarted(tokens_total);
    }

    fn progressFor(self: *Session, index: usize) *engine_mod.Progress {
        return if (index == 0) &self.engine.progress else &self.peers[index - 1].engine_progress;
    }

    const abandon_prompt = "comparison still running — press r again to abandon it";

    /// Give up on a comparison that will not finish on its own.
    ///
    /// The bench cannot stop a probe-spawned engine — that lifecycle is
    /// the device's — so a probe that accepts a run and then never
    /// reports holds `isAnyRunning()` true, and with it run, model,
    /// params and devices, until quit. Abandoning stops the one engine
    /// the bench does own and writes the rest off as failed.
    ///
    /// Written off is not stopped, though. A device that was only slow
    /// is still running the old request, will ignore the next one, and
    /// will go on reporting — so it is quarantined until that run ends
    /// (`Progress.take`), and `r` leaves it out meanwhile. Otherwise
    /// the operator could change the model or the params, press `r`,
    /// and watch the abandoned run's numbers arrive labelled as the new
    /// one's.
    fn abandonRun(self: *Session) void {
        const local_was_running = self.runner.isRunning();
        self.runner.stop();
        var abandoned: usize = 0;
        for (0..self.peers.len + 1) |index| {
            const progress = self.progressFor(index);
            if (!progress.isRunning()) continue;
            // The local engine is dead once `stop` returns; nothing of
            // its run can arrive late, so there is nothing to hold off.
            if (index == 0 and local_was_running) progress.markFailed() else progress.markAbandoned();
            abandoned += 1;
        }
        self.ui.last_done_ns = time_compat.nanoTimestamp();
        self.ui.flashFmt("comparison abandoned · {d} device{s} marked failed", .{
            abandoned,
            if (abandoned == 1) @as([]const u8, "") else "s",
        });
    }

    /// Broadcast a RunRequest to every connected probe that can spawn
    /// an engine, falling back to the host-local binary when none can.
    fn startRun(self: *Session) void {
        self.startRunWithPicker(selectModel);
    }

    // Keep terminal input at the boundary so the complete selection-to-run
    // transition can also be exercised without an interactive terminal.
    fn startRunWithPicker(self: *Session, comptime pick: fn (*Session) bool) void {
        if (self.multi == .race and self.isAnyRunning()) {
            // A comparison is not restarted under the devices still in
            // it. But refusal alone left no way out when one of them
            // never reports, so a second press while the explanation is
            // still on screen is taken as the operator overruling it.
            if (self.ui.isFlashing(abandon_prompt)) self.abandonRun() else self.ui.flash(abandon_prompt);
            return;
        }
        if (!self.hasRunModel()) {
            const plan = self.planSinks();
            if (plan.refusal == null) {
                if (self.model_sync_required and self.selected_model != null) {
                    // A device that reconnects after selection still needs
                    // the chosen model; retry that sync before starting.
                    var painter: SyncPainter = .{};
                    self.applyModel(plan, self.selected_model.?, &painter) catch return;
                } else if (!pick(self)) return;
            } else {
                self.ui.flash(plan.refusal.?);
                return;
            }
        }
        self.resetRun();

        // Ask for text when the panel is open, or when this bench has a
        // prompt for the engine it might spawn itself. Not always:
        // without a prompt somewhere the engine decodes a random token
        // sequence, and streaming that back is bandwidth spent on noise.
        //
        // The panel being open is the load-bearing half for a device.
        // A probe carries its own `--prompt` — what a phone is asked to
        // generate belongs to the phone's config — so the bench's copy
        // says nothing about whether that probe will produce text.
        const want_text = self.ui.show_output or self.prompt.len > 0;
        var sent_remote: usize = 0;
        var awaiting_model: usize = 0;
        var stale_probe: usize = 0;
        var unpinnable: usize = 0;
        var finishing: usize = 0;
        for (self.model_targets, 0..) |target, index| {
            if (target.kind != .android) continue;
            switch (self.startRemote(index, want_text)) {
                .started => sent_remote += 1,
                .needs_model => awaiting_model += 1,
                .needs_newer_probe => stale_probe += 1,
                .needs_model_for_pin => unpinnable += 1,
                .finishing_abandoned => finishing += 1,
                .unavailable => {},
            }
        }
        // Include manually configured remote probes, which have no discovery
        // target metadata and therefore cannot participate in model sync.
        if (self.model_targets.len == 0 or self.model_targets[0].kind == .unsupported) {
            switch (self.startRemote(0, want_text)) {
                .started => sent_remote += 1,
                .needs_model => awaiting_model += 1,
                .needs_newer_probe => stale_probe += 1,
                .needs_model_for_pin => unpinnable += 1,
                .finishing_abandoned => finishing += 1,
                .unavailable => {},
            }
        }
        for (self.peers, 0..) |_, peer_index| {
            const target_index = peer_index + 1;
            if (target_index < self.model_targets.len and self.model_targets[target_index].kind != .unsupported) continue;
            switch (self.startRemote(target_index, want_text)) {
                .started => sent_remote += 1,
                .needs_model => awaiting_model += 1,
                .needs_newer_probe => stale_probe += 1,
                .needs_model_for_pin => unpinnable += 1,
                .finishing_abandoned => finishing += 1,
                .unavailable => {},
            }
        }

        // The host-local runner is pumped into `session.engine` and
        // `session.output` — the same state the primary probe writes.
        // So it may only run when the host IS the primary: as a peer
        // its reports would interleave with the phone's headline
        // instead of landing in the Mac's own row.
        const host_is_primary = self.model_targets.len > 0 and self.model_targets[0].kind == .host;
        const host_is_peer = hasHostPeer(self.model_targets);
        // Nor as the fallback while a probe is still finishing an
        // abandoned run: with nothing else started that is the primary,
        // and its reports share the state the runner would write.
        const run_local = host_is_primary or (sent_remote == 0 and finishing == 0);
        var sent_local: usize = 0;
        if (run_local and self.engine_bin.len > 0 and self.engine_model.len > 0) {
            // The local runner is the primary's engine, so it takes
            // the primary's policy.
            const policy = self.policyFor(0);
            self.runner.start(self.engine_bin, self.engine_model, .{
                .prompt = self.prompt,
                .threads = policy.threads,
                .n_prompt = policy.n_prompt,
                .n_generate = policy.n_generate,
                .kernel = if (policy.kernel == .auto) "" else policy.kernel.label(),
            }) catch |e| {
                self.ui.flashFmt("engine start failed: {s}", .{@errorName(e)});
                self.engine.progress.markFailed();
                return;
            };
            self.markRunStarted(0, policy.n_generate);
            sent_local = 1;
        }
        const started = sent_remote + sent_local;
        if (started > 0) {
            if (finishing > 0) {
                self.ui.flashFmt("engine running ({d} device{s}) · {d} still finishing an abandoned run", .{
                    started,
                    if (started == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    finishing,
                });
            } else if (host_is_peer and sent_local == 0) {
                self.ui.flashFmt("engine running ({d} device{s}) · this Mac needs its own probe engine", .{
                    started,
                    if (started == 1) @as([]const u8, "") else @as([]const u8, "s"),
                });
            } else {
                self.ui.flashFmt("engine running ({d} device{s})", .{
                    started,
                    if (started == 1) @as([]const u8, "") else @as([]const u8, "s"),
                });
            }
            return;
        }

        if (finishing > 0) {
            self.ui.flashFmt("{d} device{s} still finishing an abandoned run — wait, or remove with c", .{
                finishing,
                if (finishing == 1) @as([]const u8, "") else "s",
            });
            return;
        }
        if (unpinnable > 0) {
            self.ui.flashFmt("{d} probe{s} run their own startup config — press m to pin a kernel, or set it to auto", .{
                unpinnable,
                if (unpinnable == 1) @as([]const u8, "") else "s",
            });
            return;
        }
        if (stale_probe > 0) {
            self.ui.flashFmt("{d} probe{s} cannot pin a kernel — relaunch them, or set q4_0 kernel to auto", .{
                stale_probe,
                if (stale_probe == 1) @as([]const u8, "") else "s",
            });
            return;
        }
        if (awaiting_model > 0) {
            self.ui.flashFmt("press m to choose a model ({d} device{s} waiting)", .{
                awaiting_model,
                if (awaiting_model == 1) @as([]const u8, "") else @as([]const u8, "s"),
            });
            return;
        }
        // Host-local fallback: only when no remote probe could spawn.
        // Kept for the dev loop where bench, synthetic probe, and
        // engine all live on the same machine.
        if (self.engine_bin.len == 0) {
            self.ui.flash(engine_mod.setup_hint);
            return;
        }
        self.ui.flash("no model selected — press m");
    }

    /// The credit plate for this frame, or null when no `--logo` was
    /// named. Built per frame rather than at init because the model
    /// name arrives with the probe's Hello, after the session exists.
    fn credit(self: *Session) ?credit_mod.Credit {
        const named = self.logo orelse return null;
        return .{
            // The plate variant: small enough to sit beside the hero
            // without competing with the number for attention. Non-null
            // because `cli.parse` rejects marks that have none.
            .mark = named.plate.?,
            .mark_sm = named.plate_sm,
            .model = if (self.engine.model.len > 0) self.engine.model else "no model",
            .detail = if (self.credit_line.len > 0) self.credit_line else named.label,
        };
    }

    /// Per-device policies for the frame, with `null` where the policy
    /// does not reach the device — the renderers draw nothing there
    /// rather than a figure that is not in force.
    fn snapshotPolicies(
        self: *const Session,
        buf: *[model_sync.max_targets]?run_policy.Shown,
    ) []const ?run_policy.Shown {
        const count = @min(self.peers.len + 1, self.policies.len);
        for (0..count) |index| {
            buf[index] = if (self.policyManaged(index)) .{
                .policy = self.policies[index],
                // A `--prompt` makes the engine prefill the prompt's
                // own encoded length, so our prefill count is not what
                // ran and does not get printed.
                .prompt_overrides_prefill = self.prompt.len > 0,
            } else null;
        }
        return buf[0..count];
    }

    fn render(self: *Session, view: tui.Viewport) !void {
        var policy_buf: [model_sync.max_targets]?run_policy.Shown = undefined;
        try dashboard.render(.{
            .frame = &self.current,
            .tok_lane = if (self.multi == .race) &self.race_tok_series else &self.tok_lane,
            .prime_lane = &self.prime_lane,
            .engine = self.engine,
            .compare = self.compare,
            .hello = self.helloPtr(),
            .hardware_info = if (self.have_hardware_info) &self.hardware_info else null,
            .peers = self.peers,
            .credit = self.credit(),
            .credit_at = self.logo_at,
            .multi = self.multi,
            .needs_model = !self.hasRunModel(),
            .local_run_live = self.runner.isRunning(),
            .policies = self.snapshotPolicies(&policy_buf),
            .output = .{
                .text = self.output.slice(),
                .truncated = self.output.truncated,
                .complete = self.output.complete,
                .gap = self.output.gap,
                .running = self.engine.progress.isRunning(),
            },
        }, &self.ui, view);
    }
};

fn run(session: *Session) !void {
    // Connect peers at startup. Failures aren't fatal — a peer just
    // starts disconnected and the reconnect loop retries it, so
    // `--probe pixel:… --probe pi:…` launches with the Pi unplugged.
    for (session.peers) |*p| p.tryReconnect();

    // Raw mode degrades cleanly when stdin isn't a tty (e.g. piped):
    // the bench runs without keybinds rather than failing.
    var raw_tty = tui.RawTty.enable();
    defer raw_tty.disable();

    var view = tui.Viewport.fromWinsize(tui.terminal.size() orelse default_winsize, theme.limits);
    if (raw_tty.enabled) tui.terminal.watchResize();

    try tty.write(tui.terminal.enter_alt_screen);
    defer tty.write(tui.terminal.leave_alt_screen) catch {};
    if (raw_tty.enabled) tui.terminal.drainStdin();

    // `--model` runs here rather than before `run`, so its sync screen
    // paints inside the alternate screen. Ahead of it, the frames
    // would home the cursor and erase the operator's actual terminal.
    // Peers get a moment to hand over their Hello first: the sink plan
    // asks each device whether it can take a model, and a peer still
    // mid-handshake would be refused.
    if (session.pending_model.len > 0) {
        session.settlePeers();
        try session.selectModelNamed(session.pending_model);
    }

    // First paint before any telemetry lands: the sentinel frame fills
    // the data slots, so the layout appears as one piece the moment the
    // alt screen opens instead of popping in with the first frame.
    try session.render(view);

    // Built per iteration: [sock?, peer socks…, stdin?, engine stdout?,
    // engine stderr?]. Slot meanings shift with which fds are active,
    // so indices are tracked by name rather than by constant.
    var pfds: [cli.max_peers + 4]std.posix.pollfd = undefined;
    var peer_pfd_idx: [cli.max_peers]?usize = @splat(null);
    var prev_flash_active = false;

    main_loop: while (true) {
        var dirty = false;

        if (tui.terminal.takeResize()) {
            if (tui.terminal.size()) |ws| {
                const next = tui.Viewport.fromWinsize(ws, theme.limits);
                if (next.cols != view.cols or next.rows != view.rows) {
                    view = next;
                    // Clear the previous, larger frame's ghost cells in
                    // case the terminal just shrank.
                    try tty.write(tui.terminal.home_and_clear_below);
                    dirty = true;
                }
            }
        }

        if (session.tryReconnect()) dirty = true;

        // Peer reconnects run on their own clocks, so a slow-returning
        // Pi doesn't gate retries on the Mac. No flash on success —
        // the row going from "disconnected" to live tells the story.
        for (session.peers) |*p| {
            if (p.sock_opt == null) {
                const before = p.have_hello;
                p.tryReconnect();
                if (p.sock_opt != null and !before) dirty = true;
            }
        }

        var npfd: usize = 0;
        // The socket slot is conditional: while disconnected we still
        // want stdin (so `q` quits) and the engine fd (a local run
        // keeps publishing tok/s with no probe attached).
        var sock_idx: ?usize = null;
        if (session.sock_opt) |fd| {
            sock_idx = npfd;
            pfds[npfd] = pollIn(fd);
            npfd += 1;
        }
        for (session.peers, 0..) |*p, pi| {
            if (p.sock_opt) |fd| {
                peer_pfd_idx[pi] = npfd;
                pfds[npfd] = pollIn(fd);
                npfd += 1;
            } else {
                peer_pfd_idx[pi] = null;
            }
        }
        var stdin_idx: ?usize = null;
        if (raw_tty.enabled) {
            stdin_idx = npfd;
            pfds[npfd] = pollIn(std.posix.STDIN_FILENO);
            npfd += 1;
        }
        var engine_idx: ?usize = null;
        if (session.runner.stdout_fd) |fd| {
            engine_idx = npfd;
            pfds[npfd] = pollIn(fd);
            npfd += 1;
        }
        var engine_err_idx: ?usize = null;
        if (session.runner.stderr_fd) |fd| {
            engine_err_idx = npfd;
            pfds[npfd] = pollIn(fd);
            npfd += 1;
        }

        // EINTR (e.g. SIGWINCH landing during the syscall) is not
        // surfaced here — std.posix.poll auto-restarts on it, so its
        // error set is {NetworkSubsystemFailed, SystemResources,
        // Unexpected}. All three mean the kernel-side poll loop is
        // wedged; restarting the bench is the right move.
        _ = std.posix.poll(pfds[0..npfd], poll_timeout_ms) catch |e| {
            std.debug.print("\nzzzbench: poll failed: {s}\n", .{@errorName(e)});
            return;
        };

        if (sock_idx) |idx| {
            if (pumpPrimary(session, pfds[idx].revents)) dirty = true;
        }
        for (session.peers, 0..) |*p, pi| {
            const idx = peer_pfd_idx[pi] orelse continue;
            const was_running = p.engine_progress.isRunning();
            if (pumpPeer(p, pfds[idx].revents)) dirty = true;
            if (session.multi == .race and was_running and !p.engine_progress.isRunning()) session.noteComparisonProgress();
        }
        // A peer's Hello lands asynchronously, and it is what carries
        // that device's core count, so the sweep goes here rather than
        // inside `pumpPeer` — which has no session to write into.
        // Unconditional, not gated on `dirty`: a peer that connected
        // during startup has its Hello in hand before anything sets
        // that flag, and gating meant `r` or `p` pressed first would
        // use the seed thread count instead of the device's own.
        session.adoptPeerCoreCounts();

        // Drain stderr first, so error context the child wrote before
        // exiting is captured before we tear it down.
        if (engine_err_idx) |idx| {
            if (pfds[idx].revents & std.posix.POLL.IN != 0) session.runner.drainStderr();
        }
        if (engine_idx) |idx| {
            if (pumpEngine(session, pfds[idx].revents)) dirty = true;
        }
        // After the engine pump, not before: a successful run makes the
        // banner and the final report readable in the same iteration,
        // and `noteRunFinished` flashes `engine done`. Warning first
        // meant the build-mode warning was overwritten before it could
        // be read — on the exact path where it matters most.
        if (session.warnDebugEngine()) dirty = true;

        if (stdin_idx) |idx| {
            if (pfds[idx].revents & std.posix.POLL.IN != 0) {
                switch (readKeys(session)) {
                    .quit => break :main_loop,
                    .redraw => dirty = true,
                    .idle => {},
                }
            }
        }

        // Redraw on event edges only: a frame arrived, a key was
        // pressed, or the flash banner expired (so it actually
        // disappears when its timer runs out, not on the probe's next
        // frame). Skipping silent ticks keeps CPU near zero while the
        // probe is paused.
        const flash_active = session.ui.currentFlash() != null;
        if (prev_flash_active and !flash_active) dirty = true;
        prev_flash_active = flash_active;

        if (dirty) try session.render(view);
    }
}

fn pollIn(fd: std.posix.fd_t) std.posix.pollfd {
    return .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
}

fn isLocalEndpoint(endpoint: []const u8) bool {
    if (!std.mem.startsWith(u8, endpoint, "tcp:")) return true;
    const parsed = wire.parseTcpEndpoint(endpoint) catch return false;
    return device_comparison.isLoopback(parsed.host);
}

/// A host target sitting behind the primary. There is only ever one
/// local runner, and its output lands in the primary's state, so a
/// host peer is a target the dashboard has to decline rather than
/// quietly mix in.
fn hasHostPeer(targets: []const model_sync.Target) bool {
    if (targets.len < 2) return false;
    for (targets[1..]) |target| {
        if (target.kind == .host) return true;
    }
    return false;
}

/// Service the primary probe socket. Returns true when a redraw is
/// warranted.
fn pumpPrimary(session: *Session, revents: i16) bool {
    if (revents & wire.sock_err_mask != 0) {
        session.scheduleReconnect();
        return true;
    }
    if (revents & std.posix.POLL.IN == 0) return false;

    const fd = session.sock_opt.?;
    const n = std.posix.read(fd, session.read_buf[session.read_pos..]) catch |e| switch (e) {
        // Sockets stay non-blocking after connect; if poll signalled
        // IN but the data drained between poll and read (rare, but
        // possible across signals), skip this iteration rather than
        // treating it as a disconnect.
        error.WouldBlock => return false,
        else => {
            session.scheduleReconnect();
            return true;
        },
    };
    if (n == 0) {
        session.scheduleReconnect();
        return true;
    }
    session.read_pos += n;

    // Drain every full frame the buffer now holds. The probe
    // interleaves TelemetryFrame (128 B) and EngineReport (64 B) on
    // one stream; the magic at buf[0..4] says which is next.
    var dirty = false;
    while (true) {
        const frame = wire.extractFrame(&session.read_buf, &session.read_pos);
        switch (frame) {
            .none => return dirty,
            // Wire desync — the probe's protocol is broken, or we're
            // talking to something else entirely. Reconnecting re-reads
            // Hello and resyncs (or fails with a clear error).
            .desync => {
                session.scheduleReconnect();
                return true;
            },
            else => {
                session.applyFrame(frame);
                dirty = true;
            },
        }
    }
}

fn pumpPeer(p: *Peer, revents: i16) bool {
    if (revents & wire.sock_err_mask != 0) {
        p.scheduleReconnect();
        return true;
    }
    if (revents & std.posix.POLL.IN == 0) return false;

    const n = std.posix.read(p.sock_opt.?, p.read_buf[p.read_pos..]) catch |e| switch (e) {
        error.WouldBlock => return false,
        else => {
            p.scheduleReconnect();
            return true;
        },
    };
    if (n == 0) {
        p.scheduleReconnect();
        return true;
    }
    p.read_pos += n;

    var dirty = false;
    while (true) {
        const frame = wire.extractFrame(&p.read_buf, &p.read_pos);
        switch (frame) {
            .none => return dirty,
            .desync => {
                p.scheduleReconnect();
                return true;
            },
            else => dirty = p.applyFrame(frame) or dirty,
        }
    }
}

/// Service the host-local engine's stdout. Returns true when a redraw
/// is warranted.
fn pumpEngine(session: *Session, revents: i16) bool {
    // POLL.IN can arrive alongside HUP if the kernel buffered the final
    // report before close, so check IN first and let the read drain
    // whatever is left.
    if (revents & std.posix.POLL.IN != 0) {
        const n = std.posix.read(session.runner.stdout_fd.?, session.report_buf[session.report_pos..]) catch 0;
        if (n > 0) {
            session.report_pos += n;
            return drainReports(session);
        }
        // n == 0 → orderly EOF, or the catch swallowed a read error
        // (EBADF, EIO). Either way the fd is no longer useful; fall
        // through to the unclean-exit path so the user sees stderr
        // context and we don't spin on a fd poll keeps reporting ready.
    } else if (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) == 0) {
        // No event of interest at all — shouldn't happen since we
        // asked for POLL.IN, but defensive.
        return false;
    }

    // The engine exited without a clean phase=2; surface the first
    // captured stderr line so the user sees why (model not found,
    // unsupported quant, and so on).
    const reason = session.runner.firstStderrLine();
    if (reason.len > 0) {
        session.ui.flashFmt("engine: {s}", .{reason});
    } else {
        session.ui.flash("engine exited (no stderr captured)");
    }
    session.runner.stop();
    session.noteLocalRunStopped();
    return true;
}

/// Process every complete frame the last read buffered. Handling one
/// per poll cycle falls behind a fast engine when renders gate the
/// loop.
///
/// This reads the engine's stdout with the same dispatcher the socket
/// path uses. It used to stride the buffer in fixed `EngineReport`
/// lengths, which was true of everything the engine emitted until the
/// engine started emitting text — and a fixed stride over a stream
/// with a variable-length frame in it doesn't misread one frame, it
/// loses the phase of every frame after.
fn drainReports(session: *Session) bool {
    var dirty = false;
    while (true) {
        const frame = wire.extractFrame(&session.report_buf, &session.report_pos);
        switch (frame) {
            .none => return dirty,
            .desync => {
                // The engine wrote something that isn't a protocol frame.
                // Nothing later in the stream can be trusted to be on a
                // frame boundary.
                session.ui.flash("engine: unrecognised frame on stdout");
                session.runner.stop();
                session.noteLocalRunStopped();
                session.report_pos = 0;
                return true;
            },
            .engine_report => |rep| {
                session.applyEngineReport(rep);
                dirty = true;
                if (rep.phase == engine_mod.phase_done) {
                    // A clean exit: `stop()` nulls stdout_fd, so don't
                    // fall through to the unclean-exit path.
                    session.runner.stop();
                    session.report_pos = 0;
                    return true;
                }
            },
            else => dirty = session.applyLocalEngineFrame(frame) or dirty,
        }
    }
}

const KeyOutcome = enum { idle, redraw, quit };

fn readKeys(session: *Session) KeyOutcome {
    var key_buf: [16]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &key_buf) catch 0;
    var outcome: KeyOutcome = .idle;
    for (key_buf[0..n]) |b| {
        switch (b) {
            'q', 'Q', 0x03 => return .quit, // quit + ^C
            'c', 'C' => {
                session.openComparison();
                // The device set and descriptors may have changed. Discard
                // any other keys buffered before the picker opened.
                return .redraw;
            },
            's', 'S' => {
                if (session.multi == .race) {
                    session.ui.sort_race = !session.ui.sort_race;
                    session.ui.flash(if (session.ui.sort_race) "devices sorted by average speed" else "device selection order restored");
                    outcome = .redraw;
                }
            },
            'r', 'R' => {
                // The host-local engine is the only one the bench can
                // stop directly — probe-spawned engines run their
                // lifecycle on the device. Pressing `r` while a local
                // one is alive toggles it off; pressing `r` during a
                // probe-spawned run is a no-op on the probe, which
                // doesn't restart until phase=2 lands. Split view
                // keeps the Mac in step with the phones instead, and
                // `startRun` asks twice before abandoning them all.
                if (session.multi != .race and session.runner.isRunning()) {
                    session.runner.stop();
                    session.noteLocalRunStopped();
                    session.ui.flash("engine stopped");
                } else {
                    session.startRun();
                }
                outcome = .redraw;
            },
            'm', 'M' => {
                _ = session.selectModel();
                outcome = .redraw;
            },
            'p', 'P' => {
                session.editParams();
                outcome = .redraw;
            },
            'o', 'O' => {
                session.ui.show_output = !session.ui.show_output;
                // Say why the panel is empty at the moment it is
                // opened, rather than leaving the user to conclude the
                // toggle is broken.
                if (session.ui.show_output and session.prompt.len == 0) {
                    session.ui.flash("output shown — pass --prompt to get any");
                } else {
                    session.ui.flash(if (session.ui.show_output) "output shown" else "output hidden");
                }
                outcome = .redraw;
            },
            'e', 'E' => {
                session.ui.pending_export = true;
                outcome = .redraw;
            },
            else => {},
        }
    }
    return outcome;
}

const RunTest = struct {
    const EngineFixture = struct {
        directory: std.testing.TmpDir,
        path: [:0]const u8,
        fn deinit(self: *EngineFixture) void {
            std.testing.allocator.free(self.path);
            self.directory.cleanup();
        }
    };

    fn engineFixture() !EngineFixture {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const file = try directory.dir.createFile(std.testing.io, "engine", .{ .permissions = .fromMode(0o755) });
        defer file.close(std.testing.io);
        const contract = @import("engine_contract");
        const script = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("testdata/engine-v1.sh"), "@TARGET@", contract.native_target);
        defer std.testing.allocator.free(script);
        try file.writeStreamingAll(std.testing.io, script);
        const path = try directory.dir.realPathFileAlloc(std.testing.io, "engine", std.testing.allocator);
        return .{ .directory = directory, .path = path };
    }

    const model: model_catalog.Model = .{
        .path = "/models/selected.gguf",
        .name = "selected",
        .quant = "Q4_0",
        .architecture = "qwen3",
        .parameter_count = 600_000_000,
        .size_bytes = 400_000_000,
        .source = .workspace,
    };
    const targets = [_]model_sync.Target{ .{ .kind = .host, .id = "localhost" }, .{ .kind = .android, .id = "test-phone" } };

    fn choose(session: *Session) bool {
        // Zig's build runner reserves stdout for its test protocol.
        var painter: Session.SyncPainter = .{ .render = false };
        session.applyModel(session.planSinks(), model, &painter) catch return false;
        return true;
    }

    fn cancel(session: *Session) bool {
        session.ui.flash("model selection cancelled");
        return false;
    }

    fn connectPhone(peer: *Peer) !std.posix.fd_t {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds) != 0) {
            return error.SocketPairFailed;
        }
        peer.sock_opt = fds[0];
        _ = peer.applyFrame(.{ .hello = .{ .has_engine = 1, .proto_version = proto.kernel_pin_min_version } });
        return fds[1];
    }

    fn expectFrame(fd: std.posix.fd_t, expected: []const u8) !void {
        var received: [proto.max_frame_bytes]u8 = undefined;
        var count: usize = 0;
        while (count < expected.len) {
            var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pfd, 1000));
            const n = try std.posix.read(fd, received[count..expected.len]);
            try std.testing.expect(n > 0);
            count += n;
        }
        try std.testing.expectEqualSlices(u8, expected, received[0..count]);
    }

    fn expectNoRequest(fd: std.posix.fd_t) !void {
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pfd, 0));
    }
};

test "run selection starts the local process immediately after the model is applied" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var engine_fixture = try RunTest.engineFixture();
    defer engine_fixture.deinit();
    var session = Session.init(.{ .engine_bin = engine_fixture.path, .n_generate = 64 }, &.{}, RunTest.targets[0..1], std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    defer session.deinit();
    try std.testing.expect(!session.hasRunModel());
    session.startRunWithPicker(RunTest.choose);
    try std.testing.expectEqualStrings(RunTest.model.path, session.engine_model);
    try std.testing.expect(session.runner.isRunning());
    try std.testing.expect(session.engine.progress.isRunning());
    try std.testing.expectEqual(@as(u32, 64), session.engine.progress.tokens_total);
    try std.testing.expectEqualStrings("engine running (1 device)", session.ui.currentFlash().?);
}

test "run selection cancellation neither launches nor clears the previous result" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var engine_fixture = try RunTest.engineFixture();
    defer engine_fixture.deinit();
    var session = Session.init(.{ .engine_bin = engine_fixture.path }, &.{}, RunTest.targets[0..1], std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    defer session.deinit();
    session.engine.tok_s = 42;
    session.tok_lane.push(42);
    session.startRunWithPicker(RunTest.cancel);
    try std.testing.expect(!session.runner.isRunning());
    try std.testing.expect(!session.isAnyRunning());
    try std.testing.expect(session.selected_model == null);
    try std.testing.expectEqual(@as(f32, 42), session.engine.tok_s);
    try std.testing.expectEqual(@as(usize, 1), session.tok_lane.count);
    try std.testing.expectEqualStrings("model selection cancelled", session.ui.currentFlash().?);
}

test "run selection launches the Mac and sends one phone request with its model and policy" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    const phone = try RunTest.connectPhone(&peers[0]);
    defer net.close(phone);
    var engine_fixture = try RunTest.engineFixture();
    defer engine_fixture.deinit();
    var session = Session.init(.{ .multi = .race, .engine_bin = engine_fixture.path, .engine_model = RunTest.model.path, .prompt = "shared prompt" }, &peers, &RunTest.targets, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    defer session.deinit();
    session.model_paths[1] = "/data/local/tmp/selected.gguf";
    session.policies[1] = .{ .threads = 2, .n_prompt = 16, .n_generate = 64 };
    session.startRun();
    try std.testing.expect(session.runner.isRunning());
    try std.testing.expect(session.engine.progress.isRunning());
    try std.testing.expect(peers[0].engine_progress.isRunning());
    try std.testing.expectEqual(@as(u32, 64), peers[0].engine_progress.tokens_total);
    try std.testing.expectEqualStrings("engine running (2 devices)", session.ui.currentFlash().?);
    var frame_buf: [proto.max_frame_bytes]u8 align(8) = undefined;
    const expected = try proto.RunSpec.encode(&frame_buf, .{
        .model = session.model_paths[1],
        .prompt = "shared prompt",
        .threads = 2,
        .n_prompt = 16,
        .n_generate = 64,
        .run_now = true,
        .want_text = true,
    });
    try RunTest.expectFrame(phone, expected);
    session.startRun();
    try RunTest.expectNoRequest(phone);
}

test "run selection sync failure launches neither device and preserves the previous result" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    const phone = try RunTest.connectPhone(&peers[0]);
    defer net.close(phone);
    var engine_fixture = try RunTest.engineFixture();
    defer engine_fixture.deinit();
    var session = Session.init(.{ .multi = .race, .engine_bin = engine_fixture.path, .engine_model = "/models/old.gguf" }, &peers, &RunTest.targets, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    defer session.deinit();
    var requested = RunTest.model;
    requested.path = "/nonexistent-zzzbench-test/requested.gguf";
    session.selected_model = requested;
    session.model_sync_required = true;
    session.engine.tok_s = 42;
    session.tok_lane.push(42);
    session.startRun();
    try std.testing.expect(!session.runner.isRunning());
    try std.testing.expect(!session.isAnyRunning());
    try std.testing.expect(session.model_sync_required);
    try std.testing.expectEqualStrings(requested.path, session.selected_model.?.path);
    try std.testing.expectEqual(@as(f32, 42), session.engine.tok_s);
    try std.testing.expectEqual(@as(usize, 1), session.tok_lane.count);
    try std.testing.expectEqualStrings("model sync failed: FileNotFound", session.ui.currentFlash().?);
    try RunTest.expectNoRequest(phone);
}

test "changing comparison devices clears stale results and preserves selected model and policies" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var old_peers = [_]Peer{.{ .label = "old", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .endpoint = "tcp:8000", .engine_model = "/models/shared.gguf" }, &old_peers, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    session.engine.tok_s = 99;
    session.tok_lane.push(99);
    session.model_paths[0] = "/old-device/model.gguf";
    session.selected_model = .{
        .path = "/models/shared.gguf",
        .name = "shared",
        .quant = "Q4_0",
        .architecture = "qwen3",
        .parameter_count = 600_000_000,
        .size_bytes = 400_000_000,
        .source = .workspace,
    };
    var new_peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8003" }};
    const targets = [_]model_sync.Target{ .{ .kind = .host, .id = "localhost" }, .{ .kind = .android, .id = "phone" } };
    var policies: [model_sync.max_targets]RunPolicy = @splat(.{});
    policies[0] = .{ .threads = 8, .n_prompt = 128, .n_generate = 64 };
    policies[1] = .{ .threads = 2, .n_prompt = 128, .n_generate = 64 };
    session.replaceDevices("tcp:8002", &new_peers, &targets, @splat(""), policies, @splat(true));
    defer session.deinit();
    try std.testing.expectEqualStrings("tcp:8002", session.endpoint);
    try std.testing.expectEqualStrings("phone", session.peers[0].label);
    try std.testing.expectEqual(cli.Multi.race, session.multi);
    try std.testing.expectEqual(@as(usize, 0), session.tok_lane.count);
    try std.testing.expectEqual(engine_mod.State.never_ran, session.engine.progress.state());
    try std.testing.expectEqualStrings("", session.model_paths[0]);
    try std.testing.expectEqualStrings("/models/shared.gguf", session.selected_model.?.path);
    try std.testing.expectEqual(@as(u32, 2), session.policies[1].threads);
    try std.testing.expect(session.threads_pinned[1]);
    try std.testing.expect(!session.hasRunModel());
}

test "comparison startup blocks reruns and changes while a peer is loading" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .endpoint = "tcp:8000", .multi = .race }, &peers, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    session.markRunStarted(1, 64);
    try std.testing.expect(session.isAnyRunning());
    session.startRun();
    try std.testing.expectEqualStrings(Session.abandon_prompt, session.ui.currentFlash().?);
    session.editParams();
    try std.testing.expectEqualStrings("finish the current benchmark before changing params", session.ui.currentFlash().?);
    try std.testing.expect(!session.selectModel());
    session.openComparison();
    try std.testing.expectEqualStrings("finish the current benchmark before changing devices", session.ui.currentFlash().?);
    try std.testing.expectEqual(@as(u32, 64), peers[0].engine_progress.tokens_total);
    try std.testing.expect(peers[0].engine_progress.isRunning());
}

test "an unsupported model is refused before changing or syncing the active model" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var session = Session.init(.{ .endpoint = "tcp:8000", .engine_model = "/models/working.gguf" }, &.{}, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    const model: model_catalog.Model = .{
        .path = "/models/bge.gguf",
        .name = "BGE",
        .quant = "F16",
        .architecture = "bert",
        .parameter_count = 33_000_000,
        .size_bytes = 67_000_000,
        .source = .huggingface,
    };
    var painter: Session.SyncPainter = .{};
    try std.testing.expectError(error.UnsupportedDecodeModel, session.applyModel(.{}, model, &painter));
    try std.testing.expectEqualStrings("/models/working.gguf", session.engine_model);
    try std.testing.expect(!session.model_sync_required);
    try std.testing.expect(session.selected_model == null);
    try std.testing.expect(std.mem.indexOf(u8, session.ui.currentFlash().?, "Embedding model") != null);
}

test "Mac-only run with missing setup keeps its result and gives one recovery action" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    const targets = [_]model_sync.Target{.{ .kind = .host, .id = "localhost" }};
    var session = Session.init(.{}, &.{}, &targets, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    session.engine.tok_s = 42;
    session.startRun();
    try std.testing.expectEqualStrings(engine_mod.setup_hint, session.ui.currentFlash().?);
    try std.testing.expectEqual(@as(f32, 42), session.engine.tok_s);
    try std.testing.expect(!session.runner.isRunning());
}

test "comparison keeps the completed host chart and waits for the last device" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .endpoint = "tcp:8000", .multi = .race }, &peers, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    session.markRunStarted(1, 64);
    var report = std.mem.zeroes(proto.EngineReport);
    report.phase = engine_mod.phase_done;
    report.token_index = 64;
    report.tokens_total = 64;
    report.decode_tok_s = 300;
    session.applyEngineReport(report);
    try std.testing.expectEqualStrings("1/2 finished · waiting for remaining devices", session.ui.currentFlash().?);
    for (0..300) |_| session.applyFrame(.{ .telemetry = proto.sentinelFrame(1) });
    try std.testing.expectEqual(@as(usize, 1), session.race_tok_series.count);
    try std.testing.expectEqual(@as(f32, 300), session.race_tok_series.avg());
    report.decode_tok_s = 2.5;
    _ = peers[0].applyFrame(.{ .engine_report = report });
    session.noteComparisonProgress();
    try std.testing.expectEqualStrings("comparison complete · 2 devices", session.ui.currentFlash().?);
    session.resetRun();
    try std.testing.expectEqual(@as(usize, 0), session.race_tok_series.count);
}

test "a second r abandons a comparison whose device never reports" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .endpoint = "tcp:8000", .multi = .race }, &peers, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    // The probe took the run and went silent: no report will ever clear it.
    session.markRunStarted(1, 64);
    session.startRun();
    try std.testing.expect(session.isAnyRunning());
    // An unrelated flash in between disarms the prompt rather than
    // letting a stray keypress land on a confirmation nobody can see.
    session.ui.flash("output shown");
    session.startRun();
    try std.testing.expect(session.isAnyRunning());
    try std.testing.expectEqualStrings(Session.abandon_prompt, session.ui.currentFlash().?);
    session.startRun();
    try std.testing.expect(!session.isAnyRunning());
    try std.testing.expectEqual(engine_mod.State.failed, peers[0].engine_progress.state());
    try std.testing.expectEqualStrings("comparison abandoned · 1 device marked failed", session.ui.currentFlash().?);
    try std.testing.expect(peers[0].engine_progress.abandoned);
}

test "an abandoned device's late reports are not drawn as the next run" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    const phone = try RunTest.connectPhone(&peers[0]);
    defer net.close(phone);
    var engine_fixture = try RunTest.engineFixture();
    defer engine_fixture.deinit();
    var session = Session.init(.{ .multi = .race, .engine_bin = engine_fixture.path, .engine_model = RunTest.model.path }, &peers, &RunTest.targets, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    defer session.deinit();
    session.model_paths[1] = "/data/local/tmp/selected.gguf";
    session.policies[1] = .{ .threads = 2, .n_prompt = 16, .n_generate = 64 };
    session.startRun();
    var spec_buf: [proto.max_frame_bytes]u8 align(8) = undefined;
    const first = try proto.RunSpec.encode(&spec_buf, .{ .model = session.model_paths[1], .prompt = "", .threads = 2, .n_prompt = 16, .n_generate = 64, .run_now = true, .want_text = false });
    try RunTest.expectFrame(phone, first);

    // The phone is slow, not dead. The operator gives up on it anyway.
    session.startRun();
    session.startRun();
    try std.testing.expect(!session.isAnyRunning());
    // The Mac's engine is gone for good; only the phone can report late.
    try std.testing.expect(!session.engine.progress.abandoned);
    try std.testing.expect(peers[0].engine_progress.abandoned);

    // New params, then the old run — still at t2 — finally reports.
    session.policies[1].threads = 8;
    var report = std.mem.zeroes(proto.EngineReport);
    report.phase = engine_mod.phase_decode;
    report.token_index = 8;
    report.tokens_total = 64;
    report.decode_tok_s = 2.5;
    _ = peers[0].applyFrame(.{ .engine_report = report });
    try std.testing.expectEqual(engine_mod.State.failed, peers[0].engine_progress.state());
    try std.testing.expectEqual(@as(usize, 0), peers[0].tok_series.count);
    try std.testing.expect(!peers[0].have_engine_report);

    // `r` leaves it out rather than ask a busy probe that would ignore
    // the request and answer with the old run.
    session.startRun();
    try RunTest.expectNoRequest(phone);
    try std.testing.expect(session.runner.isRunning());
    try std.testing.expectEqualStrings("engine running (1 device) · 1 still finishing an abandoned run", session.ui.currentFlash().?);
    _ = peers[0].applyFrame(.{ .engine_report = report });
    try std.testing.expectEqual(@as(usize, 0), peers[0].tok_series.count);

    // The old run's terminal report is the phone saying it is free.
    report.phase = engine_mod.phase_done;
    report.token_index = 64;
    _ = peers[0].applyFrame(.{ .engine_report = report });
    try std.testing.expect(!peers[0].engine_progress.abandoned);
    try std.testing.expectEqual(engine_mod.State.never_ran, peers[0].engine_progress.state());
}

test "a session drawn before its primary connects has an empty Hello, not stale bytes" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var session = Session.init(.{ .endpoint = "tcp:8000" }, &.{}, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    const hello = session.helloPtr();
    try std.testing.expectEqualStrings("", proto.Hello.nameSlice(&hello.device_name));
    try std.testing.expectEqualStrings("", proto.Hello.nameSlice(&hello.model_name));
    try std.testing.expectEqualStrings("", proto.Hello.sourceSlice(&hello.source));
    try std.testing.expectEqual(@as(u8, 0), hello.has_engine);
}

test "a device set that cannot share the selected model is recognised before it is installed" {
    const host: model_sync.Target = .{ .kind = .host, .id = "localhost" };
    const phone: model_sync.Target = .{ .kind = .android, .id = "pixel" };
    const iphone: model_sync.Target = .{ .kind = .unsupported };
    try std.testing.expect(!Session.mixesModelSupport(&.{ host, phone }));
    try std.testing.expect(Session.mixesModelSupport(&.{ host, phone, iphone }));
    // All-manual is not mixed: the host-local runner is the one sink.
    try std.testing.expect(!Session.mixesModelSupport(&.{ iphone, iphone }));
}

test "a kept Android device that dropped off is prepared again, a connected one is not" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .multi = .race }, &peers, &RunTest.targets, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    defer session.deinit();
    // Replugged: the forward behind `tcp:8001` is gone.
    try std.testing.expect(session.needsPreparing(1));
    // The Mac has no forward to lose, connected or not.
    try std.testing.expect(!session.needsPreparing(0));
    const phone = try RunTest.connectPhone(&peers[0]);
    defer net.close(phone);
    try std.testing.expect(!session.needsPreparing(1));
}

test "a comparison does not wait on a device that never took the run" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .endpoint = "tcp:8000", .multi = .race }, &peers, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    // `r` reached the Mac only; the phone's probe was not up to take it.
    session.markRunStarted(0, 64);
    var report = std.mem.zeroes(proto.EngineReport);
    report.phase = engine_mod.phase_done;
    report.token_index = 64;
    report.tokens_total = 64;
    report.decode_tok_s = 300;
    session.applyEngineReport(report);
    try std.testing.expectEqual(engine_mod.State.never_ran, peers[0].engine_progress.state());
    try std.testing.expectEqualStrings("comparison complete · 1 of 2 devices ran", session.ui.currentFlash().?);
}

test "a bands session does not feed the split-view series" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var session = Session.init(.{ .endpoint = "tcp:8000" }, &.{}, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    var report = std.mem.zeroes(proto.EngineReport);
    report.phase = engine_mod.phase_decode;
    report.token_index = 8;
    report.tokens_total = 64;
    report.decode_tok_s = 40;
    session.applyEngineReport(report);
    try std.testing.expectEqual(@as(usize, 0), session.race_tok_series.count);
    try std.testing.expectEqual(@as(f32, 40), session.engine.tok_s);
}

test "a device added to a comparison is not seeded with the primary's thread count" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{ .endpoint = "tcp:8000", .multi = .race, .n_generate = 128 }, &peers, &.{}, std.testing.allocator, scratch.allocator(), std.testing.io, "/workspace", "/cache", &environ);
    // The operator moved the Mac's thread count in the params grid.
    session.policies[0].threads = 12;
    session.threads_pinned[0] = true;
    session.policies[1].threads = 6;

    const current = try session.currentDevices(scratch.allocator());
    var both: device_picker.Selection = .{};
    try both.append(0);
    try both.append(1);
    const set = try session.prepareDeviceSet(scratch.allocator(), current, current, both);

    // Devices already in the comparison keep what they had...
    try std.testing.expectEqual(@as(u32, 12), set.policies[0].threads);
    try std.testing.expect(set.pinned[0]);
    try std.testing.expectEqual(@as(u32, 6), set.policies[1].threads);
    try std.testing.expect(!set.pinned[1]);
    // ...and a slot a new device would take starts from the launch
    // defaults, unpinned, so it can adopt its own core count — while
    // still sharing the token counts that make the columns comparable.
    try std.testing.expectEqual((cli.Options{}).threads, set.policies[2].threads);
    try std.testing.expect(!set.pinned[2]);
    try std.testing.expectEqual(@as(u32, 128), set.policies[2].n_generate);
    // Owned by the set's arena, not borrowed from the devices it replaces.
    try std.testing.expectEqualStrings("tcp:8000", set.endpoint);
    try std.testing.expect(set.endpoint.ptr != session.endpoint.ptr);
    try std.testing.expectEqualStrings("phone", set.peers[0].label);
    try std.testing.expect(set.peers[0].label.ptr != peers[0].label.ptr);
}

test "device selection waits for a running peer even when the primary is idle" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var peers = [_]Peer{.{ .label = "phone", .endpoint = "tcp:8001" }};
    var session = Session.init(.{}, &peers, &.{}, std.testing.allocator, std.testing.allocator, std.testing.io, "/workspace", "/cache", &environ);
    try std.testing.expect(!session.isAnyRunning());
    peers[0].engine_progress = .{ .have_report = true, .phase = engine_mod.phase_decode };
    try std.testing.expect(session.isAnyRunning());
}

test "a disconnected manual device is not mistaken for this Mac during comparison" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var session = Session.init(.{ .endpoint = "tcp:8100", .engine_bin = "/host/engine" }, &.{}, &.{}, std.testing.allocator, scratch.allocator(), std.testing.io, "/workspace", "/cache", &environ);
    const current = try session.currentDevices(scratch.allocator());
    try std.testing.expectEqualStrings("tcp:8100", current[0].id);
    try std.testing.expectEqualStrings("manual", current[0].transport);
}

test "failed comparison model sync keeps the requested model pending" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var session = Session.init(.{ .multi = .race, .engine_bin = "/host/engine", .engine_model = "/models/old.gguf" }, &.{}, &.{}, std.testing.allocator, scratch.allocator(), std.testing.io, "/workspace", "/cache", &environ);
    const model: model_catalog.Model = .{
        .path = "/nonexistent-zzzbench-test/requested.gguf",
        .name = "requested",
        .quant = "Q4_0",
        .architecture = "qwen3",
        .parameter_count = 600_000_000,
        .size_bytes = 400_000_000,
        .source = .workspace,
    };
    var painter: Session.SyncPainter = .{};
    var plan: Session.SinkPlan = .{};
    plan.sinks[0] = .{ .target = .{ .kind = .android, .id = "unreachable-test-device" }, .socket = 0 };
    plan.len = 1;
    try std.testing.expectError(error.ModelSyncFailed, session.applyModel(plan, model, &painter));
    try std.testing.expectEqualStrings(model.path, session.selected_model.?.path);
    try std.testing.expect(!session.hasRunModel());
}
