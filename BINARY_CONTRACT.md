# zzz Benchmark Executable Contract, Version 1

The TUI and probe execute a supplied program. They never link it or compile it.
The zzz adapter owns the following interface; other adapters keep their own CLI
and output formats. Probe transport versioning is separate from this executable
contract.

## Identity and Capabilities

`zzz bench-info` writes one JSON object to stdout and exits successfully:

```json
{"engine":"zzz","version":"0.1.0","benchmark_protocol":1,"command":"bench-run","backend":"cpu","target":"aarch64-macos-none","cpu":"apple_m1","architectures":["qwen3","llama"],"model_formats":["gguf"],"streaming":true,"token_text":true}
```

The object also includes `dotprod` and `i8mm` booleans describing compiled CPU
features. Target, CPU model and architecture list above are illustrative. Read them from the
actual executable. The binary SHA-256 in host comparison receipts distinguishes
builds with the same product version. The tools reject absent or incompatible
benchmark protocol identities when checking the configured zzz executable, and a
`target` whose architecture or OS differs from the machine the engine will run on
(an `x86_64-macos` engine under Rosetta on Apple Silicon, for example). An engine
whose `bench-info` has not exited within 10 seconds is killed and refused.
The engine's feature guard checks the CPU implementation before benchmark loading.

## One Benchmark Process

```sh
zzz bench-run MODEL --protocol 1 --report-binary \
  --threads 4 --prefill-tokens 16 --decode-tokens 32
```

This command benchmarks CPU inference on macOS and Android. Binary reporting is
required. Defaults are 4 threads, 16 prompt tokens, 32 generated tokens, and
automatic kernel selection. Counts must be positive.
Unknown arguments, a missing `MODEL`, and unsupported protocol versions fail
with a nonzero exit; only an explicit `--help` prints usage and succeeds.

Optional flags:

- `--prefill-warmup`: one untimed prompt-processing pass, followed by cache reset,
  before the measured pass. The zzz comparison adapter enables this option.
- `--prompt TEXT`: tokenize this text instead of the deterministic synthetic input.
- `--emit-text`: emit text frames alongside measurements; requires binary reporting.
- `--kernel auto|sdot|vector|scalar`: select the CPU kernel.

The engine checks architecture support before inference. Weight formats and tensor
layout are checked by the engine loader; capability lists are not a promise that
arbitrary model bytes are valid. Failure writes diagnostics to stderr and returns
nonzero. It never becomes a successful aggregate in the comparison coordinator.

## Output

With `--report-binary`, stdout contains only `EngineReport` and optional
`TokenText` frames defined in `shared/proto.zig`. A compact build banner and
diagnostics go to stderr. `EngineReport.phase` is 0 for prompt processing, 1 for
generation, and 2 for the terminal measurement. Reports carry token rates,
counts, and elapsed time. A successful measurement requires a terminal report
and a successful process exit. No terminal report, cancellation, or nonzero exit
is a failed/incomplete run, regardless of earlier samples.

The separately supplied probe owns process management, raw output forwarding, and optional
process resource measurements. The engine owns inference and token timings. The
comparison coordinator owns repetitions, external warmups, statistics, and receipts.

## Compatibility

zzzbench accepts engines that report benchmark protocol version 1 through
`zzz bench-info`. Use a compatible probe to launch `zzz bench-run` through
`RunSpec`. The probe's generic exec interface can launch other adapter commands.
Protocol compatibility and rejection are tested with synthetic fixtures;
released runtime binaries require separate validation.
