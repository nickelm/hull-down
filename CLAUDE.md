# Hull Down — working agreement

Turn-based tank tactics. Godot 4.7, GDScript, desktop only. The full Iteration 1 spec is
`docs/hull-down-v1.md`; the combat rules of record are `docs/design/rules.md`.

## Commands

Godot is not on PATH. Use the console build so stdout is captured:

```
$GODOT = "C:\Users\nikla\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
$PROJ  = "c:\Users\nikla\Dropbox\Dev\Hull-Down\hull-down"
```

| Purpose | Command |
|---|---|
| Run the tests | `& $GODOT --headless --path $PROJ --script res://tests/run_all.gd` |
| Run one test file | `... --script res://tests/run_all.gd -- --only test_rng` |
| Generate a map | `... --script res://tools/generate_map.gd -- --seed 12345 --out user://maps/dev.hdmap --dump-png` |
| Measure a map | `... --script res://tools/map_metrics.gd -- --map user://maps/dev.hdmap` |
| Batch generate + measure | `... --script res://tools/gen_batch.gd -- --count 20` |
| Play | `& $GODOT --path $PROJ` |

The test runner prints `TESTS_COMPLETE` as its final line and exits nonzero on failure. A missing
sentinel means a hard runtime error killed the run — treat it as a failure regardless of exit code.

`--dump-png` writes diagnostics to `dumps/` (gitignored).

**After adding a new `class_name`, rebuild the class cache before anything will resolve it:**

```
& $GODOT --headless --path $PROJ --import
```

Without it every reference to the new class fails with a bare `Identifier "X" not declared in the
current scope`, which looks like a typo and is not.

## Engine gotchas that cost time once already

- **`PackedInt32Array` is not a constant expression.** `const DX := PackedInt32Array([...])` will
  not compile. The direction tables in `Grid` are therefore `static var` and must be treated as
  read-only. `const DX: Array[int]` is not an acceptable substitute — it boxes every element as a
  Variant, which is exactly what the hot loops cannot afford.
- **`signal` is a reserved word**, so it cannot name a local. Comes up naturally in the ridged
  multifractal.
- A script that fails to parse still returns a `GDScript` from `load()`, just one where
  `can_instantiate()` is false. Calling `new()` on it aborts the calling function silently — in a
  `SceneTree` tool that means no output and no exit, i.e. an apparent hang. Guard before `new()`.

## Directory contract — hard rule

```
sim/    pure GDScript. RefCounted only. No Node, no scene tree, no rendering, no input.
game/   Godot nodes, rendering, camera, input, UI.
tools/  headless entry points (extends SceneTree).
tests/  headless test suite.
data/   every tunable number.
docs/   spec, design, decision records, journal.
```

**`game/` imports `sim/`. `sim/` never imports `game/`.** Everything in `sim/` must run under
`godot --headless --script`. If a file in `sim/` needs a Node, the design is wrong — move the Node
part to `game/` and pass plain data across.

## Determinism contract

- **No `randi()` / `randf()` / `randomize()` anywhere in `sim/`.** Not once, not "just for this".
- All randomness comes from `Rng.stream(master_seed, Rng.Stream.X)` or
  `Rng.substream(master_seed, Rng.Stream.X, "tag")`, which return a seeded
  `RandomNumberGenerator`.
- Four top-level streams: `TERRAIN`, `COMBAT`, `AI`, `CRITS`. Separate streams mean adding an AI
  call never shifts combat rolls. `substream` gives the same guarantee one level down — every
  terrain generation stage takes its own tagged substream, so inserting a stage never reshuffles
  the ones after it.
- The combat stream advances **per resolved action**, never per frame.
- A match must be reconstructible from `master_seed` plus the ordered input log.
- Iterate `Dictionary` keys in a sorted order, or not at all, in `sim/`. Do not rely on
  `String.hash()` — it is not guaranteed stable across engine versions; use `Rng.fnv1a`.

## GDScript conventions

- **Static typing everywhere.** `func f(a: int) -> float`, `var x: PackedFloat32Array = ...`.
  Untyped declarations are a configured warning.
- **Bulk data is `Packed*Array` with a flat index**, never `Array[Array]` and never `Dictionary`.
  On a 640k-cell field, nested `Array` boxes every element as a 24-byte Variant behind two
  indirections — 3-5x the access cost and ~15 MB instead of 2.5 MB. The erosion stage does
  hundreds of millions of array operations; this is the difference between a minute and five.

- **`Packed*Array` are copy-on-write value types.** This will bite you:

  ```gdscript
  var h := _heights     # NOT a reference
  h[0] = 1.0            # writes to a private copy
  # _heights is unchanged
  ```

  Every hot loop either writes through the member directly, or aliases locally and assigns back
  at the end (`field.data = H`). The same applies to a `PackedInt32Array` stored inside an
  `Array` — you must write the element back after mutating it.

- Hot loops (erosion, pathfinding, LOS) are single monolithic functions: no helper calls, no
  `Callable`, no `Vector2`/`Vector3` allocation, direction offsets from `const PackedInt32Array`.
  Readability loses to the frame budget in exactly these places and nowhere else.
- Prefer `static func` on a `class_name` over singletons. Pass `Config` in explicitly so tests can
  inject a small one.

## Tunables live in `data/`

`data/rules.json`, `data/terrain.json`, `data/units.json`, `data/pinned_seeds.json`.

No magic number in a `.gd` file. If you are about to type a threshold, a cost, a colour, or a
probability into code, it belongs in JSON and is read through `Config`. Structural constants
(grid size, quantum, direction tables) are the exception and live in `Grid` / `MapData`.

## Decision records

Any change to a **rule** or an **architectural boundary** requires a new file in
`docs/decisions/NNNN-title.md` with three sections: context, decision, consequences. Amending an
existing decision means writing a new record that supersedes it, not editing the old one.

Add a dated entry to `docs/journal.md` each session: what changed, what is next.
