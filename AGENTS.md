# zzz public repository

zzz is the inference-engine product. zzzbench is its open benchmark application,
under `tools/zzzbench/`. Shared public interfaces and utilities live in `shared/`.
The engine and probe are supplied binaries with separate distribution terms.
Do not add engine/probe source imports or compilation to this build.

Use the Zig version pinned in `.zigversion` (0.16.0) and the native Zig build
system. The package is named `zzz`; the current public executable is `zzzbench`.
The terminal toolkit is the pinned `tuiz` dependency.

```sh
zig build fmt                          # format every Zig source
zig build test                         # unit, interface, and repository tests
zig build test -Dtest-filter="name"    # only matching tests
zig build ci -Doptimize=ReleaseSafe    # the full pull-request gate, as CI runs it
zig build -Doptimize=ReleaseFast       # install zig-out/bin/zzzbench (macOS)
```

`check` compiles everything without running it. `update-golden` rewrites the
dashboard snapshot. The interactive app targets macOS; Linux runs portable tests.
Public tests must work without models, device access, engine/probe binaries, or
credentials. Register application tests in `tools/zzzbench/tests.zig`.
`tools/tidy.zig` fails on unreachable Zig files, unregistered tests,
documented build steps that do not exist, and undocumented environment
configuration; fix the cause, not the check. Changes to zzzbench and the public
interfaces start here; see CONTRIBUTING.md.

Only `proto` and `engine_contract` are exported modules. Read
[`shared/AGENTS.md`](shared/AGENTS.md) before changing a shared interface and
[`tools/zzzbench/ui/AGENTS.md`](tools/zzzbench/ui/AGENTS.md) before changing
rendering.

Keep runtime bundle paths and user configuration paths stable when moving source
files. Runtime installation automation and the reusable benchmark library remain
future work; documentation must distinguish planned features from working ones.
zzzbench bundles no in-app logos: keep the catalogue empty and renderer fixtures
synthetic. Before adding any image, record its source, publication rights, and
required notices in ARTWORK.md. Public source licensing does not grant rights to
proprietary runtimes or third-party artwork. Write documentation in the structure
and tone of README.md and CONTRIBUTING.md.
