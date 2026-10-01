# Installation

zzz runs as three executables: the **engine**, a small **probe** that runs it on
the device and streams measurements back, and **zzzbench**, the terminal app you
drive them from.

> **Note**: Runtime downloads and an installer are planned but not available yet.
> Real runs currently need a zzz runtime bundle or separately supplied engine and
> probe binaries. Models are yours to supply.

## Runtime Bundle

A bundle contains everything for a Mac and an Android phone. Run `bin/zzzbench`,
pick a device, and start a benchmark — no environment variables needed. Android
setup finds the bundled binaries, uploads them through adb, and starts the probe.

Keep the directory together when moving it:

```text
bin/zzzbench                         # Mac TUI
bin/zzzprobe                         # Mac probe
bin/zzz                              # Apple Silicon engine
share/zzzbench/v1/aarch64-linux-android/
  zzzprobe                           # Android probe
  baseline/zzz                       # baseline engine, phones without dot product
  i8mm/zzz                           # optional optimized engine
```

Binaries are found relative to the installed `zzzbench`, not the current
directory.

**Android engine selection:**

| Phone CPU | Engine used |
|-----------|-------------|
| Reports `i8mm` and `asimddp` on every core | `i8mm/zzz` |
| Anything else arm64, or CPU info unavailable | `baseline/zzz` |
| `i8mm/zzz` missing from the bundle | `baseline/zzz` |
| Other architectures | Reported as unsupported |

`baseline/zzz` refuses to run on a phone that supports dot product or `i8mm`.
Such a phone needs `i8mm/zzz`; phones with dot product but without `i8mm` are
not supported yet.

## Supplied Binaries

Without a bundle, point zzzbench at each executable.

### Engine

The engine must implement [benchmark contract v1](../BINARY_CONTRACT.md) and be
built for the machine it runs on. Check it first:

```sh
/absolute/path/to/zzz bench-info
```

Then pass it to zzzbench:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- --engine-bin /absolute/path/to/zzz
```

Without `--engine-bin`, zzzbench looks for the host engine in this order:

1. `ZZZBENCH_ENGINE_BIN`
2. A `zzz` beside the installed `zzzbench`
3. `zig-out/bin/zzz` in the current directory

An explicit path never falls back to another binary. An engine built for another
architecture or OS is refused — on Apple Silicon, an `x86_64-macos` engine would
otherwise run under Rosetta and report translated timings as native.

### Probe

A runtime bundle needs one `zzzprobe` binary per platform, alongside the engine.
The Mac probe is found beside `zzzbench` or through `ZZZBENCH_PROBE_BIN`:

```sh
export ZZZBENCH_PROBE_BIN=/absolute/path/to/zzzprobe
```

### Android

Supply **host paths to the Android executables**:

```sh
export ZZZBENCH_ANDROID_PROBE_BIN=/absolute/path/to/android/zzzprobe
export ZZZBENCH_ANDROID_ENGINE_BIN=/absolute/path/to/android/zzz
zig build zzzbench -Doptimize=ReleaseFast -- --platform android
```

zzzbench checks each file's target, stages it through adb, and verifies its
checksum. It never compiles an engine. Explicit paths take precedence over
bundled files, and an invalid override fails instead of falling back. A probe
started by another session is left running; if its port is taken by an
incompatible probe, zzzbench reports it.

## Build zzzbench from Source

Requires [Zig 0.16.0](https://ziglang.org/download/) (pinned in `.zigversion`).

```bash
zig build zzzbench -Doptimize=ReleaseFast                   # build and launch device discovery
zig build zzzbench -Doptimize=ReleaseFast -- engines --json # list adapters, no engine or probe needed
```

To install without launching, use `zig build -Doptimize=ReleaseFast`; the
executable is written to `zig-out/bin/zzzbench`.

The interactive app builds on macOS. Linux runs the test suite. The build never
produces, downloads, or compiles an engine or probe. People running an installed
`zzzbench` don't need Zig.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ZZZBENCH_ENGINE_BIN` | Host engine executable |
| `ZZZBENCH_PROBE_BIN` | Host probe executable |
| `ZZZBENCH_ANDROID_ENGINE_BIN` | Android engine, as a path on this computer |
| `ZZZBENCH_ANDROID_PROBE_BIN` | Android probe, as a path on this computer |
| `ZZZBENCH_RUNS_DIR` | Where comparison receipts are saved |
| `XDG_CONFIG_HOME` | Base for `zzzbench/config.toml` and `zzzbench/engines/` (default `~/.config`) |
| `XDG_STATE_HOME` | Base for `zzzbench/runs/` (default `~/.local/state`) |
| `HOME` | Home directory used for default configuration, state, and cache paths |
| `XDG_CACHE_HOME` | Base for `zzzbench/pushed.json` (default `~/.cache`) |

Next: [Using zzzbench](usage.md).
