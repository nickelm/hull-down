# Journal

Newest first. One entry per session: what changed, what is next.

---

## 2026-08-08 — Iteration 1 revisions from the first playtest

**Changed.** Ten pieces of feedback, all addressed. **212 tests pass.** Three decision records:
0011 roads as a link layer, 0012 turn cycling pulled into iteration 1, 0013 how dramatic the
terrain can be.

**The build allowed exactly one move.** No turn structure, one unit, and `UnitState.begin_turn()`
had never been called by anything. `sim/match_state.gd` now owns the unit list, the turn number,
the active side and the selection; `sim/units/deployment.gd` puts two units a side into their
zones with no RNG. Tab cycles, Prev/Next/End Turn are the HUD's first buttons, and `end_turn`
skips sides with no units so the loop cannot stall. Selection lives in `MatchState` rather than in
`PlayerController`, which had been carrying a `_selected: bool` that nothing read — which is what
happens when state has no owner.

**Three road bugs with one cause.** `road_entry`/`road_exit` — one byte each — cannot describe a
crossing, and `roads.count` is 2. Where the two roads met, the second overwrote both bytes and
orphaned the first road's arms; the mesh builder skipped any tile with an unfilled slot. That is
all three reported symptoms at once: tiles with no geometry, arcs with gaps, turns that render
half a corner. `MapData.road_links` is now an 8-bit mask OR-ed across every road.

Two further defects came out of the rewrite:

*The ribbon was extruded per quad.* Each sample computed its own perpendicular, so consecutive
quads did not share corner vertices and every joint left a wedge notch — an eight-sample arc read
as eight separate chunks. It now carries a mitred cross-section along the polyline.

*The seam was 15 cm off, and the reasoning that said it could not be was wrong.* The endpoint
tangent of a quadratic Bezier whose control point is the tile centre **is** exactly the edge
normal, so it looked like the cross-section would land on the tile boundary for free. But the
ribbon is built from *chords*, and the chord to the first sample has already begun to curve toward
the far edge — about nine degrees at eight samples. The straight tile next door put its vertices
exactly on the boundary and the turn tile did not. Endpoint normals are now forced to the edge
axis, and `test_the_ribbon_meets_exactly_at_a_shared_edge` checks it. Worth remembering that the
derivative being right says nothing about the chord.

Also: `_edge_midpoint` averaged the two tiles' levels, which put the ribbon half a quantum *inside*
the higher tile, so the road sank into the ground on the uphill side of every terrace. `max` is
equally symmetric and rides over the step.

**Roads stopped being a terrain type.** `terrain[i] = Type.ROAD` destroyed the ground underneath,
which is why the road rendered grey on grey. The tile keeps its natural type and `road_links != 0`
overrides the going and clears the cover in `apply_terrain_attributes` — so a road through woods is
a road through woods, and a bridge is drivable because of the override rather than because the tile
was retyped. `MapCodec` to version 2; stale caches regenerate on the version check.

**Overlays are region outlines now, not tints.** A flat tint recolours the terrain, so light blue
read as water and competed with the thing it was annotating. The shader detects a region border
from four neighbour texels and the fragment's distance to that tile edge, and draws an emissive
line — `fwidth` on a world-space metre quantity keeps it one pixel wide at any camera distance.
Movement is amber, exposed red, hull-down green. Roads moved off `StandardMaterial3D` onto the
terrain shader at the same time; on their own material they had been a grey hole down the middle of
every movement region.

**Terrain: the hypothesis was wrong and the measurement was worth more than the idea.** The plan
was that repose decouples drama from drivability — lower the angle of repose and the same relief
arrives as taller hills with climbable flanks. It does not. **Impassability is itself an angle**: a
2.5 m step over a 10 m tile is 14°, and an angle does not care what scale it is measured at. Every
repose the config permits is above 14°. Measured at relief 70 over three seeds, dropping repose
from 34° to 18° moved escarpment by under one point and cost twenty to fifty times the thermal
passes — at shipping size, 471 seconds against one. The first full-scale experiment (relief 120,
repose 22°, six octaves) came out at **30.8% impassable edges** against a 3–15% band.

A second wrong belief went with it. "50 m over 2 km is 0.25 m per tile, under one quantum, so the
map is one flat terrace" confuses the *mean gradient across the map* with the *local* tile-to-tile
step. Terrain is ridged, not a ramp: the 50 m map measures 1.82 quanta per edge, nearly a metre.
`MapMetrics.relief_variety` reports that number now — reported, not gated, because the §4.11 targets
already fail on every seed.

