# Hull Down

Turn-based tank tactics. Dozens of units per side. Steel Panthers scale with XCOM legibility.

Godot 4.7, GDScript, desktop.

## Status

**Iteration 1** — terrain, camera, movement, and visibility. No combat.

A 2 km procedural battlefield generated from a seed: tectonic relief, hydraulic and thermal
erosion, rivers and fords, a 200x200 grid of 10 m tiles quantized to 0.5 m, terrain cover types,
roads with cut and fill, villages. Rendered as a terraced flat-shaded mesh. One tank drives across
it with facing-aware pathfinding, and a visibility overlay shows where a target would be exposed,
hull down, or masked.

See `docs/hull-down-v1.md` for the full plan and `docs/journal.md` for progress.

## Running

Godot is not on PATH here. Set:

```powershell
$GODOT = "C:\Users\nikla\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
```

Then:

```powershell
& $GODOT --path .                                              # play
& $GODOT --headless --path . --script res://tests/run_all.gd   # tests
& $GODOT --headless --path . --script res://tools/generate_map.gd -- --seed 12345 --dump-png
```

## Layout

| | |
|---|---|
| `sim/` | Pure GDScript simulation. RefCounted only, no Node dependencies, headless-runnable. |
| `game/` | Godot nodes: rendering, camera, input, UI. |
| `tools/` | Headless entry points — map generation, metrics, batch runs. |
| `data/` | Every tunable number. |
| `tests/` | Headless test suite. |
| `docs/` | Spec, design rules, decision records, journal. |

`game/` imports `sim/`. `sim/` never imports `game/`. See `CLAUDE.md`.

## Controls

| | |
|---|---|
| `W A S D` | Pan |
| Mouse wheel | Zoom |
| Right-drag | Orbit |
| Edge of screen | Edge scroll |
| Left click | Select tank / order move |
| `V` | Cycle overlay (movement / visibility / off) |
| `G` | Toggle gunner view |
| `F1` | Debug panel |
