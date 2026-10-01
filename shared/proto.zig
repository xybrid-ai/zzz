//! Wire protocol shared between zzzprobe (telemetry source) and
//! zzzbench (TUI client).
//!
//! Frames are length-prefixed little-endian. The probe pushes one
//! frame per sample tick; the bench pulls them as fast as the socket
//! delivers. No request/response — the probe is a fire-hose.
//!
//! Most frames are fixed-size structs, so a reader can `@bitCast`
//! without a parser. `TokenText` is the exception and the reason
//! `frameSpan` takes a buffer rather than a magic: generated text has
//! no fixed length. It stays cheap for the readers by padding its
//! payload to keep the next frame 8-aligned, and by treating an
//! over-long length as a desync rather than an allocation — so every
//! reader can still hold any legal frame in a fixed
//! `max_frame_bytes` buffer.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Fixed-size frames are reinterpreted in place (`@bitCast`, `@ptrCast`), so
    // the native byte order is the wire byte order. Every supported
    // host and device is little-endian; a big-endian port needs explicit
    // byte swapping first.
    if (builtin.cpu.arch.endian() != .little) @compileError("proto frames require a little-endian target");
}

pub const magic: u32 = 0x7A7A_7A50; // "zzzP" — TelemetryFrame
pub const version: u16 = 1;
/// Capability level carried in Hello. Zero means the probe supports only
/// fixed-size run requests.
pub const protocol_version: u8 = 3;

/// Lowest `Hello.proto_version` that understands `RunSpec`. Gates test
/// against this, never against `protocol_version` — bumping the level
/// for some later addition must not retroactively disqualify probes
/// that handle run specs perfectly well.
pub const run_spec_min_version: u8 = 1;

/// Lowest `Hello.proto_version` that honours `RunSpec.kernel`.
///
/// A version-1 probe reads that offset as reserved and starts the
/// engine on `auto` regardless — while the dashboard, having asked for
/// `sdot`, would label the run `sdot`. A mislabelled A/B is worse than
/// no A/B, so a pinned kernel needs its own capability level rather
/// than riding the one that gates ordinary run parameters.
pub const kernel_pin_min_version: u8 = 2;
pub const exec_min_version: u8 = 3;
pub const capability_exec: u8 = 1 << 0;
pub const capability_exec_metrics: u8 = 1 << 1;

pub const hello_magic: u32 = 0x7A7A_7A48; // "zzzH" — Hello
pub const hardware_info_magic: u32 = 0x7A7A_7A49; // "zzzI" — HardwareInfo
pub const hardware_info_request_magic: u32 = 0x7A7A_7A4A; // "zzzJ" — HardwareInfoRequest
pub const engine_report_magic: u32 = 0x7A7A_7A52; // "zzzR" — EngineReport
pub const run_request_magic: u32 = 0x7A7A_7A51; // "zzzQ" — RunRequest
pub const token_text_magic: u32 = 0x7A7A_7A54; // "zzzT" — TokenText
pub const run_spec_magic: u32 = 0x7A7A_7A53; // "zzzS" — RunSpec
pub const exec_request_magic: u32 = 0x7A7A_7A45; // "zzzE" — ExecRequest
pub const raw_output_magic: u32 = 0x7A7A_7A4F; // "zzzO" — RawOutput
pub const exec_event_magic: u32 = 0x7A7A_7A56; // "zzzV" — ExecEvent
pub const exec_cancel_magic: u32 = 0x7A7A_7A43; // "zzzC" — ExecCancel
pub const exec_metrics_magic: u32 = 0x7A7A_7A4D; // "zzzM" — ExecMetrics (requested only)

/// Bits in `RunRequest.flags`. A probe ignores unsupported bits, and the
/// bench sets only bits it needs. Optional frames require an explicit request.
pub const run_flag_want_text: u32 = 1 << 0;

pub const ios_battery_pct_unavailable: u8 = std.math.maxInt(u8);
pub const ios_flag_low_power_mode: u8 = 1 << 0;
pub const hardware_info_flag_gpu_name_read: u32 = 1 << 0;
pub const hardware_info_flag_soc_inferred: u32 = 1 << 1;
pub const hardware_info_flag_npu_unavailable: u32 = 1 << 2;

pub const IosPowerState = enum(u8) {
    unknown = 0,
    unplugged = 1,
    charging = 2,
    full = 3,
};

pub const IosThermalState = enum(u8) {
    unknown = 0,
    nominal = 1,
    fair = 2,
    serious = 3,
    critical = 4,
};

/// Sent once at the head of every connection, before the telemetry
/// stream. Carries metadata that doesn't change per-tick (device
/// model, SoC name, sampling source). Bench reads exactly one Hello,
/// then enters the frame-read loop.
///
/// Strings are fixed-size, null-padded UTF-8. A trailing 0x00 marks
/// end-of-string; if the buffer is fully used the entire field is
/// the value (no terminator required). Sized generously so we don't
/// have to bump the protocol when SoC names get longer.
pub const Hello = extern struct {
    magic: u32 = hello_magic,
    version: u16 = 1,
    _pad0: u16 = 0,

    /// e.g. "Pixel 8", "Mac", "Raspberry Pi 5"
    device_name: [32]u8 = @splat(0),
    /// e.g. "Tensor G3", "Apple M3", "BCM2712"
    soc_name: [32]u8 = @splat(0),
    /// e.g. "linux sysfs", "synthetic", "darwin sysctl"
    source: [16]u8 = @splat(0),

    /// 1 if this probe was started with --engine + --model and can
    /// service a RunRequest by spawning the engine locally; 0 if it's
    /// telemetry-only. The bench reads this to decide whether to
    /// broadcast `r` keypresses to this peer (and whether to expect
    /// EngineReport frames interleaved on the socket).
    has_engine: u8 = 0,

    /// Derived from the probe's --model PATH (basename, with .gguf and
    /// known quant suffixes stripped) or set explicitly via --name FOO.
    /// Empty when the probe runs telemetry-only. The bench reads this
    /// for the title bar so the model label follows the device that
    /// actually has the file, not whatever the bench operator typed.
    model_name: [32]u8 = @splat(0),

    /// Zero means the probe supports only fixed-size run requests. Its
    /// position preserves the version-1 Hello frame layout.
    proto_version: u8 = protocol_version,

    /// CPU cores this device has, and how many of them are *not* in
    /// its slowest cluster. Zero means the probe could not tell (the
    /// synthetic macOS path, or a probe without core-count data), and
    /// the bench keeps its own default.
    ///
    /// `perf_cores`, not `total_cores`, is the thread count worth
    /// defaulting to. A Tensor G3 is 1 prime + 4 big + 4 little, and
    /// asking for all 9 spills past the 5 that matter and suppresses
    /// core pinning — measured at ~2.66x slower. A Snapdragon 8 Elite
    /// has no little cluster at all, so both figures are 8 there.
    total_cores: u8 = 0,
    perf_cores: u8 = 0,
    /// Opt-in capabilities. Zero means no optional capabilities are advertised.
    capabilities: u8 = 0,
    _pad1: [3]u8 = @splat(0),

    pub fn nameSlice(buf: *const [32]u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..end];
    }
    pub fn sourceSlice(buf: *const [16]u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..end];
    }
};

comptime {
    std.debug.assert(@sizeOf(Hello) == 128);
}

