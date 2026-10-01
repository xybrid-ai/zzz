//! Comparison commands: the headless `compare` and the dashboard's `--vs`.
//!
//! Both resolve adapters, plan the arms, run the coordinator over a probe
//! connection, and write the same receipt; they differ only in what they
//! draw while the run happens.

const std = @import("std");
const proto = @import("proto");
const net = @import("net_compat");
const time_compat = @import("time_compat");
const tui = @import("tuiz");

const cli = @import("cli.zig");
const comparison = @import("comparison.zig");
const comparison_receipt = @import("comparison_receipt.zig");
const comparison_screen = @import("ui/comparison_screen.zig");
const engine_parser = @import("engine_parser.zig");
const engine_command = @import("engine_command.zig");
const exec_client = @import("exec_client.zig");
const engine_manifest = @import("engine_manifest.zig");
const engine_registry = @import("engine_registry.zig");
const device = @import("discovery/device.zig");
const peer_mod = @import("peer.zig");
const tty = @import("tty.zig");
const wire = @import("wire.zig");
const Peer = peer_mod.Peer;
const bootstrap_android = @import("discovery/bootstrap_android.zig");

/// Everything a comparison needs, resolved and connected. Shared by the
/// headless `compare` and the dashboard's `--vs`, so the two front-ends
/// differ only in what they draw — a second resolution path is a second
/// set of numbers waiting to disagree.
const PreparedComparison = struct {
    fd: net.fd_t,
    telemetry_available: bool,
    plan: comparison.Plan,
    engine_ids: []const []const u8,
    sources: []const []const u8,
    receipt_root: []const u8,
    stamp: []const u8,
};

