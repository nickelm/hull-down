# 0009 — Operational definitions for the map metrics

## Context

0006 makes the metrics the arbiter of map quality, which means each metric has to be both faithful
to what it claims to measure and cheap enough to run on every candidate seed. Three of the four
metrics in the spec (§4.11) were stated in a way that fails one of those tests.

## Decision

### Sightline distribution — measure rays, not pairs

The spec says: sample 5,000 random tile pairs with LOS, report median, target 300-900 m.

Taken literally this mostly measures the shape of the map. On a 2 km square the median separation
of two uniformly random tiles is about 1030 m, so the reported median is dominated by that
distribution rather than by the terrain, and it would rarely land in the target band no matter what
the generator did.

Both metrics are computed. The spec's pair metric is reported as `sightline_pair_median_m` for
continuity. The **gate** is a ray-march metric: sample 5,000 random `(tile, direction)` pairs, march
outward until the ray is blocked, and report the distribution of unobstructed distances. That is
what "sightline" means tactically — how far can you see from here, that way — and it responds
correctly to erosion and woods parameters.

### Hull-down count — a local crest test

The spec's definition ("tiles masked from at least one approach direction that still hold LOS to
ground beyond the crest") is correct but not operational, and implemented literally as a virtual
observer per tile per direction it is 640,000 rays and takes minutes per map.

Operational form: from tile T, walk outward along direction d for up to `hull_down_crest_reach_tiles`
(12). T counts as hull-down-capable in direction d if there is a cell c within that reach with
`h(c) >= h(T) + hull_h` (the crest masks T's hull) and `h(c) < h(T) + turret_h` (it does not mask
T's turret), and the profile beyond c descends (so there is ground to see). About 3.8M cheap samples,
under a second at stride 2.

### Chokepoints — vertex min cut, not edge

The spec says "minimum cut on the traversal graph". On a grid graph an edge cut gives inflated,
tactically meaningless numbers. The question being asked is "how many tiles must someone hold to
seal the map", so the cut is over **vertices**: split each passable tile into in-node and out-node
joined by a capacity-1 arc, adjacency arcs infinite.

Edmonds-Karp terminates after `mincut` augmentations, and the target band is 2-6, so the search is
capped at 8 and reports "greater than 6" if it saturates. That is why a max-flow computation is
cheap here — 20-100 ms — despite the algorithm's reputation.

### Escarpment edge fraction — a new metric

Not in the spec. Added because 0002's escarpments and the angle-of-repose cap in §4.4 are in tension:
if repose is shallow, no transition ever exceeds 2.0 m, escarpments never exist, and the entire
connectivity-repair path is dead code that has never once executed. Target band 3-15% of internal
edges, with `repose_deg` at 38-42 to keep it satisfiable.

## Consequences

- Every metric is under a second except the min cut, so the generate-measure-reject loop is bounded
  by generation time, not by measurement.
- The sightline gate is a different number from the one in the spec text. Anyone reading §4.11
  should read this record alongside it.
- `hull_down_crest_reach_tiles`, `hull_down_stride`, `hull_h_m`, `turret_h_m`, and the min-cut cap
  are all in `data/rules.json`. Tightening a metric does not mean touching code.
- The crest test is an approximation of the ray-cast definition. It can differ at the margins — a
  crest 13 tiles away is invisible to it. That is acceptable for a selection metric; the
  authoritative per-pair answer remains `Los.classify()`, which is what the game itself uses.