/// Optional probe metadata sent immediately after Hello by probes
/// that can discover stable hardware names. Benches treat its absence
/// as normal and fall back to Hello.soc_name.
pub const HardwareInfo = extern struct {
    magic: u32 = hardware_info_magic,
    version: u16 = 1,
    _pad0: u16 = 0,

    /// OS product identifier, e.g. "iPhone15,2".
    machine: [16]u8 = @splat(0),
    /// SoC marketing name when known. May be inferred from machine.
    soc_name: [32]u8 = @splat(0),
    /// Metal device name, when MTLCreateSystemDefaultDevice reports one.
    gpu_name: [32]u8 = @splat(0),
    /// NPU/ANE identity when a supported source exists; empty otherwise.
    npu_name: [32]u8 = @splat(0),
    /// hardware_info_flag_* bitset describing source/availability.
    flags: u32 = 0,
    _pad1: [4]u8 = @splat(0),

    pub fn machineSlice(buf: *const [16]u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..end];
    }

    pub fn nameSlice(buf: *const [32]u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..end];
    }
};

comptime {
    std.debug.assert(@sizeOf(HardwareInfo) == 128);
}

/// Streamed to stdout by `zzz bench-run` when `--report-binary` is set.
/// The bench spawns the engine, captures its stdout pipe, and reads one EngineReport
/// per emit. Fixed-size so the bench can `@bitCast` without a
/// parser, same pattern as TelemetryFrame.
///
/// Phases:
///   0   prefill in progress
///   1   decode in progress
///   2   done — final report; engine is about to exit
pub const EngineReport = extern struct {
    magic: u32 = engine_report_magic,
    version: u16 = 1,
    phase: u8 = 0,
    _pad0: u8 = 0,

    /// Nanoseconds since the engine process started.
    ts_ns: u64,

    /// 0..tokens_total during decode; 0 during prefill.
    token_index: u32,
    /// Total decode tokens this run will produce. 0 during prefill.
    tokens_total: u32,

    /// Running average tok/s for the current phase. Updated every
    /// emit so the bench sparkline animates as the run progresses.
    decode_tok_s: f32,
    /// Final prefill tok/s, set once when prefill completes; 0 before.
    prefill_tok_s: f32,

    _pad1: [32]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(EngineReport) == 64);
}

/// Sent bench → probe to opt into the optional HardwareInfo metadata
/// frame. Probes emit HardwareInfo only after this request, so a reader
/// never receives a HardwareInfo frame it did not ask for.
pub const HardwareInfoRequest = extern struct {
    magic: u32 = hardware_info_request_magic,
    version: u16 = 1,
    _pad0: u16 = 0,
    _reserved: [24]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(HardwareInfoRequest) == 32);
}

/// Sent bench → probe to ask the probe to spawn its configured
/// engine subprocess. The probe replies by interleaving EngineReport
/// frames onto the same TCP stream as TelemetryFrame; the bench
/// dispatches by leading magic. RunRequest is fixed-size so the
/// probe can `@bitCast` without a parser, same as the other frames.
///
/// Reserved bytes leave room for future per-run parameters (token
/// budget, model selection if a probe ever carries multiple) without
/// bumping the version. A probe with has_engine=0 must drop any
/// RunRequest it receives — the bench gates on the Hello flag, but
/// don't trust client behavior.
pub const RunRequest = extern struct {
    magic: u32 = run_request_magic,
    version: u16 = 1,
    _pad0: u16 = 0,
    /// `run_flag_*` bitset. Unsupported flags are treated as reserved
    /// bytes and do not change the request's meaning.
    flags: u32 = 0,
    _reserved: [20]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(RunRequest) == 32);
}

