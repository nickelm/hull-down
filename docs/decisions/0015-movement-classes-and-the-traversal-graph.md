# 0015 — Movement classes and the traversal graph

Amends the edge-table section of [0008](0008-facing-in-the-pathfinding-state.md).

## Context

Four separate pieces of code answered "can something move from here to there, and what does it
cost": the movement overlay in `TankPathfinder`, the connectivity flood fill in
`ConnectivityRepair`, the repair pass's relaxed Dijkstra, and the chokepoint min-cut in
`VertexMinCut`. Each derived the answer independently through `can_move → neighbour → transition →
neighbour`, six function calls deep per edge — the call chain the journal already recorded as most
of the overlay's frame budget — and nothing structurally guaranteed the four agreed. A map the
flood fill calls connected and the min-cut calls severed is a disagreement nobody can see.

Separately, terrain does not have *a* movement cost. It has one per kind of vehicle. A marsh is slow
for a tank, impossible for a lorry and merely wet for infantry. `data/terrain.json` had one
`move_cost` per type, and "can a tank go here" was therefore hardcoded into the graph — so
introducing any second kind of vehicle would have meant touching pathfinding, the reachability
fill, the repair pass and the metrics at once.

## Decision

**One table, built once, shared by everyone.** `TraversalGraph` is built from `(MapData, Config,
movement class)` and holds `tile_cost`, `edge_cost` and `edge_target` as flat `Packed*Array`s, plus
the octile heuristic's lower bound. It is an extraction, not an addition — `TankPathfinder` already
built precisely this table — and the four consumers now read it instead of re-deriving it. The fill,
the repair and the min-cut agreeing is now structural rather than something to test for.

**The class dimension lives on the graph, not on `MapData`.** `movement_classes` in
`data/terrain.json` is an array parallel to `types`, indexed by `MovementClass.Kind`, and the
per-type `move_cost` field is deleted so there is one source of truth. `Config.terrain_move_cost`
becomes a *slice* of that table for the reference class rather than a second copy of the numbers.

`MapData.move_cost` keeps its length `n` and `is_passable(i)` keeps its one-argument signature,
both redefined as **the reference class** — tracked, the only class iteration 1 fields. Six
consumers genuinely mean "is this ground at all" rather than "can a Panther go here"
(`place_objectives`, `Deployment`, the sightline and hull-down metrics, `SettlementPlacer`,
`_pick_portals`), and giving them a class parameter would be churn without a caller. A defaulted
`mclass = 0` parameter was rejected: a default silently classifies, and there is no compiler help
when the wrong one is meant.

**Nothing about the class dimension is serialized.** `MapCodec`'s layout is unchanged and
`content_hash()` still hashes only the reference row, so the hash keeps meaning "the terrain
changed" rather than moving whenever a data row is added.

**Dynamic obstructions are a per-query overlay, not part of the graph.** `reachable` and `find_path`
take an optional `PackedByteArray` of blocked tiles, hoisted to one bool and one array read in the
hot loop. The graph is the static map and is built once; occupancy changes every time anything
moves, and rebuilding two megabytes of table for that would be absurd.

## Consequences

- Adding a movement class is a data change. The graph, the fill, the repair and the min-cut are
  already parameterized.
- The graph restates `can_move`'s rule against its own costs rather than delegating. It has to:
  `md.can_move` answers for the reference class, so asking it about an amphibian returns the tank's
  answer — which is how a boat first failed to cross a river. Two statements of one rule is a drift
  risk, and `test_traversal::test_the_graph_agrees_with_map_data_for_the_reference_class` walks
  every edge of a generated map to keep them honest.
- `min_cut` and `reachable_from` now require a graph argument rather than building one. "Which graph
  did you mean" must not have a silent default answer.
- The repair pass rebuilds the graph at the top of each pass rather than patching it. A fifth of a
  second against forty seconds of erosion buys the guarantee that the search and the fill agree, and
  an incremental invalidation path through that function is the kind of cleverness the rest of it is
  a monument to getting wrong.
- `PathResult.blocks_firing` still reads `MapData.transition` directly. Once `edge_cost` bakes the
  rough-going surcharge in, the table can no longer say *which* edges were rough.
- Units carry a `movement_class` read from `units.json`; `PlayerController` keeps one pathfinder per
  class actually in play.
