# 0018 — Rivers are diagonally impermeable

## Context

A river is supposed to be an obstacle you cross at a bridge or a ford. It was not one. Consider a
channel running diagonally, one tile wide — water at (5,5) and (6,6), dry land at (6,5) and (5,6).
Stepping from (6,5) to (5,6) has a dry destination and flat transitions, so every check in
`MapData.can_move` passed it: the diagonal rule inspected the two adjoining *level transitions* and
never the corner *tiles*. A tank drove across the water.

The obvious specification is a minimum width. That is the wrong requirement — it names an
implementation, and a two-tile channel with the old rule still leaks wherever the two tiles happen
to meet at a point.

## Decision

**State the requirement as a property: a river must be diagonally impermeable.** The mechanism is a
corner rule, not a width. `MapData.can_move` now additionally requires both corner tiles of a
diagonal to be ground the class can stand on:

```gdscript
return ca >= 0 and cb >= 0 and move_cost[ca] >= 0 and move_cost[cb] >= 0
```

This is the same shape as the existing escarpment-corner rule — tanks do not cut corners between two
cliffs — extended to the fact that water is now not the only impassable terrain.

**Widening the channels was considered and rejected.** `river_half_width_cells` is 4.5 at 2.5 m per
cell, a 22.5 m channel, and `downsample_water` collapses by presence, so rivers already mark two to
three tiles across in most places. The only real leak was the one-tile diagonal staircase, and the
corner rule closes exactly that. Widening would eat map area, raise the impassable fraction, push
the chokepoint metric toward its floor, and — the trap that decided it — invalidate every ford:
`_detect_fords` picks its crossings on the heightfield before any widening, so a ford sized for a
one-tile river becomes a one-tile gap in a two-tile one, which is a crossing that leads into the
water.

**The test is local and exhaustive, not a bank-to-bank flood fill.** For every diagonal step between
two tiles of dry land whose two shared corners are both impassable, the step must be illegal. That
is the property stated exactly, it is one pass over the map, and it is deterministic.

A component-count assertion was the obvious alternative and would have been wrong: a river fades
upstream into `STREAM`, which becomes drivable marsh, so on many perfectly good seeds the river runs
from mid-map to one edge and divides nothing at all.

**Crossings are a reported metric, gated only where the water actually divides the map.**
`MapMetrics.river_crossings` closes every ford and bridge — reusing the same per-query blocker
overlay the pathfinder uses for occupancy — counts components, and then counts how many crossing
groups join two different ones. `metrics.river_crossings_min`/`_max` are 2 and 4, applied only when
`spans_map` holds. Where the river does not separate the ground, a crossing count is not a fact
about the terrain; it is a fact about where the channel happened to stop.

## Consequences

- The corner rule removes edges from the traversal graph and nothing else. Passability is unchanged,
  and `escarpment_fraction` reads `trans`, so the band the generator is tuned against does not move.
- It does move the chokepoint metric, and sharply: measured over twenty seeds the min-cut median
  fell from 29 tiles to 16. That is the correct number — those diagonals were never crossable in any
  meaningful sense — but it pushes the low end of the distribution toward the 0.05 floor, and
  0009's chokepoint band should be re-read against the new distribution rather than assumed.
- The rule is per class, so an amphibian is not stopped by corners it can swim through. That is also
  the test that proves the class parameter is threaded through the graph rather than decorative.
- Because the rule is stated twice — once in `MapData.can_move` for the reference class and once in
  `TraversalGraph` against its own costs — the two are pinned together by a test that walks every
  edge of a generated map.