/// Variable-length bench → probe request. The payload is model bytes followed
/// by prompt bytes and 8-byte alignment padding. `run_now=0` changes the
/// selected model and returns an updated Hello; `run_now=1` also starts it.
pub const RunSpec = extern struct {
    pub const header_bytes: usize = 32;
    pub const max_model_path: usize = 1024;
    pub const max_prompt: usize = 512;
    pub const max_payload: usize = max_model_path + max_prompt;
    pub const flag_run_now: u16 = 1 << 0;
    pub const flag_want_text: u16 = 1 << 1;

    magic: u32 = run_spec_magic,
    version: u16 = 1,
    flags: u16 = 0,
    byte_len: u32 = 0,
    threads: u32 = 4,
    n_prompt: u32 = 16,
    n_generate: u32 = 32,
    model_len: u16 = 0,
    prompt_len: u16 = 0,
    /// Q4_0 GEMV dispatcher, as `run_policy.Kernel`'s tag. Zero selects
    /// `auto` when the sender leaves this optional field unset.
    kernel: u8 = 0,
    _reserved: [3]u8 = @splat(0),

    pub const Values = struct {
        model: []const u8,
        prompt: []const u8 = "",
        threads: u32 = 4,
        n_prompt: u32 = 16,
        n_generate: u32 = 32,
        kernel: u8 = 0,
        run_now: bool = false,
        want_text: bool = false,
    };

    pub fn payloadSpan(byte_len: u32) usize {
        return std.mem.alignForward(usize, byte_len, 8);
    }

    pub fn encode(buf: []u8, values: Values) ![]const u8 {
        if (values.model.len == 0 or values.model.len > max_model_path) return error.InvalidRunSpec;
        if (values.prompt.len > max_prompt) return error.InvalidRunSpec;
        if (values.threads == 0 or values.n_prompt == 0 or values.n_generate == 0) return error.InvalidRunSpec;
        const payload_len = values.model.len + values.prompt.len;
        const total = header_bytes + payloadSpan(@intCast(payload_len));
        if (buf.len < total) return error.NoSpaceLeft;

        const header = RunSpec{
            .flags = (if (values.run_now) flag_run_now else 0) |
                (if (values.want_text) flag_want_text else 0),
            .byte_len = @intCast(payload_len),
            .threads = values.threads,
            .n_prompt = values.n_prompt,
            .n_generate = values.n_generate,
            .model_len = @intCast(values.model.len),
            .prompt_len = @intCast(values.prompt.len),
            .kernel = values.kernel,
        };
        const header_data: *const [header_bytes]u8 = @ptrCast(&header);
        @memcpy(buf[0..header_bytes], header_data);
        @memcpy(buf[header_bytes..][0..values.model.len], values.model);
        @memcpy(buf[header_bytes + values.model.len ..][0..values.prompt.len], values.prompt);
        @memset(buf[header_bytes + payload_len .. total], 0);
        return buf[0..total];
    }

    pub fn decode(frame: []const u8) !Values {
        if (frame.len < header_bytes) return error.InvalidRunSpec;
        if (std.mem.readInt(u32, frame[0..4], .little) != run_spec_magic) return error.InvalidRunSpec;
        if (std.mem.readInt(u16, frame[4..6], .little) != 1) return error.InvalidRunSpec;
        const byte_len = std.mem.readInt(u32, frame[8..12], .little);
        if (byte_len > max_payload) return error.InvalidRunSpec;
        const total = header_bytes + payloadSpan(byte_len);
        if (frame.len != total) return error.InvalidRunSpec;
        const model_len = std.mem.readInt(u16, frame[24..26], .little);
        const prompt_len = std.mem.readInt(u16, frame[26..28], .little);
        if (model_len == 0 or model_len > max_model_path or prompt_len > max_prompt) return error.InvalidRunSpec;
        if (@as(u32, model_len) + @as(u32, prompt_len) != byte_len) return error.InvalidRunSpec;
        const threads = std.mem.readInt(u32, frame[12..16], .little);
        const n_prompt = std.mem.readInt(u32, frame[16..20], .little);
        const n_generate = std.mem.readInt(u32, frame[20..24], .little);
        if (threads == 0 or n_prompt == 0 or n_generate == 0) return error.InvalidRunSpec;
        const flags = std.mem.readInt(u16, frame[6..8], .little);
        const payload = frame[header_bytes..][0..byte_len];
        return .{
            .model = payload[0..model_len],
            .prompt = payload[model_len..][0..prompt_len],
            .threads = threads,
            .n_prompt = n_prompt,
            .n_generate = n_generate,
            // Not validated: a bench newer than this probe may name a
            // kernel it has never heard of, and the reader turns an
            // unknown value into `auto` rather than refusing the frame.
            .kernel = frame[28],
            .run_now = flags & flag_run_now != 0,
            .want_text = flags & flag_want_text != 0,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(RunSpec) == RunSpec.header_bytes);
    std.debug.assert(@offsetOf(RunSpec, "byte_len") == 8);
    // `decode` reads this one by offset, like every other field.
    std.debug.assert(@offsetOf(RunSpec, "kernel") == 28);
}

/// Bounded direct-process request. The payload is a sequence of
/// little-endian u16 length prefixes followed by the bytes for each
/// argv item, then each KEY=VALUE environment override. Nothing in the
/// payload is shell text and no terminators are placed on the wire.
pub const ExecRequest = extern struct {
    pub const flag_metrics: u16 = 1 << 0;
    pub const header_bytes: usize = 32;
    pub const argv_count_max: usize = 32;
    pub const env_count_max: usize = 16;
    pub const max_payload: usize = 8 * 1024;
    pub const timeout_ms_max: u32 = 60 * 60 * 1000;

    magic: u32 = exec_request_magic,
    version: u16 = 1,
    flags: u16 = 0,
    byte_len: u32 = 0,
    timeout_ms: u32 = 0,
    run_id: u64 = 0,
    argv_count: u16 = 0,
    env_count: u16 = 0,
    _reserved: u32 = 0,

    pub const Values = struct {
        run_id: u64,
        timeout_ms: u32,
        argv: []const []const u8,
        env: []const []const u8 = &.{},
        metrics: bool = false,
    };

    pub const Decoded = struct {
        run_id: u64,
        timeout_ms: u32,
        metrics: bool = false,
        argv_count: u8,
        env_count: u8,
        argv_items: [argv_count_max][]const u8,
        env_items: [env_count_max][]const u8,

        pub fn argv(self: *const Decoded) []const []const u8 {
            return self.argv_items[0..self.argv_count];
        }

        pub fn env(self: *const Decoded) []const []const u8 {
            return self.env_items[0..self.env_count];
        }
    };

    pub fn payloadSpan(byte_len: u32) usize {
        return std.mem.alignForward(usize, byte_len, 8);
    }

    pub fn encode(buf: []u8, values: Values) ![]const u8 {
        try validateValues(values);
        const byte_len = try encodedPayloadLen(values.argv, values.env);
        const total = header_bytes + payloadSpan(@intCast(byte_len));
        if (buf.len < total) return error.NoSpaceLeft;

        const header = ExecRequest{
            .flags = if (values.metrics) flag_metrics else 0,
            .byte_len = @intCast(byte_len),
            .timeout_ms = values.timeout_ms,
            .run_id = values.run_id,
            .argv_count = @intCast(values.argv.len),
            .env_count = @intCast(values.env.len),
        };
        const header_data: *const [header_bytes]u8 = @ptrCast(&header);
        @memcpy(buf[0..header_bytes], header_data);
        var cursor = header_bytes;
        cursor = encodeItems(buf, cursor, values.argv);
        cursor = encodeItems(buf, cursor, values.env);
        std.debug.assert(cursor == header_bytes + byte_len);
        @memset(buf[cursor..total], 0);
        return buf[0..total];
    }

    /// Run ID without validating the rest of the request. A rejection
    /// has to name the run it rejected, and the reason it is being
    /// rejected may be that the request did not decode.
    pub fn peekRunId(frame: []const u8) ?u64 {
        if (frame.len < header_bytes) return null;
        const run_id = std.mem.readInt(u64, frame[16..24], .little);
        return if (run_id == 0) null else run_id;
    }

    pub fn decode(frame: []const u8, decoded: *Decoded) !void {
        if (frame.len < header_bytes) return error.InvalidExecRequest;
        if (std.mem.readInt(u32, frame[0..4], .little) != exec_request_magic) {
            return error.InvalidExecRequest;
        }
        if (std.mem.readInt(u16, frame[4..6], .little) != 1) {
            return error.InvalidExecRequest;
        }
        const byte_len = std.mem.readInt(u32, frame[8..12], .little);
        if (byte_len > max_payload) return error.InvalidExecRequest;
        if (frame.len != header_bytes + payloadSpan(byte_len)) {
            return error.InvalidExecRequest;
        }
        const argv_count = std.mem.readInt(u16, frame[24..26], .little);
        const env_count = std.mem.readInt(u16, frame[26..28], .little);
        if (argv_count == 0 or argv_count > argv_count_max) {
            return error.InvalidExecRequest;
        }
        if (env_count > env_count_max) return error.InvalidExecRequest;

        decoded.run_id = std.mem.readInt(u64, frame[16..24], .little);
        decoded.timeout_ms = std.mem.readInt(u32, frame[12..16], .little);
        decoded.metrics = std.mem.readInt(u16, frame[6..8], .little) & flag_metrics != 0;
        decoded.argv_count = @intCast(argv_count);
        decoded.env_count = @intCast(env_count);
        if (decoded.run_id == 0) return error.InvalidExecRequest;
        if (decoded.timeout_ms == 0 or decoded.timeout_ms > timeout_ms_max) {
            return error.InvalidExecRequest;
        }

        var cursor: usize = header_bytes;
        const payload_end = header_bytes + byte_len;
        cursor = try decodeItems(
            frame,
            cursor,
            payload_end,
            decoded.argv_items[0..argv_count],
        );
        cursor = try decodeItems(
            frame,
            cursor,
            payload_end,
            decoded.env_items[0..env_count],
        );
        if (cursor != payload_end) return error.InvalidExecRequest;
        if (!validArgument(decoded.argv_items[0])) return error.InvalidExecRequest;
        for (decoded.argv()) |item| {
            if (std.mem.indexOfScalar(u8, item, 0) != null) {
                return error.InvalidExecRequest;
            }
        }
        for (decoded.env()) |item| {
            if (!validEnvironment(item)) return error.InvalidExecRequest;
        }
    }

    fn validateValues(values: Values) !void {
        if (values.run_id == 0) return error.InvalidExecRequest;
        if (values.timeout_ms == 0 or values.timeout_ms > timeout_ms_max) {
            return error.InvalidExecRequest;
        }
        if (values.argv.len == 0 or values.argv.len > argv_count_max) {
            return error.InvalidExecRequest;
        }
        if (values.env.len > env_count_max) return error.InvalidExecRequest;
        if (!validArgument(values.argv[0])) return error.InvalidExecRequest;
        for (values.argv) |item| {
            if (std.mem.indexOfScalar(u8, item, 0) != null) {
                return error.InvalidExecRequest;
            }
        }
        for (values.env) |item| {
            if (!validEnvironment(item)) return error.InvalidExecRequest;
        }
    }

    fn encodedPayloadLen(argv: []const []const u8, env: []const []const u8) !usize {
        var byte_len: usize = 0;
        for (argv) |item| byte_len = try encodedPayloadLenAdd(byte_len, item.len);
        for (env) |item| byte_len = try encodedPayloadLenAdd(byte_len, item.len);
        if (byte_len > max_payload) return error.InvalidExecRequest;
        return byte_len;
    }

    fn encodedPayloadLenAdd(byte_len: usize, item_len: usize) !usize {
        if (item_len > std.math.maxInt(u16)) return error.InvalidExecRequest;
        const with_prefix = std.math.add(usize, byte_len, 2) catch {
            return error.InvalidExecRequest;
        };
        return std.math.add(usize, with_prefix, item_len) catch {
            return error.InvalidExecRequest;
        };
    }

    fn encodeItems(buf: []u8, start: usize, items: []const []const u8) usize {
        var cursor = start;
        for (items) |item| {
            std.mem.writeInt(u16, buf[cursor..][0..2], @intCast(item.len), .little);
            cursor += 2;
            @memcpy(buf[cursor..][0..item.len], item);
            cursor += item.len;
        }
        return cursor;
    }

    fn decodeItems(
        frame: []const u8,
        start: usize,
        payload_end: usize,
        items: [][]const u8,
    ) !usize {
        var cursor = start;
        for (items) |*item| {
            if (cursor + 2 > payload_end) return error.InvalidExecRequest;
            const item_len = std.mem.readInt(u16, frame[cursor..][0..2], .little);
            cursor += 2;
            if (cursor + item_len > payload_end) return error.InvalidExecRequest;
            item.* = frame[cursor..][0..item_len];
            cursor += item_len;
        }
        return cursor;
    }

    fn validArgument(argument: []const u8) bool {
        return argument.len > 0 and std.mem.indexOfScalar(u8, argument, 0) == null;
    }

    fn validEnvironment(environment: []const u8) bool {
        if (std.mem.indexOfScalar(u8, environment, 0) != null) return false;
        const equals = std.mem.indexOfScalar(u8, environment, '=') orelse return false;
        if (equals == 0) return false;
        if (!validEnvironmentStart(environment[0])) return false;
        for (environment[1..equals]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
        }
        return true;
    }

    fn validEnvironmentStart(byte: u8) bool {
        return std.ascii.isAlphabetic(byte) or byte == '_';
    }
};

comptime {
    std.debug.assert(@sizeOf(ExecRequest) == ExecRequest.header_bytes);
    std.debug.assert(@offsetOf(ExecRequest, "byte_len") == 8);
}

/// One stdout or stderr chunk from a direct child. Sequence numbers
/// are global across both streams, making their observed order auditable.
pub const RawOutput = extern struct {
    pub const header_bytes: usize = 24;
    pub const max_payload: usize = 4 * 1024;

    magic: u32 = raw_output_magic,
    version: u16 = 1,
    stream: Stream = .stdout,
    flags: u8 = 0,
    byte_len: u32 = 0,
    seq: u32 = 0,
    run_id: u64 = 0,

    pub const Stream = enum(u8) { stdout = 1, stderr = 2 };

    pub const Values = struct {
        run_id: u64,
        seq: u32,
        stream: Stream,
        bytes: []const u8,
    };

    pub fn payloadSpan(byte_len: u32) usize {
        return std.mem.alignForward(usize, byte_len, 8);
    }

    pub fn encode(buf: []u8, values: Values) ![]const u8 {
        if (values.run_id == 0 or values.bytes.len > max_payload) {
            return error.InvalidRawOutput;
        }
        const total = header_bytes + payloadSpan(@intCast(values.bytes.len));
        if (buf.len < total) return error.NoSpaceLeft;
        const header = RawOutput{
            .stream = values.stream,
            .byte_len = @intCast(values.bytes.len),
            .seq = values.seq,
            .run_id = values.run_id,
        };
        const header_data: *const [header_bytes]u8 = @ptrCast(&header);
        @memcpy(buf[0..header_bytes], header_data);
        @memcpy(buf[header_bytes..][0..values.bytes.len], values.bytes);
        @memset(buf[header_bytes + values.bytes.len .. total], 0);
        return buf[0..total];
    }

    pub fn decode(frame: []const u8) !Values {
        if (frame.len < header_bytes) return error.InvalidRawOutput;
        if (std.mem.readInt(u32, frame[0..4], .little) != raw_output_magic) {
            return error.InvalidRawOutput;
        }
        if (std.mem.readInt(u16, frame[4..6], .little) != 1) {
            return error.InvalidRawOutput;
        }
        const byte_len = std.mem.readInt(u32, frame[8..12], .little);
        if (byte_len > max_payload) return error.InvalidRawOutput;
        if (frame.len != header_bytes + payloadSpan(byte_len)) {
            return error.InvalidRawOutput;
        }
        const stream = std.enums.fromInt(Stream, frame[6]) orelse {
            return error.InvalidRawOutput;
        };
        const run_id = std.mem.readInt(u64, frame[16..24], .little);
        if (run_id == 0) return error.InvalidRawOutput;
        return .{
            .run_id = run_id,
            .seq = std.mem.readInt(u32, frame[12..16], .little),
            .stream = stream,
            .bytes = frame[header_bytes..][0..byte_len],
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(RawOutput) == RawOutput.header_bytes);
    std.debug.assert(@offsetOf(RawOutput, "byte_len") == 8);
}

pub const ExecEvent = extern struct {
    magic: u32 = exec_event_magic,
    version: u16 = 1,
    kind: Kind,
    reason: Reason = .none,
    run_id: u64,
    elapsed_ns: u64 = 0,
    exit_code: i32 = 0,
    signal: u16 = 0,
    _reserved: u16 = 0,

    pub const Kind = enum(u8) { accepted = 1, rejected = 2, exited = 3, cancelled = 4 };
    pub const Reason = enum(u8) {
        none = 0,
        disabled = 1,
        busy = 2,
        invalid_request = 3,
        spawn_failed = 4,
        timeout = 5,
        output_limit = 6,
        client_cancel = 7,
        client_disconnect = 8,
        io_error = 9,
    };
};

pub const ExecCancel = extern struct {
    magic: u32 = exec_cancel_magic,
    version: u16 = 1,
    _pad0: u16 = 0,
    run_id: u64,
    _reserved: u64 = 0,
};

/// Optional whole-process diagnostics, sent before the terminal ExecEvent.
/// Emitted only when ExecRequest.flag_metrics is set. Missing data is
/// represented by flags, never by numeric zero.
pub const ExecMetrics = extern struct {
    pub const flag_usage: u16 = 1 << 0;
    pub const flag_frequency: u16 = 1 << 1;
    pub const policies_max = 8;
    pub const bins_max = 32;

    pub const Bin = extern struct { khz: u32 = 0, _pad: u32 = 0, ticks: u64 = 0 };
    pub const Policy = extern struct {
        id: u16 = 0,
        count: u16 = 0,
        _pad: u32 = 0,
        bins: [bins_max]Bin = @splat(.{}),
    };

    magic: u32 = exec_metrics_magic,
    version: u16 = 1,
    flags: u16 = 0,
    run_id: u64 = 0,
    user_ns: u64 = 0,
    system_ns: u64 = 0,
    minor_faults: u64 = 0,
    major_faults: u64 = 0,
    max_rss_bytes: u64 = 0,
    /// Window surrounding spawn and reap, including counter-read overhead.
    frequency_window_ns: u64 = 0,
    policy_count: u16 = 0,
    _pad: [6]u8 = @splat(0),
    policies: [policies_max]Policy = @splat(.{}),

    pub fn valid(self: *const ExecMetrics) bool {
        if (self.version != 1 or self.policy_count > policies_max) return false;
        for (self.policies[0..self.policy_count]) |policy| {
            if (policy.count > bins_max) return false;
        }
        return true;
    }
};

test "exec metrics are opt-in and bounded without changing the lifecycle frame" {
    var buf: [max_frame_bytes]u8 align(8) = undefined;
    var decoded: ExecRequest.Decoded = undefined;
    var frame = try ExecRequest.encode(&buf, .{ .run_id = 1, .timeout_ms = 100, .argv = &.{"/bin/true"} });
    try ExecRequest.decode(frame, &decoded);
    try std.testing.expect(!decoded.metrics);
    frame = try ExecRequest.encode(&buf, .{ .run_id = 1, .timeout_ms = 100, .argv = &.{"/bin/true"}, .metrics = true });
    try ExecRequest.decode(frame, &decoded);
    try std.testing.expect(decoded.metrics);
    var metrics: ExecMetrics = .{ .run_id = 1 };
    try std.testing.expectEqual(@as(usize, @sizeOf(ExecMetrics)), frameSpan(std.mem.asBytes(&metrics)).total);
    try std.testing.expect(metrics.valid());
    metrics.policy_count = ExecMetrics.policies_max + 1;
    try std.testing.expect(!metrics.valid());
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ExecEvent));
}

