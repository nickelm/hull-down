# 0001 — Godot 4 and desktop only

## Context

Hull Down needs dozens of units per side on a 2 km battlefield, a procedural terrain pipeline that
runs for minutes, and a headless mode for batch map validation and reproducible bug reports. The
engine choice constrains all three.

A browser build was considered and rejected. It would cap the terrain pipeline at whatever runs in
a single-threaded WASM heap inside a tab's memory budget, force the 800x800 erosion pass to be
either cut down or moved off the main thread with a streaming protocol, and add an export target to
every change for an audience that does not exist yet.

## Decision

Godot 4 (developing against 4.7.1-stable), GDScript, desktop only. No browser export target, now or
in iteration 1. No C# and no GDExtension until a measured hot loop demands it.

GDScript is the default because the whole codebase stays in one language, headless script entry
points are a first-class engine feature (`--headless --script`), and the parts that are genuinely
too slow are identifiable and small.

## Consequences

- `godot --headless --script res://tools/*.gd` is the batch and test harness. No external runner.
- Interpreted GDScript is roughly two orders of magnitude slower than C for tight numeric loops.
  The erosion, pathfinding, and LOS inner loops therefore have to be written against that budget —
  `Packed*Array`, monolithic functions, no `Callable` — and that constraint is documented in
  `CLAUDE.md` rather than discovered per site.
- If a loop is measured to be unacceptable after those techniques are exhausted, the escape hatch
  is a GDExtension for that one function, not a language rewrite. Nothing in the architecture
  assumes GDScript; `sim/` is plain data transformation over flat arrays and ports cleanly.
- No mobile or console assumptions in input handling. Mouse and keyboard only.
