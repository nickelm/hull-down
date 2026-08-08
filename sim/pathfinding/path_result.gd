class_name PathResult
extends RefCounted

## A route for a tank: the tiles, the facing it holds on each one, and what it cost.

## Tile indices from start to destination, inclusive.
var tiles: PackedInt32Array = PackedInt32Array()
## Facing on arrival at each tile, parallel to `tiles`.
var facings: PackedInt32Array = PackedInt32Array()
## 1 where the step into that tile was driven in reverse.
var reversed: PackedByteArray = PackedByteArray()
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