fn prepareComparison(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    workspace_path: []const u8,
    opts: cli.Options,
    peers: []const Peer,
) !PreparedComparison {
    if (opts.model.len == 0) return error.ModelRequired;
    if (opts.comparator_count == 0) return error.NoComparators;

    var diagnostic: engine_manifest.Diagnostic = .{};
    const manifests = engine_registry.load(gpa, arena, io, .{
        .home = environ.get("HOME"),
        .config_home = environ.get("XDG_CONFIG_HOME"),
        .engine_dirs = opts.engine_dirs[0..opts.engine_dir_count],
    }, &diagnostic) catch |err| {
        reportEngineRegistryError(err, diagnostic);
        return error.InvalidManifest;
    };

    // `--probe` names extra peers for the dashboard. A comparison runs
    // on exactly one device, and silently benchmarking the first peer
    // instead of the endpoint the operator typed would record the run
    // against the wrong phone.
    if (peers.len > 0) {
        std.debug.print(
            "zzzbench compare: runs one device at a time — pass it as the endpoint" ++
                " (zzzbench compare {s} ...), not as --probe\n",
            .{peers[0].endpoint},
        );
        return error.MultiDeviceCompare;
    }
    const endpoint = opts.endpoint;
    var hello_buf: [@sizeOf(proto.Hello)]u8 align(@alignOf(proto.Hello)) = undefined;
    const fd = wire.connectAndReadHello(endpoint, &hello_buf) catch |err| {
        std.debug.print(
            "zzzbench compare: no probe at {s} ({s})\n",
            .{ endpoint, @errorName(err) },
        );
        return error.ProbeUnavailable;
    };
    // Handed to the caller, who owns closing it: the socket has to
    // outlive this function for the run itself.
    errdefer net.close(fd);
    const hello: *const proto.Hello = @ptrCast(@alignCast(&hello_buf));

    if (!exec_client.available(hello)) {
        std.debug.print(
            "zzzbench compare: the probe at {s} was not started with --allow-exec," ++
                " so it cannot run a comparator.\n" ++
                "  Restart it with: zzzprobe {s} --allow-exec ...\n",
            .{ endpoint, endpoint },
        );
        return error.ExecUnavailable;
    }

    // The probe reports what it is reading, which is also what says
    // whether the manifests' android or host paths apply.
    const platform: engine_manifest.Platform = if (std.mem.eql(
        u8,
        proto.Hello.sourceSlice(&hello.source),
        "linux sysfs",
    )) .android else .host;

    // A relative `--model` means one file to the bench (which hashes it)
    // and another to the probe (which opens it in its own working
    // directory). Resolve it once, here, so the digest and the engines
    // are provably talking about the same bytes. Only on the host: an
    // android path names a file this process cannot see.
    var model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = if (platform == .host) resolved: {
        const length = std.Io.Dir.cwd().realPathFile(io, opts.model, &model_path_buf) catch |err| {
            std.debug.print(
                "zzzbench compare: --model '{s}' is not readable on this host: {s}\n",
                .{ opts.model, @errorName(err) },
            );
            return error.ModelUnreadable;
        };
        break :resolved try arena.dupe(u8, model_path_buf[0..length]);
    } else opts.model;

    var remote_workspace_buf: [96]u8 = undefined;
    const workspace = if (platform == .android)
        bootstrap_android.remoteWorkspacePath(workspace_path, &remote_workspace_buf)
    else
        workspace_path;

    var arms = try std.ArrayListUnmanaged(comparison.ArmPlan).initCapacity(
        arena,
        opts.comparator_count + 1,
    );
    var sources = try std.ArrayListUnmanaged([]const u8).initCapacity(
        arena,
        opts.comparator_count + 1,
    );
    // The baseline is first by construction: every ratio is against it.
    // `--vs` has already refused the baseline and duplicates at parse
    // time, so every id here is a distinct comparator.
    try appendArm(arena, io, &arms, &sources, manifests, cli.baseline_engine_id, platform, workspace, environ, opts, model_path);
    for (opts.comparators[0..opts.comparator_count]) |id| {
        try appendArm(arena, io, &arms, &sources, manifests, id, platform, workspace, environ, opts, model_path);
    }

    // Duped, not borrowed: `hello_buf` and `model_path_buf` are locals
    // of this function, and the plan outlives it — the run reads both
    // while rendering and while writing the receipt. Borrowing them
    // renders as mojibake in the device row, which is how this was
    // caught.
    const device_label = try arena.dupe(u8, proto.Hello.nameSlice(&hello.device_name));
    var model_digest_buf: [64]u8 = undefined;
    const model_digest = if (platform == .host)
        try arena.dupe(u8, hostFileSha256(io, model_path, &model_digest_buf))
    else
        "";
    const plan: comparison.Plan = .{
        .run_id = comparisonRunId(),
        .device = device_label,
        .model_path = model_path,
        .model_sha256 = model_digest,
        .policy = .{
            .reps = opts.reps,
            .warmup = true,
            .stat = opts.stat,
            .threads = opts.threads,
            .n_prompt = opts.n_prompt,
            .n_generate = opts.n_generate,
        },
        .arms = arms.items,
    };

    var engine_ids = try arena.alloc([]const u8, arms.items.len);
    for (arms.items, 0..) |arm, index| engine_ids[index] = arm.id;

    var stamp_buf: [32]u8 = undefined;
    const stamp = try arena.dupe(u8, formatStamp(&stamp_buf, time_compat.realtimeSeconds()));
    const receipt_root = if (environ.get("ZZZBENCH_RUNS_DIR")) |path|
        try arena.dupe(u8, path)
    else if (environ.get("XDG_STATE_HOME")) |path|
        try std.fs.path.join(arena, &.{ path, "zzzbench", "runs" })
    else if (environ.get("HOME")) |home|
        try std.fs.path.join(arena, &.{ home, ".local", "state", "zzzbench", "runs" })
    else
        try std.fs.path.join(arena, &.{ workspace_path, "zzzbench-runs" });
    return .{
        .fd = fd,
        .plan = plan,
        .telemetry_available = !std.mem.eql(u8, proto.Hello.sourceSlice(&hello.source), "synthetic"),
        .engine_ids = engine_ids,
        .sources = sources.items,
        .receipt_root = receipt_root,
        .stamp = stamp,
    };
}

