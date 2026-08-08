# Hull Down — Iteration 1 Plan

Turn-based tank tactics. Dozens of units per side. Steel Panthers scale with XCOM legibility.

**Iteration 1 delivers terrain, camera, movement, and visibility. No combat.**

---

## 0. Locked decisions

| Question | Decision |
|---|---|
| Engine | Godot 4, GDScript |
| Platform | Desktop only, no browser build |
| Setting | Generic modern armour, no licensed IP |
| Aesthetic | Flat-shaded low-poly, terraced terrain, tight palette (BattleBit reference) |
| Grid | Square, 10 m tiles, 8 facings, Euclidean range |
| Terrain | Heightfield, 0.5 m vertical quantization |
| Camera | Free flying camera above the battlefield |
| Turn structure | Side-alternating, all units activate |
| Actions | Two per unit; shooting or overwatch ends the turn; reload automatic |
| Armour | Penetration versus facing (front/left/right/rear/top). No regenerating armour |
| Hits | Percentage to-hit, then penetration roll. No null results: a non-penetrating hit still shreds or shakes |
| Spotting | Deterministic. LOS plus range threshold, modified by terrain, movement, firing |
| Fog memory | Ghost markers at last known position, decaying over turns |
| Maps | Fully procedural. No hand authoring, ever |
| Objectives | Hold objectives to win |
| Enemy | Numerous, individually weaker units |
| Simulation | Seeded and deterministic |

## 1. Determinism and save scumming

Determinism is a design choice, not just an engineering one, and it changes save scumming rather than removing it.

Rules of the contract:

- No use of Godot's global `randi()` or `randf()` anywhere in `sim/`.
- Named `RandomNumberGenerator` streams, seeded from `master_seed` plus a stream constant: `terrain`, `combat`, `ai`, `crits`. Separate streams mean adding an AI call never shifts combat rolls.
- The combat stream advances per resolved action, not per frame.
- A match is fully reconstructible from `master_seed` plus the ordered input log. This gives you replays, reproducible bug reports, and headless batch runs for free.

Consequence for save scumming: reloading and repeating the *same* shot gives the same result. Reloading and doing something *different* gives a different result. This is XCOM 2's approach. You keep the ability to undo a bad plan; you lose the ability to reroll a bad die. That is the better version of the mechanic.

## 2. Repository layout

```
hull-down/
  CLAUDE.md
  README.md
  project.godot
  sim/                 pure GDScript, RefCounted only, no Node dependencies
    rng.gd
    map/               generation pipeline
    pathfinding/
    visibility/
  game/                Godot nodes, rendering, camera, input, UI
  tools/               headless entry points
    generate_map.gd
    map_metrics.gd
  data/
    units.json
    rules.json
    terrain.json
  docs/
    design/rules.md
    decisions/NNNN-*.md
    journal.md
  tests/
```

**Hard rule, stated in CLAUDE.md: `game/` imports `sim/`. `sim/` never imports `game/`.** Everything in `sim/` must run under `godot --headless --script`.

## 3. Bootstrap documents, written first

**CLAUDE.md** covers: build and run commands; the headless test command; the directory contract above; the determinism contract; GDScript conventions; tunable constants live in `data/`, never inline in code; and the standing instruction that any change to a rule or an architectural boundary requires a new decision record in `docs/decisions/`.

**Decision records to write immediately**, one file each, three sections (context, decision, consequences):

1. Godot 4 and desktop only
2. Square 10 m grid on a quantized heightfield
3. Side-alternating turns with full activation
4. Penetration versus facing, rejecting regenerating armour
5. Deterministic seeded simulation
6. Fully procedural maps validated by tactical metrics
7. Tile-bound roads with cut and fill

**docs/design/rules.md** is the source of truth for combat rules. Iteration 1 fills in only movement, LOS, and exposure.

**docs/journal.md** gets a dated entry per session: what changed, what is next.

## 4. Task order

Each task states its acceptance check. Do not proceed past a failing check.

### 4.1 Skeleton
Project, directory layout, docs, `rng.gd` with named streams, headless test runner.
*Done when:* `godot --headless --script res://tests/run_all.gd` runs and reports zero tests.

### 4.2 Base relief
Low-frequency tectonic layer plus ridged multifractal, domain-warped. Generate at 800x800, 2.5 m spacing (2 km square).
*Done when:* a heightmap PNG dumps to disk and shows directional ridge structure rather than isotropic lumps.

### 4.3 Hydraulic erosion
Droplet erosion, target 500k droplets. Each droplet carries sediment capacity proportional to slope and velocity, erodes on steep ground, deposits on flats.
*Done when:* dendritic valley networks are visible in the dump, and total mass is conserved within a few percent.
*Note:* expect roughly a minute in plain GDScript at this resolution. Accept it behind a progress print. Move to a compute shader only if it becomes annoying.

### 4.4 Thermal erosion
Iterate until no slope exceeds the angle of repose; collapse excess into talus.
*Done when:* the maximum tile-to-tile gradient falls below the configured threshold.

### 4.5 Hydrology
D8 flow direction, flow accumulation. Accumulation above `stream_threshold` becomes a stream, above `river_threshold` a river. Carve channels. Mark fords where channel depth and bank gradient are both low.
*Done when:* rivers run downhill without breaks and at least two fords exist per map.