comptime {
    std.debug.assert(@sizeOf(ExecEvent) == 32);
    std.debug.assert(@sizeOf(ExecCancel) == 24);
}

/// Derive a tweet-friendly model display name from a .gguf path.
/// Strips the directory, the `.gguf` extension, and known quant
/// suffixes iteratively (so `Sample-0.6B-Q4_0.gguf` resolves to
/// `Sample-0.6B`). Returns the input unchanged if it doesn't match the
/// expected shape — a `--name FOO` override on zzzprobe is the escape
/// hatch. Used by zzzprobe to populate Hello.model_name and by
/// zzzbench to derive a title-bar fallback when its `--engine-model`
/// path is set but no probe Hello carries a name.
pub fn deriveModelName(path: []const u8) []const u8 {
    var name = stem(path);
    var changed = true;
    while (changed) {
        changed = false;
        for (quant_suffixes) |s| {
            if (std.mem.endsWith(u8, name, s)) {
                name = name[0 .. name.len - s.len];
                changed = true;
                // Break so each outer pass strips at most one suffix —
                // makes the loop deterministic regardless of list
                // order. Stacked quant tags still all
                // peel off because the outer `while (changed)` runs
                // again after each strip.
                break;
            }
        }
    }
    return name;
}

/// The quant tag a `.gguf` filename carries (`Sample-0.6B-Q4_K_M.gguf`
/// → `Q4_K_M`), or null when the name has none. Reads the same
/// vocabulary `deriveModelName` strips, so the display name and the
/// quant label can never disagree about where the name ends.
///
/// Filename beats header inspection here on purpose: a `_M` mix is
/// several ggml types at once, and picking the most common one by
/// element count can mislabel a mixed-format model. Preserve the
/// quantization label chosen by the file producer.
pub fn quantFromPath(path: []const u8) ?[]const u8 {
    const name = stem(path);
    for (quant_suffixes) |s| {
        if (std.mem.endsWith(u8, name, s)) return s[1..];
    }
    return null;
}

