# Architecture

zzz is an inference engine for tiny devices. This repository is its public home:
documentation, public interfaces, and zzzbench, the terminal app that runs and
measures engines directly on devices. The engine and probe are supplied
binaries with separate distribution terms; nothing here builds or links them.

Public components must build and test without them. The app lives in
`tools/zzzbench/`, and the interfaces it shares with the engine and probe live in
`shared/`.

## Repository Layout

```text
zzz/
├── tools/zzzbench/       # Benchmark app, adapters, device setup, terminal screens
├── tools/tidy.zig        # Repository checks run by `zig build test`
├── shared/              # Public interfaces and small utilities
├── tests/consumer/      # Separate package importing the exported modules
├── runtime/             # Distribution status and planned metadata
├── docs/                # Engine usage, installation, contributor guides
├── assets/              # README demo recording
├── build.zig            # Public build entry
├── build_support.zig    # Public module and artifact definitions
├── build.zig.zon        # zzz package; pinned tuiz dependency
├── .zigversion          # Exact contributor and CI toolchain
└── .github/             # Public component checks
```

The package is named `zzz`; its current executable is `zzzbench`. `zig build`
installs that executable, `zig build test` runs public tests, and `zig build ci`
runs everything CI runs. Runtime binaries are supplied separately.

## Execution Paths

```text
CLI or live comparison screen
    -> comparison coordinator (ordering, repetitions, aggregation)
    -> manifest adapter (arguments and output format)
    -> probe client -> supplied probe -> supplied engine executable
    <- output, progress, completion, and process measurements

Ordinary local dashboard run
    -> host runner -> supplied zzz executable
```

A probe is the companion process that runs commands and sends measurements back to
the application. Local comparisons also use this probe transport. The ordinary
local dashboard has a direct engine runner; these are distinct execution paths.

## Source Map

| Location | Responsibility |
|---|---|
| `tools/zzzbench/main.zig`, `cli.zig` | Application setup, command parsing, event loop |
| `tools/zzzbench/comparison.zig` | Comparison plans, ordering, repetitions, statistics, events |
| `tools/zzzbench/engine_manifest.zig`, `engine_registry.zig` | Manifest validation, discovery, overrides |
| `tools/zzzbench/engine_command.zig`, `engine_parser.zig` | Direct argument construction and output interpretation |
| `tools/zzzbench/exec_client.zig`, `wire.zig` | Probe requests, responses, cancellation, connection handling |
| `tools/zzzbench/engine.zig` | Direct host runner and engine progress state |
| `tools/zzzbench/discovery/`, `bundle.zig`, `model_sync.zig` | Device discovery, supplied-binary setup, model transfer |
| `tools/zzzbench/model_catalog.zig`, `shared/gguf_metadata.zig` | Model-file discovery and metadata-only inspection |
| `tools/zzzbench/comparison_receipt.zig`, `comparison_report.zig` | Saved run evidence and reports |
| `tools/zzzbench/ui/` | Terminal screens and application presentation |
| `shared/proto.zig`, `engine_contract.zig` | Probe wire format and zzz executable identity contract |
| `shared/net_compat.zig`, `time_compat.zig` | Platform utilities |
| `tools/zzzbench/tests.zig` | Explicit import root for application tests |
| `tools/zzzbench/update_golden.zig` | Writes the dashboard snapshot for `zig build update-golden` |
| `tools/tidy.zig` | Reachability, test registration, documented build steps |
| `build_support.zig` | Named modules, application and test build steps |

The public [tuiz](https://github.com/xybrid-ai/tuiz) package supplies the reusable
renderer, imported as `tuiz`. Its URL and content hash are pinned in `build.zig.zon`.
Engine and probe implementations remain outside this package and are never linked
into the application. See [BINARY_CONTRACT.md](../BINARY_CONTRACT.md) for the zzz
executable interface; other adapters use their own commands and output formats.

## Current Boundaries

- The comparison coordinator accepts adapters and injectable execution transports.
  The CLI currently selects `zzz` as the baseline; `--vs` adds other adapters.
  Listing or editing adapters needs no zzz executable. Running the current CLI
  comparison does need the baseline executable and a compatible probe.
- The ordinary Run/device-race path remains zzz-specific. A new comparison adapter
  does not automatically change those paths.
- Model discovery reads GGUF metadata. Other model formats and LiteRT integration
  are not implemented.
- A named, supported `zzzbench` library module is not exported yet. Only `proto`
  and `engine_contract` are exported; importing those is different from consuming
  the whole comparison coordinator as a library. The other `shared/` modules are
  application utilities.
- The current application build targets macOS. Linux runs the portable tests;
  Android setup transfers supplied binaries. Runtime download, signing, and
  installation automation are separate work.

Keep measurement policy in the coordinator, command/output translation in the
adapter layer, and rendering in the UI. Avoid adding engine source dependencies to
make an adapter work. Keep source-only tests independent of installed runtimes.