/// The headless half of `--vs`: resolve manifests, run the comparison on
/// one probe, and print the same `result.json` the receipt holds.
///
/// The probe must already be running with `--allow-exec`. Bootstrapping
/// one on demand belongs with the dashboard path that knows how to push
/// binaries; refusing early with the exact restart instruction beats
/// silently measuring nothing.
pub fn runComparison(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    workspace_path: []const u8,
    opts: cli.Options,
    peers: []const Peer,
) !void {
    const prepared = try prepareComparison(gpa, arena, io, environ, workspace_path, opts, peers);
    defer net.close(prepared.fd);
    const plan = prepared.plan;

    var receipt = try comparison_receipt.Receipt.create(
        gpa,
        io,
        prepared.receipt_root,
        prepared.stamp,
        plan.run_id,
        prepared.engine_ids,
    );
    defer receipt.deinit();
    receipt.writePlan(plan, prepared.sources) catch |err| {
        std.debug.print(
            "zzzbench compare: could not write {s}/plan.json: {s}\n",
            .{ receipt.root, @errorName(err) },
        );
    };

    var transport: ProbeTransport = .{ .fd = prepared.fd, .run_id = plan.run_id << 8, .telemetry_available = prepared.telemetry_available };
    const result = try comparison.execute(arena, plan, transport.transport(), receipt.recorder());
    // The measurements are done; losing the receipt is diagnostic loss,
    // not a reason to throw away the only remaining copy of the numbers.
    receipt.writeResult(result) catch |err| {
        std.debug.print(
            "zzzbench compare: could not finalize receipt at {s}: {s}\n",
            .{ receipt.root, @errorName(err) },
        );
    };

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    if (opts.json) {
        try comparison.writeJson(&stdout.interface, result);
    } else {
        try comparison.writeTable(&stdout.interface, result);
        try stdout.interface.print("\nreceipt  {s}\n", .{receipt.root});
    }
    try stdout.interface.flush();
    if (receipt.failed) {
        std.debug.print("zzzbench compare: receipt at {s} is incomplete\n", .{receipt.root});
    }
}

