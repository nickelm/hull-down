# 0010 — Pinned seeds, and the limits of float determinism

## Context

0005 makes the simulation deterministic from `master_seed` plus the input log, and 0006 pins five
named seeds as regression maps. Both rest on an assumption worth stating explicitly, because it is
only partly true.

Determinism *within a build* is guaranteed by the seeded RNG streams. Determinism *across builds*
is not. The terrain pipeline runs millions of float operations through `FastNoiseLite` and hand-
written erosion loops; IEEE float behaviour, library implementation details, and compiler
vectorisation are not contractually stable across Godot point releases or across CPUs. A seed that
produces Ridge today may produce something else after an engine upgrade.

## Decision

`data/pinned_seeds.json` records the seed **and the metrics measured when it was pinned**, plus the
engine version that measured them. Map binaries are not committed.

`tests/test_determinism.gd` verifies the property that is actually guaranteed: generating the same
seed twice **in the same process** yields an identical content hash. It does not compare against a
stored hash from a previous build.

Metric drift on the pinned seeds is detected by re-running `tools/map_metrics.gd` against
`pinned_seeds.json` and diffing, which is a deliberate act rather than a test that fails on
upgrade day.

## Consequences

- The repository stays small and the pinned seeds stay human-readable. A seed and a metrics row
  say what a map is; a megabyte of binary does not.
- **A Godot upgrade can silently invalidate the five pinned maps.** They will still generate, still
  be playable, and may no longer match their recorded metrics or their names. This is accepted. The
  mitigation is procedural: after any engine upgrade, re-run the metrics against
  `pinned_seeds.json`, and if a seed has drifted out of band, re-pin from a fresh batch and note it
  in `docs/journal.md`.
- Tests that need a specific terrain feature build a synthetic map (`tests/fixtures/synth.gd`)
  rather than depending on a generated seed. A test that says "on seed 4471, tile 12,880 is hull
  down" is a test that will break for reasons unrelated to the code it covers.
- If cross-build stability later becomes genuinely necessary — for multiplayer, or for shared
  replays — the answer is to commit map artifacts and version the map format, not to try to make
  float generation reproducible. That would be a new decision superseding this one.