/// Basename with the `.gguf` extension removed.
fn stem(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.endsWith(u8, name, ".gguf")) name = name[0 .. name.len - ".gguf".len];
    return name;
}

/// Quant tags a `.gguf` filename may carry, leading `-` included so
/// both the stripper and the reader match on the same boundary.
const quant_suffixes = [_][]const u8{
    "-Q2_K",   "-Q3_K_S", "-Q3_K_M", "-Q3_K_L",
    "-Q4_0",   "-Q4_K_S", "-Q4_K_M", "-Q5_K_S",
    "-Q5_K_M", "-Q6_K",   "-Q8_0",   "-IQ3_XXS",
    "-IQ4_NL", "-IQ4_XS",
};

/// Header of the one variable-length frame on the wire: a run of
/// decoded token text, emitted by the engine and forwarded verbatim by
/// the probe.
///
/// Every other frame is a fixed-size struct whose length the magic
/// alone determines. Text has no such length — a token piece is 1 byte
/// or 12 — and padding it into fixed chunks would mean sending 128
/// bytes per ~5-byte token, at one frame per token, which is the rate
/// the panel needs to animate. So this frame carries its own length.
///
/// Two properties keep that from costing the readers anything:
///
///   * `payloadSpan` rounds the payload up to a multiple of 8, so the
///     head of the next frame stays 8-aligned in a shared read buffer.
///     Every fixed frame is already a multiple of 8; this keeps the
///     invariant that `extractFrame`'s `@alignCast` relies on.
///   * `byte_len` above `max_payload` is a desync, not an allocation.
///     A corrupt length can therefore never ask a reader for more than
///     `max_frame_bytes`, which every read buffer is sized to hold.
pub const TokenText = extern struct {
    /// Ceiling on one frame's text. Sized to hold any single token
    /// piece with room to coalesce a burst, while keeping the whole
    /// frame small enough that every read buffer can stay a fixed
    /// array on the stack — including on the Android probe, which
    /// allocates nothing on the read path.
    pub const max_payload: usize = 512;
    pub const header_bytes: usize = 16;

    /// Set on the last frame of a run, so a reader can tell "the model
    /// stopped" from "the next chunk has not arrived yet".
    pub const flag_final: u16 = 1 << 0;

    magic: u32 = token_text_magic,
    version: u16 = 1,
    /// `TokenText.flag_*` bitset.
    flags: u16 = 0,
    /// 0-based index of this chunk within its run. A gap means text
    /// was dropped rather than silently reordered.
    seq: u32 = 0,
    /// Payload bytes that follow the header. The frame on the wire is
    /// `header_bytes + payloadSpan(byte_len)` long; bytes past
    /// `byte_len` are padding and carry no text.
    byte_len: u32 = 0,

    /// Wire bytes a payload of `byte_len` occupies, including the
    /// alignment padding that keeps the following frame 8-aligned.
    pub fn payloadSpan(byte_len: u32) usize {
        return std.mem.alignForward(usize, byte_len, 8);
    }
};

comptime {
    std.debug.assert(@sizeOf(TokenText) == TokenText.header_bytes);
    std.debug.assert(TokenText.header_bytes % 8 == 0);
    // `frameSpan` reads byte_len by offset, before it can cast.
    std.debug.assert(@offsetOf(TokenText, "byte_len") == 12);
}

/// Largest frame any reader must be able to hold whole.
pub const max_frame_bytes: usize = @max(
    @max(
        TokenText.header_bytes + TokenText.max_payload,
        RunSpec.header_bytes + RunSpec.max_payload,
    ),
    @max(
        ExecRequest.header_bytes + ExecRequest.max_payload,
        RawOutput.header_bytes + RawOutput.max_payload,
    ),
);

comptime {
    std.debug.assert(max_frame_bytes >= @sizeOf(TelemetryFrame));
    std.debug.assert(max_frame_bytes >= @sizeOf(Hello));
    std.debug.assert(max_frame_bytes >= @sizeOf(ExecMetrics));
}

/// How much of a frame is present at the head of `buf`.
pub const FrameSpan = union(enum) {
    /// Not enough bytes to know the length yet — read more.
    need_more,
    /// Unknown magic, or a length no valid frame could carry. Caller
    /// treats this as a wire desync (consistent with readFrame's
    /// BadMagic path) and resyncs by reconnecting.
    desync,
    /// Total bytes of the frame at `buf[0..]`, including its header.
    total: usize,
};

/// Magic-dispatch helper, and the single place that knows how long a
/// frame is. Fixed frames answer from the magic alone; the variable
/// one needs its header read first, which is why this takes the buffer
/// rather than a `u32`.
pub fn frameSpan(buf: []const u8) FrameSpan {
    if (buf.len < 4) return .need_more;
    const m = std.mem.readInt(u32, buf[0..4], .little);
    if (fixedFrameSize(m)) |n| return .{ .total = n };
    const header_bytes: usize, const len_at: usize, const max_payload: usize = switch (m) {
        token_text_magic => .{
            TokenText.header_bytes,
            @offsetOf(TokenText, "byte_len"),
            TokenText.max_payload,
        },
        run_spec_magic => .{
            RunSpec.header_bytes,
            @offsetOf(RunSpec, "byte_len"),
            RunSpec.max_payload,
        },
        exec_request_magic => .{
            ExecRequest.header_bytes,
            @offsetOf(ExecRequest, "byte_len"),
            ExecRequest.max_payload,
        },
        raw_output_magic => .{
            RawOutput.header_bytes,
            @offsetOf(RawOutput, "byte_len"),
            RawOutput.max_payload,
        },
        else => return .desync,
    };
    if (buf.len < header_bytes) return .need_more;
    // Read the length field out of the bytes rather than casting to
    // the struct: the length has to be knowable before we've decided
    // the buffer holds a whole frame, and a reader may be looking at
    // an unaligned tail. The offset comes from the struct rather than
    // a literal — the two variable-length frames do not carry it in
    // the same place, and a wrong offset reads as a desync loop on the
    // wire, not as a compile error.
    const byte_len = std.mem.readInt(u32, buf[len_at..][0..4], .little);
    if (byte_len > max_payload) return .desync;
    return .{ .total = header_bytes + std.mem.alignForward(usize, byte_len, 8) };
}

