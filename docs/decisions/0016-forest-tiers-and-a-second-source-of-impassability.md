# 0016 — Forest tiers, and cover height as the real design axis

## Context

Woods was one type: cost 1.8, 8 m of line-of-sight cover, about 17% of the map. That single number
was doing two unrelated jobs badly.

**The visibility half is the important one, and it had not been understood.** `Los.clear_range`
blocks when a tile's cover rises above the observer's eye line, and the eye sits at ground plus
`visibility.turret_h_m` (2.6 m). On level ground a blocker of height `b` contributes an elevation
angle of `(b − 2.6) / d`, and the next tile's turret angle is `0`:

| `blocker_h` | angle contributed | effect |
|---|---|---|
| 8.0 | `+5.4/d` | blocks |
| 3.0 | `+0.4/d` | blocks — identically, on the level |
| 2.2 | `−0.4/d` | clear, and masks a nearby target's hull |

**It is a threshold at turret height, not a dial.** A tier at 3 m occludes exactly as thoroughly as
one at 8 m. This is why the §4.11 sightline gate has failed on every seed the generator has ever
produced, and why the journal concluded that reaching a 300 m median "needs woods nearer 3%, which
is a different kind of map" — with every stand opaque, the only lever left was coverage.

The movement half was a separate gap: water was the only impassable terrain on the map, so the
connectivity guarantee had never been tested against anything else, and the repair pass could only
cut escarpments.

## Decision

**Three tiers, chosen against the sight lines rather than for looks.**

| type | tracked | `blocker_h` | why that height |
|---|---|---|---|
| `woods_light` | 1.4 | **2.2** | below `turret_h_m` 2.6 and above `hull_h_m` 1.4 — invisible to a tank's line of sight, and still masks a target's hull |
| `woods` | 1.8 | 8.0 | unchanged |
| `woods_heavy` | **impassable** | 10.0 | timber a tracked or wheeled vehicle cannot enter; infantry can |

The light tier is the point. It raises sightlines **without thinning forest coverage at all**, which
is the resolution the journal could not find, and a stand between the hull and turret lines is
concealment that hides the hull and leaves the turret — the state this game is named after.

**Heavy forest is a second source of impassability, so repair generalizes.** The relaxed Dijkstra
in `ConnectivityRepair` now prices three ways of opening ground against each other in one search:
cut an escarpment (`earthwork_penalty` 40 per excess quantum), clear a stand (`clear_penalty` 120
per tile), or lay a ford (`ford_penalty` 600 per tile, and capped by `max_repair_fords`). The
penalties are an order apart on purpose: earthwork is routine, felling a forest is a decision, and
putting a crossing where the hydrology did not is a last resort.

**Tiers are promoted after majority smoothing, by rank.** Smoothing replaces any tile whose
neighbours hold a strict majority, three passes over, so a dense core assigned before it is a
minority all along its own edge and gets eaten back to ordinary woods almost everywhere. Promotion
therefore runs afterwards, on its own noise substream, and splits the stands by **rank** rather than
by an absolute threshold — "the densest fifth of the forest" means that on every seed, whereas a
fixed threshold gives whatever that seed's noise happened to put above it.

## Consequences

- Measured over twenty seeds, the sightline median moved from 113 m to 140 m. That is real and it is
  not enough: the band is 300–900 m. What the band should be is [0020](0020-the-sightline-band.md).
- Terrain types are appended, never inserted. These are raw array offsets into
  `cfg.terrain_colours` and friends; inserting a tier next to `woods` at index 3 would renumber
  everything above it and silently repaint every map.
- Anything measuring "is this forest" must ask `TerrainTyper.is_woods`. Comparing against `WOODS`
  still compiles and silently measures a third of the forest.
- Heavy timber is never promoted onto a watercourse. Smoothing can turn a stream tile into woods —
  marsh is not a fixed type — and an impassable stream is exactly the wall-the-map-off outcome the
  stream rule exists to prevent.
- Deployment-zone scoring now penalizes impassable ground, not just water. Without that a zone lands
  in a wood and is quietly shrunk afterwards by `_prune_stranded_zone_tiles`.
- The repair's ford op is compound: a river bed sits metres below its banks, so the tile is raised
  to sit between its route neighbours and reclassified, not merely re-marked. A ford that was only a
  marker would be drivable ground with blocked edges on both sides — a crossing to nowhere.
- `ScatterBuilder` takes each tile's own `blocker_h`, so one unit-height mesh serves all three tiers
  and a light stand comes out shorter and proportionally narrower. Leaving it matching `WOODS`
  exactly would have given the new tiers no scatter at all, silently — light woods reading as open
  ground while `Los` marched against its cover, which is the defect that file exists to prevent.
- Passable ground fell from about 96% to about 94%.
