# src/spikes — pre-contract implementation spikes (NOT the contract tree)

These were built and simulated BEFORE the contracts-first skeleton plan:
- `common/mac_unit.v` + `tb_mac_unit.v`: folded MAC, iverilog PASS 64 iters
  at W=8 AND W=4 (independent Python-oracle golden in `mac_*.hex`).
- `embed/`: EMBED slice, iverilog EMBED PASS (`ids/wemb/wproj` vectors).

Status: sunset from `rtl/` (folder retired). Kept as implementation
REFERENCE for the later parallel pursuit (leaf-by-leaf implementation of
`src/components`). Excluded from `TestSkeleton` (that suite globs
`src/components/*.v` only). Do not import spikes into the contract tree.
