# 0013 — How dramatic the terrain can be

## Context

Playtesting said the terrain is boring. The obvious reading is that the map is too flat, and
`world.target_relief_m` had been cut from 220 m to 50 m during §4.6 to get impassable edges down
from 50% to a workable 7–13%.

**The first hypothesis was wrong, and it is worth recording why.** It went: total relief and
drivability are separable, because drivability is a function of *slope*, and slope is relief
divided by the width of the landform — so lowering `erosion.thermal.repose_deg` from its 34° would
let the same relief arrive as taller hills with flanks a tank can climb. Repose had never been the
binding constraint, so it looked like free headroom.

It is not free, for a reason the arithmetic makes obvious once written down. **Impassability is
itself an angle.** A tile edge is blocked at a 2.5 m step across a 10 m tile, which is 14°. An
angle does not care what scale it is measured at, so capping slopes at any repose above 14° still
leaves a sustained slope at repose impassable — and every repose the config allows is above 14°,
because `test_repose_still_permits_escarpments` requires better than 11.3° for escarpments to be
possible at all. The window between "escarpments can exist" and "sustained slopes are drivable" is
11.3°–14.0°, and inside it thermal erosion is doing an enormous amount of work for almost nothing.

Measured, on four seeds at `target_relief_m` 70:

| repose | escarpment fraction | thermal passes |
|---|---|---|
| 34° | 14.2%, 16.5%, 14.6% | 25–133 |
| 18° | 14.5%, 17.5%, 14.3% | 494–887 |

Under one percentage point of difference, for twenty to fifty times the work. At the shipping
heightfield size the 22° experiment cost 471 seconds of thermal erosion against a handful.

## Decision

**`target_relief_m` is the dial, and the escarpment band is what bounds it.** Repose returns to
34°, `max_carve_depth_m` to 2.5 m, and octaves to 5 — all three were moved on the strength of the
hypothesis above and none of them earned their place.

Relief goes from 50 m to **65 m**. Measured at shipping settings — 800² heightfield, 500k droplets —
across four seeds:

| relief | escarpment | relief variety | level span | roads within gradient limit |
|---|---|---|---|---|
| 60 m | 9.1% | 1.85 quanta | 126 quanta (63 m) | yes |
| **65 m** | **10.7–14.3%** | **1.98–2.27** | **134–143 (67–72 m)** | **yes** |
| 70 m | 12.5–15.3% | 2.12–2.23 | 144–152 | yes |
| 80 m | 15.9–17.7% | 2.37–2.50 | 160–169 | no (1.5 m step) |
| 95 m | 20.7–21.2% | 2.76–2.88 | 184–196 | yes |

65 m is the most relief that keeps every seed inside the 3–15% band from
[0009](0009-operational-definitions-for-map-metrics.md) with headroom on the worst of them. 70 m
puts one seed in four over the ceiling; 80 m puts all of them over and starts breaking the road
gradient limit as well. 95 m — which is closer to what "dramatic" would want — costs 21% impassable
edges, which is a different game.

**Measure at the full droplet count.** A reduced-droplet tuning run (`--hf-size 400 --droplets
120000`) reads three to five points *pessimistic* on escarpment, because hydraulic erosion is what
smooths the fine detail that steep tile edges are made of. The first pass at this landed on 60 m
from reduced-droplet numbers and left real headroom on the table.

**A new metric makes this measurable rather than a matter of opinion.** `relief_variety` in
`sim/metrics/map_metrics_calc.gd` reports the mean absolute `level` delta across tile edges in
quanta — "how many terrace steps does a tank cross per tile of travel" — plus the fraction of edges
with no step at all and the map's total level span. It is **reported, not gated**: the journal
records that the §4.11 targets already fail on every seed, and a fourth failing gate would make the
batch tool less useful rather than more.

It also corrected a second wrong belief. The argument for "the map is one flat terrace" was that
50 m over 2 km is 0.25 m per tile, under one 0.5 m quantum. That is the *mean gradient across the
whole map*, which is not the *local* tile-to-tile step — terrain is ridged, not a uniform ramp. The
50 m map measures 1.82 quanta per edge, nearly a metre. It was never the terrace the arithmetic
claimed.

## A second finding: the test pipeline was not measuring the shipping map

`Params.small` shrinks the world to a quarter and keeps the cell and tile sizes, and its docstring
gives the reason: stretching the tiles instead would quadruple every tile-to-tile drop, so "tests
would be running against terrain the game never produces". The principle was right and applied to
only one axis. `target_relief_m` was still being applied whole to a quarter-size world, so the small
pipeline had four times the gradient of the shipping map — it measured **37% impassable edges where
the shipping map measures 12%**, and roads failed their gradient limit on it.

Relief is now scaled by the world's span in `BaseRelief.generate`, so what stays constant across
sizes is the *gradient* rather than the height range. The edge-falloff ramp, whose own note says it
is sized against total relief, scales with it. The small pipeline now measures 0–5% escarpment
against the shipping map's 11–14% — gentler rather than steeper, because a quarter-size world samples
fewer cycles of the low-frequency octaves — but it is the same terrain the game makes, which is what
a test needs it to be.

## Consequences

- Terrain gains about 18% in total span and 15% in local step. Real, and considerably less than
  "dramatic". Within the drivability band that is the ceiling, and the honest answer to "make the
  terrain more interesting" is that the band has to move first.
- If more drama is wanted, the decision to revisit is **0009's 3–15% escarpment band**, not the
  generator. That is a question about what kind of battlefield this is — open country a tank can
  cross, or broken ground that funnels — and it wants its own record.
- Repose staying at 34° keeps map generation affordable. The 22° experiment made the *test suite*
  impractically slow, which is its own argument.
- `tools/generate_map.gd` gained `--relief`, `--octaves`, `--h-exp`, `--gain`, `--carve` and
  `--repose` overrides, so a sweep runs several configurations side by side without editing
  `data/rules.json` between them. With `--hf-size 400 --droplets 120000` a configuration measures
  in well under a minute, which is what made this record possible.
- `h_exp` moved 0.45 → 0.30 because that is the value the accepted sweep was measured at. Between
  0.22 and 0.30 it changed escarpment by 0.1 points, so it is not a lever either.
