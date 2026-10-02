# zzzbench TUI Guide

zzzbench runs an engine on a Mac or an Android phone and records what it
measured. On Android it also streams the phone's telemetry while the engine runs.
Set up the engine and probe first — see [Installation](installation.md).

## Launch the TUI

From the source checkout on macOS:

```sh
zig build zzzbench -Doptimize=ReleaseFast
```

This builds, installs, and launches zzzbench. It discovers connected devices and
your Mac, then opens a picker. Use the arrow keys to move, **Space** to toggle a
device, and **Enter** to continue. A single available device is selected
automatically. A missing probe is expected in a source-only checkout; see
[supplied binaries](installation.md#supplied-binaries).

> **Note**: Benchmark with a release build. Plain `zig build zzzbench` makes a
> debug build for development, which adds its own overhead to the Mac you may be
> measuring.

The examples below use the source launcher. With a runtime bundle, replace
`zig build zzzbench -Doptimize=ReleaseFast --` with `bin/zzzbench`; with
zzzbench on your `PATH`, use `zzzbench`. Add `--help` for a summary of the options.

## Pick a Device

Limit discovery to Android phones or your Mac:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- --platform android
zig build zzzbench -Doptimize=ReleaseFast -- --platform host
```

Android discovery requires `adb` on your Mac, USB debugging enabled on the phone,
and authorization of the connected computer. To select a device without the
picker, list its ID and pass it to `--devices`:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- devices --json
zig build zzzbench -Doptimize=ReleaseFast -- --devices DEVICE_ID
```

Only one probe can serve an Android phone at a time. If a probe started from
another workspace holds it, zzzbench shows that probe's process ID and uptime.
In a terminal it asks before stopping it; without one it refuses and prints the
`adb shell kill` command to run. Pass `--replace-probe` to stop it without asking.
Stopping a probe also stops any benchmark it is running.

Use comma-separated IDs for several devices, or `--all` for all available devices
(up to five). An explicit probe endpoint connects directly and skips discovery:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- tcp:17879
```

## Models

zzzbench lists GGUF models from the Hugging Face cache
(`~/.cache/huggingface/hub`), `./fixtures/models`, and directories configured in
`~/.config/zzzbench/config.toml` (or `$XDG_CONFIG_HOME/zzzbench/config.toml`):

```toml
model_dirs = ["/absolute/path/to/models"]
```

```sh
zig build zzzbench -Doptimize=ReleaseFast -- models --json   # list what zzzbench found
```

The catalogue reads GGUF metadata only; the engine decides whether it can load a
model. Known embedding models are marked unavailable in the picker. An architecture in the
engine's capability list does not guarantee every quantization will load.

## Run Parameters

Choose a model from the catalogue and set the workload before opening the TUI:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- --model example-model --threads 4 \
  --n-prompt-tokens 256 --n-generate-tokens 64
```

`--model` accepts a catalogue name or a path to a catalogued GGUF file. Configure
its directory above if it is not in the Hugging Face cache. Device discovery
still runs when you supply model or workload options. Press **`r`** to start;
**`m`** changes the model and **`p`** edits parameters in the dashboard.

To generate text instead of using the synthetic benchmark token sequence:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- --model example-model --prompt "Explain gravity" --show-output
```

Real text changes the prefill workload, so compare runs with the same prompt.

## Dashboard Keys

| Key | Action |
|-----|--------|
| `r` | Run the benchmark; press again to stop a Mac run |
| `m` | Choose a model |
| `p` | Edit run parameters |
| `c` | Compare devices side by side |
| `s` | Sort compared devices by speed |
| `o` | Show or hide generated text (run with `--prompt TEXT`) |
| `e` | Export the screen |
| `q` | Quit |

## Compare Engines

`compare` runs zzz and one or more other engines on the same model through a
probe, then prints the results:

```sh
/absolute/path/to/zzzprobe tcp:17879 --allow-exec
```

```sh
zig build zzzbench -Doptimize=ReleaseFast -- compare tcp:17879 --engine-bin /absolute/path/to/zzz \
  --model /absolute/path/to/model.gguf --vs llamacpp --reps 3
```

zzz is always the baseline. Add more engines with repeated `--vs`. Omit the
`compare` subcommand to watch the comparison in the TUI:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- tcp:17879 --engine-bin /absolute/path/to/zzz \
  --model /absolute/path/to/model.gguf --vs llamacpp --reps 3
```

Both comparison modes connect to an already running probe; they do not perform
device discovery. Model and executable paths must be accessible on the machine
running that probe. Install `llama-bench` separately and configure its path in
an adapter manifest if it differs from the built-in default.

Built-in adapters cover llama.cpp's `llama-bench`. Add your own with manifests
in `~/.config/zzzbench/engines/` (or `$XDG_CONFIG_HOME/zzzbench/engines/`), or
pass `--engine-dir DIR`. List what zzzbench will use:

```sh
zig build zzzbench -Doptimize=ReleaseFast -- engines --json
```

See [Engine adapters](adapters.md) for the manifest format.

> **Note**: The same model file does not mean the same workload. Check prompt
> length, generation length, context depth, warmup, and threads before reading
> a ratio between engines.

## Results

| Output | Location |
|--------|----------|
| Comparison receipts | `$ZZZBENCH_RUNS_DIR`, else `$XDG_STATE_HOME/zzzbench/runs`, else `~/.local/state/zzzbench/runs`, else `./zzzbench-runs` |
| Screen exports | `./exports` |
| Android upload record | `$XDG_CACHE_HOME/zzzbench/pushed.json`, else `~/.cache/zzzbench/pushed.json` |

Each receipt holds the plan, the raw output of every process, the result JSON,
and a `SUMMARY.md`. Receipts can contain local paths, device identifiers, and
configuration; review them before sharing.

The upload record lets later runs check a model's size instead of a full
on-device checksum. Deleting it is safe: the next run verifies by checksum and
skips unchanged uploads.
