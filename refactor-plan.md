# Refactor plan — ssh_socks_tunnel

**Settings:** `keepPublicApi=false` (but CLI surface kept stable in practice) ·
git per-round commits · Strategy A (layer-per-round, ascending) · budget: to
diminishing returns.

**Baseline:** 429 lines, 21 funcs, 1 class, 43 comments · 37 tests green · no
unused imports.

**Test command:** `bash tests/run_all.sh` (37 assertions across 7 files).

## Smells found (Phase 1)

| # | Smell | Layer | API? | Est Δ |
|---|-------|-------|------|-------|
| S1 | `lambda a: _cmd_run(a)` redundant wrapper | 1 | no | -1 |
| S2 | `getattr(a, "ssh_config", None)` — attr always present (×2) | 2 | no | ~0 |
| S3 | `CONN_ARG_SPECS` duplicates the 12 connection-arg declarations in `add_connection_args`; a new arg must be added in two places or the systemd unit silently omits it (no test catches it) | 4/6 | no (CLI identical) | -10, removes drift |
| S4 | `Supervisor.run()` ~67 lines mixing launch / poll-stop / retry accounting | 7 | no | +few (navigability) |

## Deferred (with reason)

- **No formatter run** — project ships no formatter config; imposing black/ruff
  would churn many lines with no mandate. A few >100-char lines in
  `add_connection_args` are a deliberate compact style; left as-is.
- **No file split** — 429 lines is well under the ~800 threshold; a single
  self-contained CLI file is appropriate.
- **Not table-driving `-J/-o/-F`** — those three args are genuinely special
  (store_true / append / different dest); keeping them explicit is clearer than
  forcing them into the uniform table.

## Rounds

- [x] Round 1 — Surface + intra tidy (Layers 1–2): S1, S2
- [x] Round 2 — Connection-arg single source of truth (Layer 4/6): S3
- [x] Round 3 — Decompose `Supervisor.run()` (Layer 7): S4
- [x] Round 4 — Add reconstruct→unit round-trip test (test-only)
- [x] Final — full suite (54 green), metrics, report

**Outcome:** 37 → 54 tests green · CLI/dry-run byte-identical to baseline ·
`run()` −32% · connection-arg drift eliminated. See `refactor-report.md`.