/// The dashboard's `--vs`: the same plan, transport and receipt the
/// headless path uses, with the run drawn while it happens.
///
/// The probe serves one client at a time, so a comparison cannot share
/// the socket with a live telemetry dashboard. Rather than pretend
/// otherwise, `--vs` is its own screen for the duration of the run: the
/// comparison owns the connection, and the device conditions the
/// dashboard would have shown are recorded per repetition in the
/// receipt instead.
pub fn runComparisonScreen(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    workspace_path: []const u8,
    opts: cli.Options,
    peers: []const Peer,
) !void {
    const prepared = try prepareComparison(gpa, arena, io, environ, workspace_path, opts, peers);
    defer net.close(prepared.fd);

    var receipt = try comparison_receipt.Receipt.create(
        gpa,
        io,
        prepared.receipt_root,
        prepared.stamp,
        prepared.plan.run_id,
        prepared.engine_ids,
    );
    defer receipt.deinit();
    receipt.writePlan(prepared.plan, prepared.sources) catch |err| {
        std.debug.print("zzzbench: could not write plan.json: {s}\n", .{@errorName(err)});
    };

    var live: LiveComparison = .{ .io = io, .receipt = &receipt };
    live.seed(prepared.plan);

    var raw_tty = tui.RawTty.enable();
    defer raw_tty.disable();
    try tty.write(tui.terminal.enter_alt_screen);
    defer tty.write(tui.terminal.leave_alt_screen) catch {};
    if (raw_tty.enabled) tui.terminal.drainStdin();

    var worker: ComparisonWorker = .{
        .arena = arena,
        .plan = prepared.plan,
        .fd = prepared.fd,
        .telemetry_available = prepared.telemetry_available,
        .live = &live,
    };
    const thread = try std.Thread.spawn(.{}, ComparisonWorker.run, .{&worker});
    // Declared after the receipt and the socket, so LIFO unwinding ends
    // the worker *before* the state it is still using goes away. Every
    // exit from here — including an error unwinding out of a render —
    // has to wait for it, and asks it to stop first so waiting is
    // bounded by one repetition rather than by the whole run.
    var joined = false;
    defer if (!joined) {
        live.requestStop();
        thread.join();
    };

    // The run happens on the worker; this loop only draws it and reads
    // keys, so a slow terminal can never stall a measurement. A frame
    // that cannot be drawn is dropped rather than propagated: losing the
    // display is not a reason to abandon a measurement in flight.
    while (true) {
        comparison_screen.render(live.snapshot()) catch {};
        if (live.runEnded()) break;
        if (raw_tty.enabled and readStopKey()) live.requestStop();
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    thread.join();
    joined = true;

    if (worker.failure) |err| return err;
    const result = worker.result.?;
    receipt.writeResult(result) catch |err| {
        std.debug.print("zzzbench: could not finalize receipt: {s}\n", .{@errorName(err)});
    };

    live.markDone(result, receipt.root);
    comparison_screen.render(live.snapshot()) catch {};
    if (raw_tty.enabled) waitForKey();

    // The table also goes to the real terminal, so a comparison run
    // through the dashboard leaves the same artifact a scripted one
    // does rather than vanishing with the alternate screen.
    try tty.write(tui.terminal.leave_alt_screen);
    raw_tty.disable();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    try comparison.writeTable(&stdout.interface, result);
    try stdout.interface.print("\nreceipt  {s}\n", .{receipt.root});
    try stdout.interface.flush();
}

fn readStopKey() bool {
    var buf: [8]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    for (buf[0..n]) |byte| {
        if (byte == 'q' or byte == 'Q' or byte == 0x1b or byte == 0x03) return true;
    }
    return false;
}

fn waitForKey() void {
    var pfd = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    // Bounded: a comparison left running on a desk should not hold the
    // alternate screen forever.
    const ready = std.posix.poll(&pfd, 120_000) catch return;
    if (ready == 0) return;
    var buf: [8]u8 = undefined;
    _ = std.posix.read(std.posix.STDIN_FILENO, &buf) catch {};
}

/// Runs the coordinator off the render loop. Owns nothing the UI thread
/// touches except through `LiveComparison`'s mutex.
const ComparisonWorker = struct {
    arena: std.mem.Allocator,
    plan: comparison.Plan,
    fd: net.fd_t,
    telemetry_available: bool,
    live: *LiveComparison,
    result: ?comparison.Result = null,
    failure: ?anyerror = null,

    fn run(self: *ComparisonWorker) void {
        var transport: ProbeTransport = .{ .fd = self.fd, .run_id = self.plan.run_id << 8, .telemetry_available = self.telemetry_available };
        self.result = comparison.execute(
            self.arena,
            self.plan,
            transport.transport(),
            self.live.recorder(),
        ) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.live.markFinished();
    }
};

/// The screen's state, written by the coordinator's thread and read by
/// the render loop. Everything is fixed-size and copied out under the
/// lock, so the renderer never holds a pointer into a running run.
const LiveComparison = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    view: comparison_screen.View = .{},
    stop: bool = false,
    complete: bool = false,
    receipt: *comparison_receipt.Receipt,

    fn seed(self: *LiveComparison, plan: comparison.Plan) void {
        self.view.device = plan.device;
        self.view.model = plan.model_path;
        self.view.reps = plan.policy.reps;
        self.view.stat = plan.policy.stat.label();
        self.view.threads = plan.policy.threads;
        self.view.n_prompt = plan.policy.n_prompt;
        self.view.n_generate = plan.policy.n_generate;
        self.view.arm_count = @min(plan.arms.len, comparison_screen.max_arms);
        const cells = @as(usize, plan.policy.reps) +
            @as(usize, if (plan.policy.warmup) 1 else 0);
        for (plan.arms[0..self.view.arm_count], 0..) |arm, index| {
            self.view.arms[index] = .{
                .id = arm.id,
                .label = arm.label,
                .fidelity = @tagName(arm.fidelity),
                .cell_count = @min(cells, comparison_screen.max_cells),
            };
        }
    }

    fn recorder(self: *LiveComparison) comparison.Recorder {
        return .{
            .context = self,
            .started = started,
            .output = output,
            .finished = finished,
            .progress = progress,
            .stopRequested = stopRequested,
        };
    }

    fn snapshot(self: *LiveComparison) comparison_screen.View {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.view;
    }

    /// True once the coordinator's thread has returned, whether it
    /// produced a result or an error.
    fn runEnded(self: *LiveComparison) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.complete;
    }

    fn markFinished(self: *LiveComparison) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.complete = true;
    }

    fn requestStop(self: *LiveComparison) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stop = true;
        self.view.stopping = true;
    }

    fn markDone(self: *LiveComparison, result: comparison.Result, receipt_root: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.view.done = true;
        self.view.live = null;
        self.view.receipt = receipt_root;
        for (result.arms, 0..) |arm, index| {
            if (index >= self.view.arm_count) break;
            self.view.arms[index].prefill_tps = arm.prefill_tps;
            self.view.arms[index].decode_tps = arm.decode_tps;
            self.view.arms[index].prefill_stats = arm.prefill_stats;
            self.view.arms[index].decode_stats = arm.decode_stats;
            self.view.arms[index].prefill_ratio = arm.prefill_ratio;
            self.view.arms[index].decode_ratio = arm.decode_ratio;
        }
    }

    fn cellIndex(self: *LiveComparison, invocation: comparison.Invocation) usize {
        _ = self;
        return invocation.round;
    }

    fn started(context: *anyopaque, invocation: comparison.Invocation) void {
        const self: *LiveComparison = @ptrCast(@alignCast(context));
        self.receipt.recorder().started(self.receipt, invocation);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const cell = self.cellIndex(invocation);
        if (invocation.arm < self.view.arm_count and cell < comparison_screen.max_cells) {
            self.view.arms[invocation.arm].cells[cell] = .running;
        }
        self.view.live = .{ .arm = invocation.arm, .round = invocation.round };
    }

    fn output(
        context: *anyopaque,
        invocation: comparison.Invocation,
        stream: proto.RawOutput.Stream,
        bytes: []const u8,
    ) void {
        const self: *LiveComparison = @ptrCast(@alignCast(context));
        self.receipt.recorder().output(self.receipt, invocation, stream, bytes);
    }

    fn progress(
        context: *anyopaque,
        invocation: comparison.Invocation,
        update: engine_parser.Progress,
    ) void {
        const self: *LiveComparison = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.view.live = .{
            .arm = invocation.arm,
            .round = invocation.round,
            .phase = update.phase,
            .token_index = update.token_index,
            .tokens_total = update.tokens_total,
            .prefill_tps = update.prefill_tps,
            .decode_tps = update.decode_tps,
        };
    }

    fn finished(
        context: *anyopaque,
        invocation: comparison.Invocation,
        repetition: comparison.Repetition,
    ) void {
        const self: *LiveComparison = @ptrCast(@alignCast(context));
        self.receipt.recorder().finished(self.receipt, invocation, repetition);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const cell = self.cellIndex(invocation);
        if (invocation.arm >= self.view.arm_count or cell >= comparison_screen.max_cells) return;
        self.view.arms[invocation.arm].cells[cell] =
            if (repetition.failure == .none) .done else .failed;
        if (repetition.failure != .none) self.view.arms[invocation.arm].failures += 1;
        self.view.live = null;
    }

    fn stopRequested(context: *anyopaque) bool {
        const self: *LiveComparison = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stop;
    }
};

