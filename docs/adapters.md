# Engine Adapters

An adapter manifest describes how to invoke an executable and interpret its output.
It is a constrained TOML file, not a dynamically loaded plugin. The executable is
supplied separately. See the [built-in manifests](../tools/zzzbench/engines/) for examples.

The current CLI compares a zzz baseline with one or more `--vs` adapters. A manifest
can be inspected without any runtime installed; running a comparison also requires
a model, a zzz baseline executable, and a supplied probe with generic execution enabled.

## Discovery and Overrides

Manifests are loaded in this order; a later file with the same `id` replaces the
whole earlier manifest:

1. Built-ins: `zzz`, `llamacpp`, and `llamacpp-depth`.
2. `$XDG_CONFIG_HOME/zzzbench/engines/`, or `~/.config/zzzbench/engines/` when
   `XDG_CONFIG_HOME` is unset.
3. Each `--engine-dir DIR`, in command-line order.

Within a directory, `.toml` files load in filename order. A missing default config
directory is allowed; an explicit `--engine-dir` must exist. Unknown fields,
duplicate fields, and invalid manifests fail with source and field diagnostics.
An override must be a complete manifest, not a partial configuration patch.

```sh
zig build zzzbench -Doptimize=ReleaseFast -- engines
zig build zzzbench -Doptimize=ReleaseFast -- engines --json --engine-dir /absolute/path/to/adapters
```

The `host` and `android` fields in the listing mean a binary path was declared.
They do not certify that the executable exists, is compatible, or has been tested.

## A JSON-Output Adapter

Save this as `example-json.toml` in an adapter directory. Replace the executable
path and arguments with the command your benchmark actually supports:

```toml
schema = 1
id = "example-json"
label = "Example JSON engine"
parser = "json-object"
fidelity = "summary"
bin.host = "/absolute/path/to/example-bench"
argv = [
  "{bin}", "--model", "{model}", "--threads", "{threads}",
  "--prompt-tokens", "{n_prompt}", "--generate-tokens", "{n_generate}",
]
metrics.prefill = "prompt_tokens_per_second"
metrics.decode = "generated_tokens_per_second"
```

The program must exit successfully and write one JSON object to stdout, for example:

```json
{"prompt_tokens_per_second":120.0,"generated_tokens_per_second":30.0}
```

These are illustrative values, not a performance claim. Send diagnostics to stderr.
Both metric mappings are required in the manifest. They name top-level keys, not
JSON paths. The output may omit a metric; at least one mapped metric must be present.
Present values must be finite positive numbers or numeric strings; zero, negative,
null, and malformed values are rejected.

After configuring your adapter and supplying the required binaries, a host
comparison looks like this (start the probe in a separate terminal):

```sh
/absolute/path/to/zzzprobe tcp:17879 --allow-exec
```

```sh
zig build zzzbench -Doptimize=ReleaseFast -- compare tcp:17879 \
  --engine-bin /absolute/path/to/zzz --model /absolute/path/to/model.gguf \
  --engine-dir /absolute/path/to/adapters --vs example-json --reps 3
```

This command runs both zzz and `example-json`; it does not install either executable.

## Fields and Templates

Use flat assignments, double-quoted strings, string arrays, inline environment
maps, and `#` comments as shown in the built-ins. The parser does not implement
arbitrary TOML tables or every TOML feature.

| Field | Meaning |
|---|---|
| `schema` | Required integer `1` |
| `id` | Required ID: `[a-z0-9][a-z0-9_-]*`, at most 32 bytes |
| `label` | Required display label, 1–64 bytes |
| `parser`, `fidelity` | Required pair from the table below |
| `bin.host`, `bin.android` | At least one required; path on the execution host or Android device |
| `argv` | Required argument array; its first entry must be exactly `"{bin}"` |
| `argv_prompt` | Appended when explicit prompt text is requested |
| `argv_kernel` | Appended when a non-`auto` kernel selection is requested |
| `env.host`, `env.android` | Optional maps, such as `{ LD_LIBRARY_PATH = "/device/lib" }` |
| `metrics.prefill`, `metrics.decode` | Required top-level field names for `json-object` |

Argument and environment templates accept `{bin}`, `{model}`, `{threads}`,
`{n_prompt}`, `{n_generate}`, `{prompt}`, `{kernel}`, and `{workspace}`.
Binary paths accept only the `{workspace}` placeholder. Host binary paths also
expand a leading `~/`; Android paths do not. Prefer absolute executable paths.
Each argument stays one argument, including spaces: there is no shell expansion
of pipes, redirection, `$VARIABLE`, or wildcards. Only use adapters whose commands
you intend to execute; a manifest is configuration, not a sandbox.

An explicit prompt or non-default kernel option fails if the corresponding
optional argument array is absent. Add these arrays only when the executable
supports those controls. Manifests are limited to 64 KiB; resolved commands to
32 arguments, 16 environment entries, and 8 KiB including framing overhead.

## Supported Output Formats

| Parser | Fidelity | Output |
|---|---|---|
| `zzz-binary` | `streaming` | Binary engine reports, including a terminal report; progress can update the screen |
| `llama-bench-json` | `summary` | JSON array of rows using `n_prompt`, `n_gen`, and `avg_ts` |
| `json-object` | `summary` | One object with manifest-selected metric keys |

For llama-bench, rows are matched to the requested token counts. A prompt row has
`n_gen = 0`; a generation row has `n_prompt = 0`. Rows with unrelated workloads
are ignored. A valid sample may have only one of the two metrics. Process failure,
cancellation, and malformed or missing results must not be aggregated as success.

The coordinator owns repetitions and an external warmup round. Configure each
executable invocation as one sample; avoid adding an independent repetition loop
inside a wrapper. Adapter-specific warmups can also exist, as in the zzz manifest;
record their meaning when comparing runtimes.

## Measurement Compatibility and Testing

Prompt processing measures work over the input tokens; generation measures the
subsequent output tokens. Rates with different starting contexts or timing
boundaries are not interchangeable. The `llamacpp` manifest starts its prompt and
generation tests from an empty context. `llamacpp-depth` adds the requested input
length to the starting context, making its generation workload closer to zzz's
post-prompt generation; its prompt-processing workload also changes.

Document tokenization, context depth, warmup behavior, threads, and what time the
executable includes in its rate. The shared comparison policy cannot infer those
semantics from a field called tokens-per-second.

When adding a parser, place synthetic output under `tools/zzzbench/testdata/` and test
incremental input, invalid output, and nonzero exits in `engine_parser.zig`. Use the
fake transport in `comparison.zig` to check integration without a real engine.
Run the [contributor checks](../CONTRIBUTING.md#testing). New runtime formats
may need an external wrapper that emits a supported schema, or a compiled parser.