### 4.6 Quantize and repair
Downsample 800x800 to the 200x200 gameplay grid by area averaging. Quantize to 0.5 m. Classify every tile-to-tile transition:

- `dh <= 1.0 m` passable, normal cost
- `1.0 < dh <= 2.0 m` passable, extra cost, cannot fire the same turn
- `dh > 2.0 m` escarpment, impassable

Then flood fill from each deployment zone and lower selected edges until the map is connected.
*Done when:* every deployment zone reaches every objective, verified by a test.

### 4.7 Cover and concealment
Derive terrain type from flow accumulation (moisture), slope, and elevation: woods, marsh, scrub, open, rock. Each type carries a movement cost and a spotting-range multiplier from `data/terrain.json`.
*Done when:* woods cluster in valleys and lower slopes rather than scattering uniformly.

### 4.8 Roads and settlements
Roads are A* paths over slope cost between map edges, reusing the pathfinding module. Bridges where a road meets a river. Villages at junctions and crossings, fields around villages.

Road representation: one segment per tile, defined by an entry edge and an exit edge, rendered as a quadratic Bezier through the tile centre. Road generation applies cut and fill, smoothing the height profile along the polyline, so roads become the low-gradient route and sometimes the only crossing of an escarpment.
*Done when:* a road crosses the map end to end, its gradient stays under the configured maximum, and it renders as a smooth curve on the terraced mesh.

### 4.9 Mesh and look
Terraced mesh with flat shading, vertex colour by terrain type, no textures. Tight palette. Water plane for rivers.
*Done when:* a fly-over reads clearly: you can see where the ridges, valleys, woods, river, and road are without a legend.

### 4.10 Camera
Free flying camera: WASD pan, mouse wheel zoom, right-drag orbit, edge scroll, clamped to map bounds and to a minimum height above terrain.
*Done when:* you can inspect any part of the map in under three seconds.

### 4.11 Tactical validation and seed pinning
`tools/map_metrics.gd` computes and prints, headless:

- **Sightline distribution.** Sample 5,000 random tile pairs with LOS; report median and quartiles. Target median 300 to 900 m.
- **Hull-down count.** Tiles masked from at least one approach direction that still hold LOS to ground beyond the crest. Target: at least 5% of tiles.
- **Chokepoints.** Minimum cut on the traversal graph between deployment zones. Target 2 to 6.
- **Balance.** Hull-down count and mean elevation per deployment zone, within 15% of each other.

Wire this into a generate-measure-reject loop. Then pin five named seeds as regression maps: Ridge, Village, Steppe, Chokepoint, Sprawl.
*Done when:* generating 20 maps yields at least 5 that pass, and the pinned seeds are committed with their metrics.

### 4.12 Tank entity and pathfinding
One tank, one type, no combat. A* over the traversal graph with facing in the search state (tiles x 8 facings), octile heuristic. Turning costs movement. Reverse movement is a distinct, costlier edge. Dijkstra flood fill for the movement range overlay.
*Done when:* the tank drives to any reachable tile, faces sensibly along its path, and the reachable set updates in under 50 ms.

### 4.13 Visibility
LOS by ray sampling against tile heights, from turret height at the observer to hull and turret height at the target, which yields three exposure states:

- **Exposed:** hull and turret both visible
- **Hull down:** turret visible, hull masked
- **Masked:** neither visible

Paint the overlay from the selected tank: one tint for tiles it sees exposed, another for tiles where a target would be hull down, nothing for masked.
*Done when:* driving along a ridge visibly flips the overlay, and the hull-down band appears just behind each crest.

### 4.14 Gunner view
Toggle to a camera at the selected tank's turret, looking along its facing. Confirms what the overlay claims.
*Done when:* what you see in gunner view agrees with the overlay on all five pinned seeds.

## 5. Data files

`data/terrain.json`: per terrain type, movement cost, spotting multiplier, colour.
`data/rules.json`: quantization step, traversal thresholds, spotting base ranges, erosion parameters, metric targets.
`data/units.json`: v1 roster, unused in iteration 1 but defined now.

Roster (three vehicles, four to five stats each):

| Unit | Speed | Armour F/S/R/T | Gun | Penetration | Optics | Role |
|---|---|---|---|---|---|---|
| Light | high | thin | small | low, high shred | best | Recon, flanking, armour shred |
| Medium | medium | moderate | medium | medium | good | Generalist |
| Heavy | low | thick front | large | high | poor | Anchor, breakthrough |

Every number in this table lives in JSON, not in code.

## 6. Out of scope for iteration 1

Combat resolution, penetration, criticals, spotting rules and ghost markers, enemy AI, objectives and win conditions, infantry, APCs, unit selection and turn cycling UI, save and load, the campaign layer, and the large-world map. All of these depend on ground that iteration 1 establishes.

## 7. Iteration 2 preview

Combat on the terrain from iteration 1: spotting and ghost markers, to-hit and penetration, non-penetrating outcomes, two component criticals (immobilised, gun damaged), overwatch, the three-unit roster, a three-rule enemy (advance to objective, prefer hull-down tiles, shoot the best target), objective capture, and Tab-cycling unit selection with a fast enemy turn.

That is the first version you can actually play.