fn appendArm(
    arena: std.mem.Allocator,
    io: std.Io,
    arms: *std.ArrayListUnmanaged(comparison.ArmPlan),
    sources: *std.ArrayListUnmanaged([]const u8),
    manifests: []const engine_manifest.Manifest,
    id: []const u8,
    platform: engine_manifest.Platform,
    workspace: []const u8,
    environ: *const std.process.Environ.Map,
    opts: cli.Options,
    model_path: []const u8,
) !void {
    const manifest = findManifest(manifests, id) orelse {
        std.debug.print(
            "zzzbench compare: no engine manifest with id '{s}'. See `zzzbench engines`.\n",
            .{id},
        );
        return error.UnknownEngine;
    };
    if (!manifest.available(platform)) {
        std.debug.print(
            "zzzbench compare: engine '{s}' has no {s} binary in {s}\n",
            .{ id, @tagName(platform), manifest.source },
        );
        return error.PlatformUnavailable;
    }

    const command = engine_command.resolve(arena, manifest, .{
        .platform = platform,
        .binary = if (platform == .host and std.mem.eql(u8, id, "zzz") and opts.engine_bin.len > 0 and
            (opts.engine_bin_override or std.mem.eql(u8, manifest.source, "builtin:zzz.toml")))
            try std.Io.Dir.cwd().realPathFileAlloc(io, opts.engine_bin, arena)
        else
            null,
        .home = environ.get("HOME"),
        .model = model_path,
        .threads = opts.threads,
        .n_prompt = opts.n_prompt,
        .n_generate = opts.n_generate,
        .prompt = opts.prompt,
        .kernel = opts.kernel.label(),
        .workspace = workspace,
    }) catch |err| {
        std.debug.print(
            "zzzbench compare: engine '{s}' cannot run this policy: {s}\n",
            .{ id, @errorName(err) },
        );
        return err;
    };

    // Third-party streaming adapters may emit these frames without implementing
    // zzz's CLI. Only the bundled zzz adapter owns this identity contract.
    if (platform == .host and std.mem.eql(u8, manifest.source, "builtin:zzz.toml")) {
        try @import("engine_contract").check(arena, io, command.argv[0]);
    }

    // The wire carries environment overrides as KEY=VALUE, so the shape
    // conversion happens once, here, rather than per repetition.
    var environment = try arena.alloc([]const u8, command.environment.len);
    for (command.environment, 0..) |entry, index| {
        environment[index] = try std.fmt.allocPrint(
            arena,
            "{s}={s}",
            .{ entry.key, entry.value },
        );
    }

    // What actually ran, when this host can see it. A receipt that names
    // a path proves nothing once that path has been rebuilt.
    const digest_buf = try arena.alloc(u8, 64);
    const binary_sha256 = if (platform == .host)
        hostFileSha256(io, command.argv[0], digest_buf[0..64])
    else
        "";

    try arms.append(arena, .{
        .id = manifest.id,
        .label = manifest.label,
        .parser = manifest.parser,
        .fidelity = manifest.fidelity,
        .metrics = manifest.metrics,
        .argv = command.argv,
        .environment = environment,
        .binary_sha256 = binary_sha256,
    });
    try sources.append(arena, manifest.source);
}