/// Size of the fixed-length frames, or null for a magic that is either
/// variable-length or unknown. Prefer `frameSpan` unless you genuinely
/// only care about the fixed set (e.g. sizing a struct-shaped buffer).
pub fn fixedFrameSize(m: u32) ?usize {
    return switch (m) {
        magic => @sizeOf(TelemetryFrame),
        hello_magic => @sizeOf(Hello),
        hardware_info_magic => @sizeOf(HardwareInfo),
        hardware_info_request_magic => @sizeOf(HardwareInfoRequest),
        engine_report_magic => @sizeOf(EngineReport),
        run_request_magic => @sizeOf(RunRequest),
        exec_event_magic => @sizeOf(ExecEvent),
        exec_metrics_magic => @sizeOf(ExecMetrics),
        exec_cancel_magic => @sizeOf(ExecCancel),
        else => null,
    };
}

/// One sample tick. Fixed size so probe + bench can `@bitCast` without
/// a parser. Counts/temps use sentinel values when unavailable on the
/// host (see field comments).
pub const TelemetryFrame = extern struct {
    magic: u32 = magic,
    version: u16 = version,
    _pad0: u16 = 0,

    /// Monotonic nanoseconds since probe start.
    ts_ns: u64,

    // CPU — Pixel 8 / Tensor G3 has 1 prime + 4 big + 4 little. We
    // model the upper bound (8 cores) and use NaN for absent slots.
    cpu_util_pct: [8]f32, // 0..100, NaN if absent
    cpu_freq_mhz: [8]u32, // 0 if absent

    /// GPU utilisation 0..100, NaN if no GPU sampling on this host.
    gpu_util_pct: f32,

    /// Resident RAM of the inference process, MB. 0 = no process attached.
    proc_rss_mb: u32,
    /// Total system RAM in use, MB.
    sys_used_mb: u32,
    /// Total system RAM, MB.
    sys_total_mb: u32,

    /// Skin and SoC thermal zones in milli-celsius. INT32_MIN if absent.
    skin_temp_mc: i32,
    soc_temp_mc: i32,

    /// 1 if any thermal zone is in throttle, 0 otherwise.
    throttling: u8,
    _pad1: [3]u8 = .{ 0, 0, 0 },

    /// Live decode tok/s. NaN until the bench publishes a measurement
    /// back to the probe (future: bidirectional). For now the probe
    /// just emits 0 and the bench overlays its own number.
    decode_tok_s: f32,
    /// Live prefill tok/s. Same caveat.
    prefill_tok_s: f32,

    /// Instantaneous power draw in milliwatts. `maxInt(u32)` is the
    /// sentinel for "not sampled" — picked so a real zero-watt
    /// reading (briefly possible during a `batterystats` reset)
    /// doesn't collide with the absent value. The synthetic probe
    /// path on macOS emits sample values here.
    power_mw: u32,

    /// iOS memory headroom before Jetsam pressure, MB. `maxInt(u32)` means
    /// the host cannot sample it; 0 means sampled and currently no headroom.
    mem_available_mb: u32 = std.math.maxInt(u32),

    /// iOS-only extension fields. These reuse the v1 trailing frame padding
    /// without changing frame size; non-iOS probes leave them at sentinels.
    ios_battery_pct: u8 = ios_battery_pct_unavailable, // 0..100, 255 absent
    ios_power_state: u8 = @intFromEnum(IosPowerState.unknown),
    ios_thermal_state: u8 = @intFromEnum(IosThermalState.unknown),
    ios_flags: u8 = 0,
};

comptime {
    // Locking the size catches accidental field churn — bump `version`
    // when changing the layout.
    std.debug.assert(@sizeOf(TelemetryFrame) == 128);
}

/// A frame with every field set to its "absent" sentinel — NaN for
/// floats, 0 for unsigned counters, INT32_MIN for signed temps. Used
/// by the probe on real-data hosts (Linux/Android) as the per-tick
/// baseline before sysfs.fillFrame overlays whatever it can read.
/// Fields the host doesn't expose (GPU%, thermal zones blocked by
/// SELinux on shell, power on devices without batterystats access)
/// stay sentinel and render as "—" in the bench, instead of carrying
/// stale synthetic numbers that mislead screencap viewers.
pub fn sentinelFrame(ts_ns: u64) TelemetryFrame {
    return .{
        .ts_ns = ts_ns,
        .cpu_util_pct = @splat(std.math.nan(f32)),
        .cpu_freq_mhz = @splat(0),
        .gpu_util_pct = std.math.nan(f32),
        .proc_rss_mb = 0,
        .sys_used_mb = 0,
        .sys_total_mb = 0,
        .skin_temp_mc = std.math.minInt(i32),
        .soc_temp_mc = std.math.minInt(i32),
        .throttling = 0,
        .decode_tok_s = std.math.nan(f32),
        .prefill_tok_s = std.math.nan(f32),
        .power_mw = std.math.maxInt(u32),
        .mem_available_mb = std.math.maxInt(u32),
        .ios_battery_pct = ios_battery_pct_unavailable,
        .ios_power_state = @intFromEnum(IosPowerState.unknown),
        .ios_thermal_state = @intFromEnum(IosThermalState.unknown),
        .ios_flags = 0,
    };
}

/// Write one frame to a stream.
pub fn writeFrame(writer: anytype, frame: *const TelemetryFrame) !void {
    const bytes: *const [@sizeOf(TelemetryFrame)]u8 = @ptrCast(frame);
    try writer.writeAll(bytes);
}

/// Read one frame from a stream. Errors on EOF or magic/version mismatch.
pub fn readFrame(reader: anytype) !TelemetryFrame {
    var frame: TelemetryFrame = undefined;
    const bytes: *[@sizeOf(TelemetryFrame)]u8 = @ptrCast(&frame);
    try reader.readSliceAll(bytes);
    if (frame.magic != magic) return error.BadMagic;
    if (frame.version != version) return error.VersionMismatch;
    return frame;
}

test "fixedFrameSize dispatch" {
    try std.testing.expectEqual(@as(?usize, @sizeOf(TelemetryFrame)), fixedFrameSize(magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(Hello)), fixedFrameSize(hello_magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(HardwareInfo)), fixedFrameSize(hardware_info_magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(HardwareInfoRequest)), fixedFrameSize(hardware_info_request_magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(EngineReport)), fixedFrameSize(engine_report_magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(RunRequest)), fixedFrameSize(run_request_magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(ExecEvent)), fixedFrameSize(exec_event_magic));
    try std.testing.expectEqual(@as(?usize, @sizeOf(ExecCancel)), fixedFrameSize(exec_cancel_magic));
    try std.testing.expectEqual(@as(?usize, null), fixedFrameSize(run_spec_magic));
    try std.testing.expectEqual(@as(?usize, null), fixedFrameSize(exec_request_magic));
    try std.testing.expectEqual(@as(?usize, null), fixedFrameSize(raw_output_magic));
    try std.testing.expectEqual(@as(?usize, null), fixedFrameSize(0xDEAD_BEEF));
    // Variable-length: the magic alone cannot answer.
    try std.testing.expectEqual(@as(?usize, null), fixedFrameSize(token_text_magic));
}

