# 0005 — Deterministic seeded simulation

## Context

A tactics game with random resolution has a save-scumming question whether or not it acknowledges
one. If rolls are drawn fresh on reload, the optimal play for a determined player is to reload until
the die cooperates, which quietly converts every percentage in the game into a time cost.

Determinism is also the cheapest engineering leverage available: replays, reproducible bug reports,
and headless batch validation all fall out of the same property.

## Decision

The simulation is fully deterministic from a `master_seed` plus the ordered input log.

- **No `randi()`, `randf()`, or `randomize()` anywhere in `sim/`.** Not once.
- All randomness comes from named `RandomNumberGenerator` streams seeded from `master_seed` mixed
  with a stream constant: `TERRAIN`, `COMBAT`, `AI`, `CRITS`. Separate streams mean adding an AI
  call never shifts combat rolls.
- `Rng.substream(seed, stream, tag)` gives the same guarantee one level down. Every terrain
  generation stage takes its own tagged substream, so inserting a stage never reshuffles the noise
  of the stages after it.
- The combat stream advances **per resolved action**, never per frame.
- Seeding uses a splitmix64 finalizer over an FNV-1a hash of the tag. `String.hash()` is not used —
  it is not guaranteed stable across engine versions.

## Consequences

- **Save scumming changes rather than disappears.** Reloading and repeating the *same* shot gives
  the same result. Reloading and doing something *different* gives a different result. You keep the
  ability to undo a bad plan; you lose the ability to reroll a bad die. This is XCOM 2's approach
  and it is the better version of the mechanic.
- Replays are free: seed plus input log reconstructs the match.
- A bug report is a seed and a log, not a save file and a description.
- Headless batch runs can generate and score twenty maps, or play a thousand AI turns, without a
  renderer.
- The cost is discipline. Any per-frame or per-render randomness leaking into `sim/` breaks the
  contract silently — the game still runs, it just stops being reconstructible. The test
  `tests/test_rng.gd` guards the load-bearing property directly: drawing extra values from the AI
  stream must leave the COMBAT sequence bit-identical.
- Bit-identical float behaviour across engine versions and CPUs is **not** guaranteed, so map
  generation may shift under a Godot upgrade. See 0010.