fn findManifest(
    manifests: []const engine_manifest.Manifest,
    id: []const u8,
) ?engine_manifest.Manifest {
    for (manifests) |manifest| {
        if (std.mem.eql(u8, manifest.id, id)) return manifest;
    }
    return null;
}

/// Runs one repetition on the probe. Run IDs are unique per repetition
/// so a late frame from a cancelled run can never be attributed to the
/// one after it.
const ProbeTransport = struct {
    fd: net.fd_t,
    run_id: u64,
    telemetry_available: bool = true,

    fn transport(self: *ProbeTransport) comparison.Transport {
        return .{ .context = self, .execute = execute };
    }

    fn execute(
        context: *anyopaque,
        invocation: comparison.Invocation,
        sink: exec_client.Sink,
    ) anyerror!exec_client.Outcome {
        const self: *ProbeTransport = @ptrCast(@alignCast(context));
        self.run_id += 1;
        return exec_client.run(self.fd, .{
            .run_id = self.run_id,
            .timeout_ms = invocation.timeout_ms,
            .argv = invocation.argv,
            .environment = invocation.environment,
            // Above the device's own timeout: the probe should be the
            // one to end a slow run, and this only covers a probe that
            // stopped answering entirely.
            .client_deadline_ms = invocation.timeout_ms + 30_000,
            // Version-3 probes ignore this reserved request bit; their
            // outcome keeps metrics null. New probes emit an extra frame.
            .metrics = true,
            .telemetry_available = self.telemetry_available,
        }, sink);
    }
};