test "frameSpan needs the header before it can size a text frame" {
    var buf: [proto_test_buf]u8 align(8) = @splat(0);
    std.mem.writeInt(u32, buf[0..4], token_text_magic, .little);

    try std.testing.expectEqual(FrameSpan.need_more, frameSpan(buf[0..2]));
    try std.testing.expectEqual(FrameSpan.need_more, frameSpan(buf[0 .. TokenText.header_bytes - 1]));

    // 5 bytes of text pad out to an 8-byte span, so the frame after it
    // stays 8-aligned in a shared read buffer.
    std.mem.writeInt(u32, buf[12..16], 5, .little);
    try std.testing.expectEqual(
        FrameSpan{ .total = TokenText.header_bytes + 8 },
        frameSpan(&buf),
    );
    try std.testing.expectEqual(@as(usize, 0), frameSpan(&buf).total % 8);

    // An empty chunk is legal and occupies just its header.
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    try std.testing.expectEqual(
        FrameSpan{ .total = TokenText.header_bytes },
        frameSpan(&buf),
    );
}

test "frameSpan treats an oversized length as desync, never as an allocation" {
    var buf: [proto_test_buf]u8 align(8) = @splat(0);
    std.mem.writeInt(u32, buf[0..4], token_text_magic, .little);
    std.mem.writeInt(u32, buf[12..16], @intCast(TokenText.max_payload + 1), .little);
    try std.testing.expectEqual(FrameSpan.desync, frameSpan(&buf));

    std.mem.writeInt(u32, buf[12..16], std.math.maxInt(u32), .little);
    try std.testing.expectEqual(FrameSpan.desync, frameSpan(&buf));

    // The bound is what lets every reader hold a whole frame in a
    // fixed buffer.
    std.mem.writeInt(u32, buf[12..16], @intCast(TokenText.max_payload), .little);
    try std.testing.expectEqual(
        FrameSpan{ .total = TokenText.header_bytes + TokenText.max_payload },
        frameSpan(&buf),
    );
    try std.testing.expect(TokenText.header_bytes + TokenText.max_payload <= max_frame_bytes);
}

test "frameSpan rejects unknown magic" {
    var buf: [proto_test_buf]u8 align(8) = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 0xDEAD_BEEF, .little);
    try std.testing.expectEqual(FrameSpan.desync, frameSpan(&buf));
}

const proto_test_buf = max_frame_bytes;

test "HardwareInfo fits in 128 bytes and slices names" {
    var hw = HardwareInfo{ .flags = hardware_info_flag_gpu_name_read | hardware_info_flag_soc_inferred };
    const machine = "iPhone15,2";
    const soc = "A16 Bionic";
    const gpu = "Apple A16 GPU";
    @memcpy(hw.machine[0..machine.len], machine);
    @memcpy(hw.soc_name[0..soc.len], soc);
    @memcpy(hw.gpu_name[0..gpu.len], gpu);

    try std.testing.expectEqual(@as(usize, 128), @sizeOf(HardwareInfo));
    try std.testing.expectEqualStrings(machine, HardwareInfo.machineSlice(&hw.machine));
    try std.testing.expectEqualStrings(soc, HardwareInfo.nameSlice(&hw.soc_name));
    try std.testing.expectEqualStrings(gpu, HardwareInfo.nameSlice(&hw.gpu_name));
    try std.testing.expectEqual(hardware_info_flag_gpu_name_read | hardware_info_flag_soc_inferred, hw.flags);
}

test "RunRequest defaults" {
    const r = RunRequest{};
    try std.testing.expectEqual(run_request_magic, r.magic);
    try std.testing.expectEqual(@as(u16, 1), r.version);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RunRequest));
}

test "RunSpec packs a model and prompt into one bounded frame" {
    var buf: [max_frame_bytes]u8 align(8) = undefined;
    const spec: RunSpec.Values = .{
        .model = "/data/local/tmp/models/qwen.gguf",
        .prompt = "The capital of France is",
        .threads = 6,
        .n_prompt = 512,
        .n_generate = 128,
        .run_now = true,
        .want_text = true,
    };

    const encoded = try RunSpec.encode(&buf, spec);
    try std.testing.expectEqual(FrameSpan{ .total = encoded.len }, frameSpan(encoded));
    const decoded = try RunSpec.decode(encoded);
    try std.testing.expectEqualStrings(spec.model, decoded.model);
    try std.testing.expectEqualStrings(spec.prompt, decoded.prompt);
    try std.testing.expectEqual(spec.threads, decoded.threads);
    try std.testing.expectEqual(spec.n_prompt, decoded.n_prompt);
    try std.testing.expectEqual(spec.n_generate, decoded.n_generate);
    try std.testing.expect(decoded.run_now);
    try std.testing.expect(decoded.want_text);
}

test "RunSpec carries a kernel choice without growing or bumping version" {
    var buf: [max_frame_bytes]u8 align(8) = undefined;
    const encoded = try RunSpec.encode(&buf, .{ .model = "m.gguf", .kernel = 2 });
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RunSpec));
    try std.testing.expectEqual(@as(u8, 2), (try RunSpec.decode(encoded)).kernel);

    // An unset optional kernel field selects `auto`.
    const default_kernel = try RunSpec.encode(&buf, .{ .model = "m.gguf" });
    try std.testing.expectEqual(@as(u8, 0), (try RunSpec.decode(default_kernel)).kernel);
}

test "RunSpec rejects inconsistent and oversized payload lengths" {
    var buf: [max_frame_bytes]u8 align(8) = @splat(0);
    const encoded = try RunSpec.encode(&buf, .{ .model = "model.gguf" });
    std.mem.writeInt(u16, buf[24..26], 99, .little);
    try std.testing.expectError(error.InvalidRunSpec, RunSpec.decode(encoded));

    std.mem.writeInt(u32, buf[8..12], @intCast(RunSpec.max_payload + 1), .little);
    try std.testing.expectEqual(FrameSpan.desync, frameSpan(&buf));
}

test "ExecRequest round-trips bounded argv and environment without shell text" {
    var frame_buf: [max_frame_bytes]u8 align(8) = undefined;
    const encoded = try ExecRequest.encode(&frame_buf, .{
        .run_id = 42,
        .timeout_ms = 5_000,
        .argv = &.{ "/data/local/tmp/llama-bench", "model with spaces.gguf", "-o", "json" },
        .env = &.{ "LD_LIBRARY_PATH=/data/local/tmp/lib", "OMP_NUM_THREADS=8" },
    });
    try std.testing.expectEqual(FrameSpan{ .total = encoded.len }, frameSpan(encoded));

    var decoded: ExecRequest.Decoded = undefined;
    try ExecRequest.decode(encoded, &decoded);
    try std.testing.expectEqual(@as(u64, 42), decoded.run_id);
    try std.testing.expectEqual(@as(u32, 5_000), decoded.timeout_ms);
    try std.testing.expectEqual(@as(usize, 4), decoded.argv().len);
    try std.testing.expectEqualStrings("model with spaces.gguf", decoded.argv()[1]);
    try std.testing.expectEqual(@as(usize, 2), decoded.env().len);
    try std.testing.expectEqualStrings("OMP_NUM_THREADS=8", decoded.env()[1]);
}

