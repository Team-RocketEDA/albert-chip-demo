#!/usr/bin/env bash
# Elaboration gate for the wiring-only skeleton tree: proves every
# instantiation resolves and every port connection elaborates.
# No simulation, no implementation — structure only.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IV="${IV:-iverilog}"
"$IV" -tnull -o /dev/null "$ROOT"/src/components/*.v