Relief is **65 m**, which is the most the escarpment band allows: 10.7–14.3% across four seeds with
every road inside its gradient limit. 80 m puts all four over the ceiling and breaks the road limit.
The honest summary is that the ground gained about 18% in span and 15% in local step, and going
further means moving 0009's band — a decision about what kind of battlefield this is, not a tuning
knob.

**The test pipeline had not been measuring the shipping map.** `Params.small` shrinks the world and
keeps the cell and tile sizes, and its docstring gives the reason: stretching tiles instead would
quadruple every drop, so "tests would be running against terrain the game never produces". Right
principle, one axis. `target_relief_m` was still applied whole to a quarter-size world — four times
the gradient, **37% impassable edges where the shipping map measures 12%** — and that, not the road
rewrite, is what failed the road-gradient test. Relief now scales with the world's span, so what
holds constant across sizes is the gradient.

One more trap worth recording: a reduced-droplet tuning run reads three to five points pessimistic
on escarpment, because hydraulic erosion is what smooths the fine detail steep tile edges are made
of. The first pass settled on 60 m from `--hf-size 400` numbers and left real headroom unused.

**Smaller things.** Trees and buildings exist (`ScatterBuilder`, one `MultiMesh` per terrain chunk,
12k instances, shadows off) and are sized from `blocker_h` rather than a literal, so what the player
sees is the cover LOS asserts. The camera opens on the first unit at 130 m instead of 420 m and
eases to the selection rather than snapping. `window/stretch/mode` is `disabled`, which is right for
a 3D game and also fixes a latent picking bug — `TilePicker` feeds raw event positions into
`project_ray_origin`, and under a scaled canvas those are different spaces. `TilePicker.pick_ray`
had been rescanning all 40 000 tiles for the map's maximum height on every mouse-motion event.

Two Godot facts that cost time: HUD buttons must set `focus_mode = FOCUS_NONE` or the GUI eats Tab
as `ui_focus_next` before `_unhandled_input` ever sees it, and `set_anchors_preset` followed by
setting `position` leaves the offsets describing a zero-size box — `set_anchors_and_offsets_preset`
with `PRESET_MODE_MINSIZE`, applied after the children have their minimum sizes, is the one that
works.

**Next.** The §4.11 targets are still unresolved and the seeds still cannot be pinned; sightlines
remain woods-limited at ~70 m against a 300–900 m target, and that is a question about woods density
rather than about terrain. Whether the escarpment band should move is the other open decision, and
it now has numbers attached.

---

## 2026-08-07 — Mesh, camera, pathfinding, visibility, §4.9 to §4.14

**Changed.** Everything in Iteration 1 is now implemented. **175 tests pass.**

- **§4.9 / §4.10.** Terraced flat-shaded `ArrayMesh` in 25 chunks, per-water-tile surfaces, Bezier
  road ribbon, free-flying camera, HUD, and the overlay texture. `tools/screenshot.gd` renders
  fixed viewpoints so a visual check is one command.
- **§4.12.** `TankPathfinder` over (tile × facing), `DialQueue`, `PathResult`, `UnitState`, tile
  picking, orders, path preview.
- **§4.13 / §4.14.** `Los` (exact single-pair) and `VisionField` (radial sweep, all three exposure
  states from one traversal), the exposure overlay, and the gunner camera mounted at exactly the
  height the LOS rules use.
- **§4.11.** Metrics, vertex min-cut, `tools/map_metrics.gd`, `tools/gen_batch.gd`.

**Three bugs worth keeping.**

*The map rendered as floating wall strips with sky between them.* Tile tops were wound against
Godot's front-face convention and were all being culled — while the walls looked fine, because
they were being seen from the inside through the holes the missing tops left. It looked like
missing vertex colours, then a broken shader, then water drawn over the ground. `_quad` now does
the flip in one place and `test_faces_are_wound_to_face_outward` checks every triangle's winding
against its own normal.

*`DialQueue` silently lost half the search.* The buckets were an intrusive linked list keyed by the
value, so re-pushing a state — which lazy deletion does constantly — overwrote its `next` pointer
and orphaned everything behind it in that bucket. Symptom: "no route across open ground". A node
pool fixes it and allows the duplicates the algorithm needs.

*Edmonds–Karp never returned.* The `add_edge` helper was a lambda, and GDScript closures capture by
value, so every one of 360k appends copied the whole graph. The same copy-on-write trap as the
`Packed*Array` note in CLAUDE.md, wearing a different hat.

The movement overlay came in at 72 ms against a 50 ms budget until the per-edge `can_move` →
`neighbour` → `transition` call chain was replaced with a precomputed edge table. It is asserted at
the shipping map size now, on open ground, which is the worst case.