test "ExecRequest rejects malformed commands before process execution" {
    var frame_buf: [max_frame_bytes]u8 align(8) = undefined;
    try std.testing.expectError(error.InvalidExecRequest, ExecRequest.encode(&frame_buf, .{
        .run_id = 1,
        .timeout_ms = 1,
        .argv = &.{},
    }));
    try std.testing.expectError(error.InvalidExecRequest, ExecRequest.encode(&frame_buf, .{
        .run_id = 1,
        .timeout_ms = 1,
        .argv = &.{"bad\x00command"},
    }));
    try std.testing.expectError(error.InvalidExecRequest, ExecRequest.encode(&frame_buf, .{
        .run_id = 1,
        .timeout_ms = 1,
        .argv = &.{"true"},
        .env = &.{"NOT-AN-ENV=value"},
    }));

    var oversized_argv: [ExecRequest.argv_count_max + 1][]const u8 = @splat("x");
    try std.testing.expectError(error.InvalidExecRequest, ExecRequest.encode(&frame_buf, .{
        .run_id = 1,
        .timeout_ms = 1,
        .argv = &oversized_argv,
    }));
}

test "RawOutput carries one bounded stream chunk and rejects oversized lengths" {
    var frame_buf: [max_frame_bytes]u8 align(8) = undefined;
    const encoded = try RawOutput.encode(&frame_buf, .{
        .run_id = 7,
        .seq = 9,
        .stream = .stderr,
        .bytes = "warning\n",
    });
    const decoded = try RawOutput.decode(encoded);
    try std.testing.expectEqual(@as(u64, 7), decoded.run_id);
    try std.testing.expectEqual(@as(u32, 9), decoded.seq);
    try std.testing.expectEqual(RawOutput.Stream.stderr, decoded.stream);
    try std.testing.expectEqualStrings("warning\n", decoded.bytes);

    std.mem.writeInt(u32, frame_buf[8..12], @intCast(RawOutput.max_payload + 1), .little);
    try std.testing.expectEqual(FrameSpan.desync, frameSpan(&frame_buf));
}

test "exec event and cancellation remain fixed frames" {
    const event = ExecEvent{
        .kind = .exited,
        .reason = .timeout,
        .run_id = 99,
        .elapsed_ns = 123,
        .exit_code = -1,
    };
    const cancel = ExecCancel{ .run_id = 99 };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ExecEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ExecCancel));
    try std.testing.expectEqual(@as(?usize, 32), fixedFrameSize(event.magic));
    try std.testing.expectEqual(@as(?usize, 24), fixedFrameSize(cancel.magic));
}

test "Hello advertises additive protocol support without changing size" {
    const current = Hello{};
    try std.testing.expectEqual(protocol_version, current.proto_version);
    // Ordinary run parameters stayed at level 1 when the kernel pin
    // took level 2: a probe that handles RunSpec perfectly well must
    // not be disqualified by a capability it does not need.
    try std.testing.expect(run_spec_min_version < kernel_pin_min_version);
    try std.testing.expect(protocol_version > kernel_pin_min_version);
    try std.testing.expectEqual(@as(u8, 0), current.capabilities);
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Hello));

    var minimal = std.mem.zeroes(Hello);
    minimal.magic = hello_magic;
    minimal.version = 1;
    try std.testing.expectEqual(@as(u8, 0), minimal.proto_version);
    // Zero core counts mean "unknown".
    try std.testing.expectEqual(@as(u8, 0), minimal.total_cores);
    try std.testing.expectEqual(@as(u8, 0), minimal.perf_cores);
}

test "HardwareInfoRequest defaults" {
    const r = HardwareInfoRequest{};
    try std.testing.expectEqual(hardware_info_request_magic, r.magic);
    try std.testing.expectEqual(@as(u16, 1), r.version);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(HardwareInfoRequest));
}

test "Hello has_engine fits in 128 bytes" {
    const h = Hello{ .has_engine = 1 };
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Hello));
    try std.testing.expectEqual(@as(u8, 1), h.has_engine);
}

test "Hello model_name round-trip" {
    var h = Hello{};
    const name = "Sample-0.6B";
    @memcpy(h.model_name[0..name.len], name);
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Hello));
    try std.testing.expectEqualStrings(name, Hello.nameSlice(&h.model_name));
}

test "deriveModelName strips path + extension + stacked quant suffixes" {
    try std.testing.expectEqualStrings("Sample", deriveModelName("Sample-Q4_0-Q8_0.gguf"));
    try std.testing.expectEqualStrings("Sample-0.6B", deriveModelName("/data/local/tmp/Sample-0.6B-Q4_0.gguf"));
    try std.testing.expectEqualStrings("Llama-3.2-1B-Instruct", deriveModelName("Llama-3.2-1B-Instruct-Q4_K_M.gguf"));
    try std.testing.expectEqualStrings("gemma-3-1b-it", deriveModelName("gemma-3-1b-it-Q6_K.gguf"));
    try std.testing.expectEqualStrings("plain", deriveModelName("plain.gguf"));
    try std.testing.expectEqualStrings("noext", deriveModelName("noext"));
    // Community quants beyond the K-quant series.
    try std.testing.expectEqualStrings("phi-3-mini", deriveModelName("phi-3-mini-Q2_K.gguf"));
    try std.testing.expectEqualStrings("mistral-7b", deriveModelName("mistral-7b-IQ4_NL.gguf"));
    try std.testing.expectEqualStrings("tinyllama", deriveModelName("tinyllama-IQ3_XXS.gguf"));
}

test "quantFromPath reads the tag deriveModelName strips" {
    try std.testing.expectEqualStrings("Q4_K_M", quantFromPath("Llama-3.2-1B-Instruct-Q4_K_M.gguf").?);
    try std.testing.expectEqualStrings("Q6_K", quantFromPath("/models/gemma-3-1b-it-Q6_K.gguf").?);
    // A standard quantization suffix can be read without opening the model.
    try std.testing.expectEqualStrings("Q4_0", quantFromPath("Sample-0.6B-Q4_0.gguf").?);
    // Names with no tag fall through so the caller can inspect the header.
    try std.testing.expectEqual(@as(?[]const u8, null), quantFromPath("Sample-8B.gguf"));
    try std.testing.expectEqual(@as(?[]const u8, null), quantFromPath("plain.gguf"));
}

test "frame round-trip" {
    var buf: [@sizeOf(TelemetryFrame)]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const out = TelemetryFrame{
        .ts_ns = 12345,
        .cpu_util_pct = .{ 10, 20, 30, 40, 50, 60, 70, 80 },
        .cpu_freq_mhz = .{ 900, 900, 900, 900, 900, 900, 900, 900 },
        .gpu_util_pct = 0,
        .proc_rss_mb = 412,
        .sys_used_mb = 4096,
        .sys_total_mb = 12288,
        .skin_temp_mc = 34_200,
        .soc_temp_mc = 41_800,
        .throttling = 0,
        .decode_tok_s = 20.41,
        .prefill_tok_s = 820.0,
        .power_mw = 3100,
        .ios_battery_pct = 87,
        .ios_power_state = @intFromEnum(IosPowerState.charging),
        .ios_thermal_state = @intFromEnum(IosThermalState.fair),
        .ios_flags = ios_flag_low_power_mode,
    };
    try writeFrame(&writer, &out);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    const back = try readFrame(&reader);
    try std.testing.expectEqual(@as(u64, 12345), back.ts_ns);
    try std.testing.expectEqual(@as(u32, 412), back.proc_rss_mb);
    try std.testing.expectEqual(@as(u8, 87), back.ios_battery_pct);
    try std.testing.expectEqual(@as(u8, @intFromEnum(IosPowerState.charging)), back.ios_power_state);
    try std.testing.expectEqual(@as(u8, @intFromEnum(IosThermalState.fair)), back.ios_thermal_state);
    try std.testing.expectEqual(@as(u8, ios_flag_low_power_mode), back.ios_flags);
}

// Unrecognized filename metadata belongs to the producer, not this parser.
test "model names preserve unrecognized filename suffixes" {
    const path = "/models/Sample-Q4_0-custom.gguf";
    try std.testing.expectEqualStrings("Sample-Q4_0-custom", deriveModelName(path));
    try std.testing.expectEqual(@as(?[]const u8, null), quantFromPath(path));
}
