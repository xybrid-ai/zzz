# Contributing to zzz

Thank you for your interest in contributing to zzz! This guide will help you get started.

This repository holds zzz's open tooling and public interfaces. The engine and
probe are distributed as binaries, so you can build and test everything here
without them, without a model, and without a connected device.

## Code ownership

This repository is the source of truth for zzzbench, engine adapters, the shared
public interfaces, and their documentation. Submit changes here as pull requests
against `main`.

## Where to start

If you're looking for a first task, browse the [`good first issue`](https://github.com/xybrid-ai/zzz/labels/good%20first%20issue) label — these are scoped to be self-contained, with clear acceptance criteria.

The main areas are:

- **zzzbench** — the terminal app: screens, device setup, comparisons, and reports (`tools/zzzbench/`)
- **Engine adapters** — support for benchmarking other runtimes ([docs/adapters.md](docs/adapters.md))
- **Shared interfaces** — the probe wire format and the engine contract (`shared/`)
- **Documentation** — guides under `docs/`

Medium-difficulty tasks are labeled [`help wanted`](https://github.com/xybrid-ai/zzz/labels/help%20wanted). If you want to claim an issue, leave a comment so we can avoid duplicate work — no formal assignment process is needed.

## Prerequisites

- **Zig** 0.16.0 exactly — the version in `.zigversion`. Download it from
  [ziglang.org](https://ziglang.org/download/) and check with `zig version`.
  The repository tests fail on any other compiler.
- **macOS** to build and run the zzzbench app. Linux runs the full test suite.
- **Git** for version control

No Python, model download, or shader compiler is needed. The first build fetches
the pinned [tuiz](https://github.com/xybrid-ai/tuiz) terminal toolkit.

## Dev Environment Setup

```bash
git clone https://github.com/xybrid-ai/zzz.git
cd zzz
zig build test
```

## Building

```bash
zig build -Doptimize=ReleaseFast           # Install zig-out/bin/zzzbench (macOS)
zig build check                            # Compile everything, run nothing
zig build zzzbench                        # Build, install, and discover devices
```

Two commands work without an engine or probe:

```bash
zig build zzzbench -- engines --json      # List engine adapters
zig build zzzbench -- models --json       # List discovered models
```

Running `zzzbench` with no arguments starts device discovery; a missing probe is
expected in a source-only checkout. For real runs, see the
[Installation guide](docs/installation.md).

## Testing

```bash
zig build test                             # Unit, interface, and repository tests
zig build test -Dtest-filter="receipt"     # Only tests whose names match
zig build test -Dexhaustive                # Include the full rendering sweeps
zig build fmt                              # Format all Zig sources
zig build ci -Doptimize=ReleaseSafe        # Everything CI runs
```

Tests use generated model headers, recorded output, fake transports, and local
sockets. They never need engine or probe binaries, models, devices, or
credentials — keep it that way.

The repository checks also require every configuration key to have an exact
row with a nonempty description in the environment table in
`docs/installation.md`. Tidy recognizes literal reads on `env`, `environ`, and
`environ_map` receivers and qualified standard-library environment APIs, plus
all `ZZZBENCH_` and `XDG_` string keys, including keys passed through constants
or helpers. Keep new keys literal: computed names and other receiver aliases
still require review.

## PR Process

1. **Fork** the repository on GitHub
2. **Create a branch** from `main`:
   ```bash
   git checkout -b your-feature-name
   ```
3. **Make your changes** — keep commits focused and minimal
4. **Ensure quality checks pass:**
   ```bash
   zig build ci -Doptimize=ReleaseSafe
   ```
5. **Push** your branch and open a Pull Request against `main`
6. **Respond to review feedback** — a maintainer will review your PR

Open a draft while you iterate; CI starts when you mark it ready for review.

### PR Guidelines

- Keep PRs focused on a single change
- Include tests for new functionality, and check that a regression test fails without the fix
- Update documentation if behavior changes
- Follow existing code patterns and conventions
- For UI changes, check narrow and wide terminals and include a screenshot
- For adapter changes, describe the executable's output, timing, and workload
- Use synthetic device names, paths, and numbers in fixtures and screenshots

Test results are not performance measurements. Real-device behavior needs its own
evidence when a change affects it.

## Code Style

**Zig:** `zig fmt` formatting and standard library naming (`camelCase` functions,
`snake_case` variables, `PascalCase` types). Tests live next to the code they
cover; register new test files in `tools/zzzbench/tests.zig`.

**Parsers and protocols:** test invalid input and incomplete runs. A failed
process must never become a successful benchmark sample.

**UI:** screens render through `tuiz`. The dashboard snapshot in
`tools/zzzbench/ui/testdata/dashboard.golden` pins the exact output — after an
intended visual change, run `zig build update-golden` and review the diff before
committing it.

## Adding an Engine Adapter

1. **Write a manifest** — a TOML file describing how to run the engine and read
   its output. Start from the [built-in examples](tools/zzzbench/engines/).
2. **Check it loads:**
   ```bash
   zig build zzzbench -- engines --json --engine-dir /absolute/path/to/adapters
   ```
3. **Add a synthetic output sample** under `tools/zzzbench/testdata/` if the
   output format is new, with tests in `engine_parser.zig`.
4. **Run a comparison** against your engine with `--vs your-adapter-id`.

An adapter using an existing output format needs no code. See
[Engine adapters](docs/adapters.md) for the full reference.

## Dependencies

| Area | Manifest |
|------|----------|
| Zig packages | `build.zig.zon` |
| Zig toolchain | `.zigversion` |
| CI actions | `.github/workflows/ci.yml` |

- Prefer the standard library; add a dependency only when it earns its keep.
- Zig dependencies are pinned by URL and content hash. Changes to the terminal
  toolkit belong in [tuiz](https://github.com/xybrid-ai/tuiz); update the pin
  here once the upstream change is available.
- GitHub Actions are pinned by commit SHA.
- Third-party material must keep its notices; record artwork origins in
  [ARTWORK.md](ARTWORK.md) and license text in [NOTICE](NOTICE).

## Getting Help

- **Questions?** Open a [GitHub Issue](https://github.com/xybrid-ai/zzz/issues) or ask on [Discord](https://discord.gg/YhFHHkhbad)
- **Architecture** — the [architecture map](docs/architecture.md) covers the source layout and boundaries

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
