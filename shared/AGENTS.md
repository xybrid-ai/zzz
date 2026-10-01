# Shared interfaces

`proto.zig` (probe wire format) and `engine_contract.zig` (the zzz executable
interface in [BINARY_CONTRACT.md](../BINARY_CONTRACT.md)) are exported modules.
Probes and engines compile against them, so changes must remain compatible with
separately supplied binaries.

- Fixed-size frames are `extern struct`s with comptime `@sizeOf` checks. Changing
  a layout requires bumping that frame's `version`; do not edit a size check to
  make it pass.
- Add fields in reserved or padding bytes, gate new behaviour on a
  `*_min_version` constant compared with `Hello.proto_version`, and let readers
  ignore optional fields they do not understand. Never gate on
  `protocol_version` itself.
- The wire is little-endian and frames are reinterpreted in place. Variable-length
  frames are bounded by `max_frame_bytes`; an over-long length is a desync, never
  an allocation.
- Exported modules must not import the application, `tuiz`, or engine source.
  `tests/consumer/` builds them as another package would, with the toolkit off.
- `net_compat`, `time_compat`, `gguf_metadata`, and `recap_bars` are application
  utilities, not exported interfaces. Export a new module only for a real
  external consumer.
