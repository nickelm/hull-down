# 0019 — The road network is a spanning tree over villages and portals

Supersedes the routing and settlement-placement sections of
[0007](0007-tile-bound-roads-with-cut-and-fill.md). The representation from
[0011](0011-roads-as-a-link-layer.md) stands.

## Context

`roads.count` was 2, and the two roads were independent point-to-point A* paths between opposite map
edges with the axis alternated so they would tend to cross. Villages were then placed *at* the
junctions and crossings those paths happened to produce.

That is backwards as geography. People settle on good ground and then build roads between the places
they settled; the roads exist because the villages do. Placing villages at whatever junction two
arbitrary routes made means the settlements are an artefact of the roads, the network goes nowhere
in particular, and on a seed where the two paths do not cross there is no junction and a fallback
drops a village at the midpoint of the longest road.

## Decision

**Sites first, then a tree.** `SettlementPlacer.choose_sites` picks village tiles before any road is
routed — low, flat, dry, drivable ground away from the deployment zones, spread by
`min_separation_tiles`, off rock, marsh and forest. `RoadBuilder.build` then constructs a minimum
spanning tree over `{village sites} ∪ {edge portals}`, where a portal is the lowest drivable tile on
each map edge.

**Choosing moved earlier; stamping did not.** A village flattens its footprint to a median height
and the road runs straight through the middle of it, so `stamp_all` still runs after the road
earthworks and is still followed by `resmooth`. That ordering is what
`test_a_village_does_not_put_a_step_in_the_road` pins, and only the *choosing* was safe to move.

**Kruskal over a flat union-find, never a Dictionary.** Candidate edges are packed into a
`PackedInt64Array` and sorted as integers — the trick `place_objectives` and `_detect_fords` already
use. A Dictionary keyed by node pair would put the iteration order of the entire road network at the
mercy of hash ordering, and this is the one place in this batch where determinism could have been
lost without anything failing.

**Tree edges converge; bypasses do not.** Routing prices a step onto an existing road at
`roads.reuse_discount` (0.25), and edges are stamped in ascending cost order and **re-routed** as
they are laid rather than reusing the path that decided the tree's shape — so later edges run into
earlier trunks and the network grows arterials instead of parallel lanes.

The redundant edges are the exception, in two ways that both turned out to be necessary:

- They are chosen as the pairs **furthest apart along the tree**, not the cheapest pairs left over.
  Cheapest is the obvious choice and it is useless: the cheapest non-tree pair is almost always one
  already adjacent on the tree.
- They are routed at **full price**, with the reuse discount disabled. At 0.25, retracing the tree
  beats any direct line unless the detour is more than fourfold, which on a spanning tree it
  essentially never is — so the "redundant" edge lays itself down on top of the road already there
  and the network gains a duplicate rather than a loop. A bypass is built precisely because the
  existing way round is long; it has to be allowed to cut its own line.

## Consequences

- Every village is on the network by construction, because the villages are half of what the tree
  spans. The old "villages appear at junctions" rule is gone, along with its longest-road fallback.
- The end-to-end claim is now about the *network*: you can drive from one border to the other
  without leaving the tarmac. An individual road is a portal-to-village hop and may be short, so
  "one road touches both borders" no longer means anything even when it happens to be true.
- The network has at least one independent cycle, asserted as `edges − nodes + components ≥ 1` over
  the link mask. A pure tree gives every pair of places exactly one route, which is a road network
  with no alternatives and nothing to outflank.
- Generation costs `n(n−1)/2` extra A* searches to shape the tree — 28 at eight nodes, against the
  forty seconds erosion already costs. If that ever shows up, the fix is one single-source Dijkstra
  per node rather than a search per pair.
- The reuse discount makes the cheapest possible edge `base × reuse_discount`, so `route` passes
  that as the A* heuristic scale rather than `base`. Passing `base` was correct until the discount
  existed and would silently overestimate afterwards. Edge costs are floored at 1, because
  `IntHeap.push` shifts the key left twenty bits and a non-positive key corrupts the packing.
- `roads.count` and `roads.min_endpoint_separation_frac` are gone; `roads.portal_count`,
  `roads.redundant_edges`, `roads.reuse_discount` and `settlements.site_count` replace them.
- Every road on every seed changes. That is expected — the `roads` substream's consumption changed —
  and it is why the pinned seeds are re-measured in the same batch.
