#!/bin/sh
# Public test fixture: no engine source or model needed.
case "$1" in
  # @TARGET@ is replaced with the test binary's own target when written.
  bench-info) printf '%s\n' '{"engine":"zzz","benchmark_protocol":1,"command":"bench-run","backend":"cpu","target":"@TARGET@"}' ;;
  bench-run) exit 0 ;;
  *) exit 2 ;;
esac