**Outstanding: the §4.11 metric targets are not met by any seed.** Twelve maps, zero passes, and
the failures are systematic rather than scattered — which is the signature of a wrong target, not a
wrong generator:

| metric | measured (12 seeds) | target |
|---|---|---|
| sightline median | 71–90 m | 300–900 m |
| hull-down | 24–36% | ≥ 5% |
| chokepoints | 19–41 | 2–6 |
| zone imbalance | 18–76% | ≤ 15% |
| escarpment edges | 7–13% | 3–15% |

Only escarpment and hull-down land where they should. The other three need a decision rather than a
tweak, and the numbers say what the decision is about:

- **Sightlines are woods-limited.** Woods stand 8 m and cover ~17% of the map, so a ray meets one
  within six tiles on average — 70 m is almost exactly `1 / 0.17` tiles. Reaching a 300 m median
  needs woods nearer 3%, which is a different kind of map. Either the target describes more open
  country than this generator makes, or woods should be sparser.
- **Chokepoints cannot be 2–6 on an open map.** A vertex min-cut between two edges of a 95%
  drivable 200-tile map is tens of tiles wide; 2–6 means a canyon. The metric is now measurable
  (the cap was raised from 8, which was reporting every map as "9"), and a fraction-of-width target
  would be scale-free and achievable.
- **Zone imbalance is noisy at zone scale.** Now measured over each zone's own footprint, per the
  spec, rather than over map halves — but a zone is only ~800 tiles and its hull-down fraction
  swings widely. Placement also picks the flattest window on each edge independently, so nothing
  balances the two against each other.

I have not retuned the bands to make them pass. Choosing between "the generator should make more
open, more funnelled maps" and "the targets describe a different game" is a design decision, and it
wants a decision record.

**Next.** Resolve those three targets, then pin the five regression seeds — which cannot happen
until a seed can pass.

---

## 2026-08-07 — Gameplay grid and roads, §4.6 to §4.8

**Changed.** The map pipeline is complete end to end: relief through roads and villages produces a
connected, playable 200×200 grid. 129 tests green.

`MapData`, `Quantizer`, `ConnectivityRepair`, `TerrainTyper`, `MapCodec`, `RoadBuilder`,
`SettlementPlacer`, plus `IntHeap` and `GridAStar`.

**The tuning was the work, not the code.** The first assembled map came out with **50% of tile
edges impassable** — a maze of cliffs with corridors through it. Three separate causes, and the
first two guesses were both wrong:

- Cutting octave count did almost nothing. Neither did the angle of repose, much.
- The actual lever is **total relief**. A 2 m drop across a 10 m tile is impassable, so anything
  over ~11° is a wall, and 220 m of relief over 2 km puts most of the map above that. Now 50 m,
  which gives 7% impassable edges — inside the 3–15% band decision 0009 asked for. It is also
  plenty: a turret sits 2.6 m up, so a 3 m fold is already a hull-down position.
- Woods came out at **0.2% of the map** because moisture was normalized against `log(n)`, which
  puts almost every tile below 0.1. Moisture is now a percentile, re-ranked *after* downsampling —
  ranking before it made the thresholds depend on the downsample ratio, so "the wetter 38%" meant
  the wetter 2% at the shipping resolution.

Bugs worth remembering, all found by tests rather than by looking:

- **Connectivity repair levelled its route backwards**, adjusting each tile against a neighbour not
  yet final, so the next step undid the edge just fixed. Sixty-five edges cut, map still
  disconnected. Forward levelling fixed it, and the same shape of bug turned up again in the road
  earthworks and once more in rounding.
- **Repair checked one representative tile per deployment zone.** A zone is 40×20 tiles of real
  terrain and is routinely split across components; it reported success on maps where two thirds of
  the zone could reach nothing. It now checks zones whole and disowns tiles it cannot connect.
- **`Params.small` stretched tiles to 40 m** instead of shrinking the world. That quadruples every
  tile-to-tile drop, so the test pipeline was running against fragmented terrain the game never
  produces. It now shrinks the map and keeps cell and tile sizes exactly as they ship.
- Objective separation was an absolute tile count, unsatisfiable on a small map, and the fallback
  abandoned the constraint entirely and stacked all three objectives on adjacent tiles. Zone and
  separation dimensions are fractions of the map now.

**Next.** §4.9 and §4.10: the terraced flat-shaded mesh, the water and road surfaces, the palette,
and the free-flying camera. First work that needs the editor rather than the test runner.

---

