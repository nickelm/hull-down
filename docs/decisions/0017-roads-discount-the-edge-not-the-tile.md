# 0017 — Roads discount the edge, not the tile

Amends the modifier section of [0011](0011-roads-as-a-link-layer.md).

## Context

0011 established that a road is a layer over terrain rather than a kind of terrain, and that where
one runs, "the road's `move_cost` replaces the terrain's". That was implemented as a tile-level
override in `TerrainTyper.apply_terrain_attributes`, and a tile-level override pays out to a tank
crossing the road at right angles — a vehicle that spent no time on the road at all and drove
straight over it into the field beyond, for a discount.

## Decision

The modifier has two halves and they are different things.

> **Deck.** Where a road runs over ground the class could not otherwise enter, the road's cost
> replaces it. That is a *passability override*, and it is what makes a bridge over a river
> drivable. It is applied to the tile.
>
> **Surface.** The discount for travelling along a road is applied to the **edge**, and only where
> the step follows a road link. A step along a road is priced at the road's surface cost outright,
> not as a multiplier on the destination tile, because the vehicle is on the made surface for the
> whole step and what is underneath it is irrelevant.

`MapData.link_road` sets the bit on both sides of one shared edge, so `has_road_link(from, d)` *is*
the test "the entering and the leaving edge are both road-connected" — there is one bit, not two.
Cover is still cleared on any road tile either way; a road is cut through the trees whichever
direction you are driving.

## Consequences

- A road extends reach along its length and not across it, which is what makes a road a corridor
  rather than a discount stripe. It is also what makes ambushing one meaningful.
- The octile heuristic's lower bound can no longer be a scan of `MapData.move_cost`. A road step is
  priced on the edge and can be cheaper than any tile on the map, so a bound taken from the tiles
  would overestimate the cost of a route along a road — and an inadmissible heuristic returns routes
  that are visibly not the shortest and very hard to argue with afterwards. It is now recovered from
  the built edge table by dividing each step cost back out by its own base, which is exact by
  construction and truncates downward, the safe direction.
- No tile can take both halves. A bridge deck is standable at the road's cost because its natural
  ground is impassable; it does not also collect the surface discount for a step that crosses it.
- Tests that asserted `move_cost[i] == road_cost` on every road tile were asserting the tile-level
  rule and are now edge assertions.
- A consequence discovered while writing this: `RoadBuilder.route` never did prefer reusing existing
  roads, though it looked as though it must. `apply_terrain_attributes` runs once *after* the whole
  build loop, so no road ever saw another road's discount in `move_cost`. The reuse discount added
  in [0019](0019-roads-as-a-spanning-tree.md) is therefore new behaviour, not restored behaviour.
