# Rendering

Screens render into a caller-supplied writer through `tuiz`; only `tty.zig`
writes to the terminal.

- `testdata/dashboard.golden` pins the dashboard bytes across terminal sizes and
  states. After an intended visual change, run `zig build update-golden`, read
  `git diff` on the snapshot, and commit it with the change. Never regenerate it
  to silence a failure you have not explained.
- The viewport sweep in `dashboard.zig` asserts that no frame overflows its
  terminal. `zig build test` samples its cases; run `-Dexhaustive` (or
  `zig build ci`) after layout changes.
- Check narrow and wide layouts, and wide (CJK) text: widths are measured in
  cells, not bytes or code points.
- Device-supplied or engine-supplied text is untrusted: sanitize it before it
  reaches the terminal.
- Fixtures and snapshots use synthetic device names, IDs, paths, and numbers.
  Artwork is deferred; use the synthetic marks in `test_marks.zig`.
