class_name PathResult
extends RefCounted

## A route for a tank: the tiles, the facing it holds on each one, and what it cost.

## Tile indices from start to destination, inclusive.
var tiles: PackedInt32Array = PackedInt32Array()
## Facing held on each tile, parallel to `tiles`.
##
## Turn-in-place states are collapsed by `find_path` — a tile the tank turns on appears once, and
## the facing recorded is the **last** one held there, which is the facing it departs with. So for
## the step from `tiles[k]` to `tiles[k + 1]`, the heading is `facings[k]`. Reading `facings[k + 1]`
## instead gives the heading for the step after, which is a full tile early.
var facings: PackedInt32Array = PackedInt32Array()
## 1 where the step into that tile was driven in reverse.
var reversed: PackedByteArray = PackedByteArray()

## What it cost to drive into `tiles[k]` from `tiles[k - 1]`. `step_cost[0]` is 0 — there is no step
## into the tile the tank is already standing on.
##
## Filled during backtracking from the `g` values the search already holds, rather than recomputed.
## The pathfinder owns the cost model; a second copy of it can disagree with the search, and a
## preview that disagrees with what the move charges is the worst kind of bug this game can have.
var step_cost: PackedInt32Array = PackedInt32Array()

## What it cost to turn on the spot while standing on `tiles[k]`, before departing it.
##
## Turn-in-place states are collapsed out of `tiles`, so this is where the price of that collapse
## goes — without it a route's cost cannot be attributed to the tiles it was spent on. `turn_cost[0]`
## is the swing the tank makes before it sets off, which is often the surprising part of the bill.
##
##     invariant: sum(step_cost) + sum(turn_cost) == cost
var turn_cost: PackedInt32Array = PackedInt32Array()

var cost: int = 0
var found: bool = false

## True if any step crossed a rough transition.
##
## The spec says a rough transition means the unit cannot fire that turn. There is no combat in
## iteration 1, so this is computed after the fact and displayed, rather than being carried in the
## search state — putting it in the state would double the state space to record something nothing
## currently reads.
var blocks_firing: bool = false


func length() -> int:
	return tiles.size()


func destination() -> int:
	return tiles[tiles.size() - 1] if tiles.size() > 0 else -1


func final_facing() -> int:
	return facings[facings.size() - 1] if facings.size() > 0 else 0


## Everything paid to arrive on `tiles[k]` and be pointing the right way to leave it. What the path
## preview attributes to that tile.
func tile_cost(k: int) -> int:
	if k < 0 or k >= step_cost.size():
		return 0
	return step_cost[k] + turn_cost[k]
