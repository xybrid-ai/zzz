# The zzz Engine

zzz is an inference engine for tiny devices. zzzbench runs a supplied engine
binary as a separate process on the device you pick and measures it there.
This repository builds zzzbench; engine builds and runtime distribution are
separate work. Runtime downloads are not available yet.

## Engine Targets

| Target | Binary | Notes |
|--------|--------|-------|
| Apple Silicon Mac | `zzz` | Native arm64 |
| Android arm64 | `baseline/zzz` | Phones without dot product |
| Android arm64 | `i8mm/zzz` | Needs `i8mm` and dot product; selected automatically |

An engine refuses to run on a CPU with features it was not built for. A phone
with dot product but without `i8mm` therefore has no working engine yet.

See [Installation](installation.md) for bundles and supplied binaries.

## Check an Engine

A supplied engine must implement [benchmark contract v1](../BINARY_CONTRACT.md).
Ask it to describe itself:

```sh
/absolute/path/to/zzz bench-info
```

It prints one JSON object with its version, build target, CPU features, and the
model architectures it supports. zzzbench runs the same check before using an
engine and refuses one built for a different architecture or OS — a host engine
can't stand in for an Android one, and a translated build would report
misleading timings.

## Run It

```sh
zig build zzzbench -Doptimize=ReleaseFast -- --engine-bin /absolute/path/to/zzz
```

Pick a model and press **`r`**. The engine loads the model and generates; zzzbench
handles device setup, run settings, and the display. See
[zzzbench TUI guide](usage.md) for comparisons with other engines.