## 2026-08-07 — Terrain pipeline, §4.1 to §4.5

**Changed.** The continuous half of map generation is complete and green: 80 tests,
`TESTS_COMPLETE`, exit 0.

- **§4.1 skeleton.** `Rng` (splitmix64 seeding, four streams, tagged substreams), `Grid`,
  `Config`, and the headless runner. Three engine facts cost time and are now in `CLAUDE.md`: a new
  `class_name` is invisible until `--import` rebuilds the class cache; `PackedInt32Array` is not a
  constant expression, so the direction tables are `static var`; and a script that fails to parse
  still returns a `GDScript` from `load()`, so calling `new()` on it hangs a `SceneTree` tool with
  no output.
- **§4.2 base relief.** Hand-rolled ridged multifractal over `FRACTAL_NONE` samplers — Godot's
  `FRACTAL_RIDGED` lacks the per-octave weighting and produces exactly the isotropic lumps the
  check rejects. Directionality is imposed, not sampled: a per-map strike angle, coordinates
  compressed along it, plus elongated tectonic uplift bands. 1 s at 800².
- **§4.3 hydraulic erosion.** Mass drift 0.000%. The constants shipped in the plan were sized for a
  normalized 0..1 heightfield; against metres they let a single droplet level its entire step,
  which dug pits, trapped the next droplet, and stippled the uplands. Rescaled with a note in
  `rules.json` explaining the dimensionality. 40 s for 500k droplets.
- **§4.4 thermal erosion.** Converges to the angle of repose exactly. Full sweeps were too slow and
  a 400-pass cap was not enough — talus propagates one cell per pass, so a tall scarp needs passes
  proportional to how far the collapse travels. The active list makes settled ground free, so 715
  passes now cost what 400 did.
- **§4.5 hydrology.** Depression fill (priority-flood, intrusive-linked-list bucket queue), D8, Kahn
  accumulation, carving, fords. Two bugs worth recording. The carve expressed its cross-section as
  an absolute bed elevation plus a parabola, which on a steep valley wall sliced the wall down to
  the channel's own height and left a 23 m cliff at the edge of the carve radius; cutting a depth
  *relative to the local surface* fixed it (max step 23.04 → 5.40 m). And ford easing raises the
  bed after the monotonicity pass had run, so every ford broke the "rivers run downhill" check —
  the levelling pass is now a separate function called twice.

Also removed a piece of theatre: fords were gated on being naturally shallow, and rivers are carved
metres deep by construction, so that gate accepted nothing on every seed and the "fallback" repair
path was the only path that ever ran. The code now says what it does — pick the best crossings, ease
the ones that need it.

**Next.** §4.6: downsample 800→200 by area averaging, quantize to 0.5 m integer levels, classify
transitions, place zones and objectives, repair connectivity, and add `MapCodec` so the later stages
stop paying the full generation cost.

---

## 2026-08-06 — Bootstrap

**Changed.** Repository initialized from `docs/hull-down-v1.md`. Godot project created (4.7.1),
`.gitignore`, `README.md`, `CLAUDE.md` with the directory contract, the determinism contract, the
GDScript conventions, and the copy-on-write gotcha that `Packed*Array` is a value type.

Ten decision records written: the seven called for in §3, plus three covering resolutions to
ambiguities found while planning —

- **0008** facing in the pathfinding state (the spec did not say whether turning in place is legal;
  it is, and the branching factor that follows is what makes the 50 ms overlay target reachable).
- **0009** operational definitions for the map metrics. Three of the four metrics as written either
  measured the wrong thing or cost minutes per map. The sightline metric in particular: sampling
  random tile *pairs* on a 2 km square reports the geometry of the square (median separation about
  1030 m), not the terrain. Both are now computed; the ray-march version is the gate. Also added an
  escarpment-edge-fraction metric, because without it the angle-of-repose cap could silently leave
  the connectivity-repair path as dead code.
- **0010** pinned seeds and the limits of float determinism. Seeds and their metrics are committed;
  map binaries are not. A Godot upgrade can invalidate the pinned maps, and the mitigation is
  procedural rather than a test that fails on upgrade day.

`docs/design/rules.md` written, with movement, LOS, and exposure filled in and the combat sections
stubbed for iteration 2. `data/rules.json`, `terrain.json`, `units.json`, `pinned_seeds.json`
created — every tunable number in the project now has a home outside code.

**Next.** §4.1 skeleton: `sim/rng.gd` with named streams, `sim/grid.gd`, `sim/config.gd`, and the
headless test runner. Acceptance check is the runner reporting zero tests and exiting clean.