/// Run IDs also name the receipt directory, and whole seconds are not
/// enough to keep two scripted comparisons started in the same second
/// from writing into each other's evidence. Mixing the monotonic clock
/// in gives the sub-second entropy the wall clock does not have.
fn comparisonRunId() u64 {
    const seconds: u64 = @bitCast(time_compat.realtimeSeconds());
    const monotonic: u64 = @truncate(@as(u128, @bitCast(time_compat.nanoTimestamp())));
    return ((seconds & 0xFFFF_FFFF) << 20) | (monotonic % (1 << 20));
}

/// Digest of a file *if this host can read the path*. On Android the
/// paths name files on the device, which the host cannot hash from here;
/// those digests come from the push manifest, and reach this once
/// `compare` is given the device serial rather than a bare endpoint. An
/// empty digest is recorded as empty rather than as a hash of something
/// else.
///
/// Distinct from `model_sync`'s hashing, which interleaves progress
/// reporting for a multi-gigabyte push; this one is silent and only runs
/// on a path that is already local.
fn hostFileSha256(io: std.Io, path: []const u8, out: *[64]u8) []const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return "";
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return "",
        };
        if (n == 0) break;
        hash.update(buf[0..n]);
    }
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    @memcpy(out, &hex);
    return out;
}

/// `YYYYMMDD-HHMMSS` in UTC, for a receipt directory that sorts by time.
fn formatStamp(buf: []u8, unix_seconds: i64) []const u8 {
    const seconds: u64 = @intCast(@max(unix_seconds, 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time_of_day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time_of_day.getHoursIntoDay(),
        time_of_day.getMinutesIntoHour(),
        time_of_day.getSecondsIntoMinute(),
    }) catch "00000000-000000";
}

pub fn reportComparisonError(err: anyerror) void {
    switch (err) {
        // Already explained at the point it was detected.
        error.InvalidManifest,
        error.ProbeUnavailable,
        error.ExecUnavailable,
        error.UnknownEngine,
        error.PlatformUnavailable,
        error.MultiDeviceCompare,
        error.ModelUnreadable,
        => {},
        error.ModelRequired => std.debug.print(
            "zzzbench compare: --model PATH is required (the path on the device)\n",
            .{},
        ),
        error.NoComparators => std.debug.print(
            "zzzbench compare: --vs ID is required, e.g. --vs llamacpp\n",
            .{},
        ),
        else => std.debug.print("zzzbench compare: {s}\n", .{@errorName(err)}),
    }
}

pub fn reportEngineRegistryError(err: anyerror, diagnostic: engine_manifest.Diagnostic) void {
    if (err != error.InvalidManifest) {
        std.debug.print("zzzbench: engine discovery failed: {s}\n", .{@errorName(err)});
        return;
    }
    std.debug.print("zzzbench: invalid engine manifest {s}", .{diagnostic.source});
    if (diagnostic.line > 0) std.debug.print(":{d}", .{diagnostic.line});
    std.debug.print(": {s}", .{diagnostic.message()});
    if (diagnostic.field.len > 0) std.debug.print(" ({s})", .{diagnostic.field});
    std.debug.print("\n", .{});
}
