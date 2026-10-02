//! Transport-neutral device records used by discovery, selection, and
//! bootstrap. Strings are owned by the caller's process-lifetime arena.

pub const Platform = enum {
    android,
    ios,
    host,

    pub fn label(self: Platform) []const u8 {
        return switch (self) {
            .android => "android",
            .ios => "ios",
            .host => "macos",
        };
    }
};

pub const ProbeState = enum {
    live,
    missing,
    unknown,

    pub fn label(self: ProbeState) []const u8 {
        return @tagName(self);
    }
};

pub const Candidate = struct {
    platform: Platform,
    /// Stable transport identifier: adb serial, CoreDevice identifier,
    /// or `localhost` for the host.
    id: []const u8,
    name: []const u8,
    soc: []const u8 = "",
    transport: []const u8,
    /// Transport-level readiness (`device`, `unauthorized`, `offline`,
    /// `paired`, or `ready`). Kept separate from probe state so discovery can
    /// explain why an attached device cannot be launched.
    transport_state: []const u8 = "ready",
    selectable: bool = true,
    /// Filled when discovery can address the probe directly. Android
    /// receives an endpoint only after `adb forward` during prepare.
    endpoint: []const u8 = "",
    probe_state: ProbeState = .unknown,
};
