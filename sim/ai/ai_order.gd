class_name AiOrder
extends RefCounted

## What a policy wants one unit to do — docs/decisions/0038.
##
## The whole vocabulary an AI has, and it is deliberately the player's vocabulary: every kind here
## maps onto exactly one `ActionResolver` entry point, so a policy cannot ask for anything a human
## could not click. A policy that wants a new verb has to give it to the player too.
##
## Pure data. The order does not know whether it is legal — `AiRunner` resolves it and the resolver
## refuses it exactly as it would refuse a click, which is what keeps the legality rules in one
## place.

enum Kind {
	## Deliberately stand the unit down for this turn.
	PASS = 0,
	MOVE = 1,
	FIRE = 2,
	OVERWATCH = 3,
	## Lay the turret on a bearing. Free, so it never ends the loop on its own — a policy that
	## answers TURRET forever is cut off by the runner's order cap.
	TURRET = 4,
}

var kind: int = Kind.PASS
## Index into the match's unit array — the unit being ordered.
var unit: int = -1
## MOVE: the destination tile.
var goal_tile: int = -1
## FIRE: the target's unit index, as carried on a `Contact` the view handed out.
var target: int = -1
## OVERWATCH and TURRET: the bearing, 0-7.
var bearing: int = -1


static func pass_order(unit_index: int) -> AiOrder:
	var o := AiOrder.new()
	o.kind = Kind.PASS
	o.unit = unit_index
	return o


static func move(unit_index: int, to_tile: int) -> AiOrder:
	var o := AiOrder.new()
	o.kind = Kind.MOVE
	o.unit = unit_index
	o.goal_tile = to_tile
	return o


static func fire(unit_index: int, target_index: int) -> AiOrder:
	var o := AiOrder.new()
	o.kind = Kind.FIRE
	o.unit = unit_index
	o.target = target_index
	return o


static func overwatch(unit_index: int, dir: int) -> AiOrder:
	var o := AiOrder.new()
	o.kind = Kind.OVERWATCH
	o.unit = unit_index
	o.bearing = dir
	return o


static func turret(unit_index: int, dir: int) -> AiOrder:
	var o := AiOrder.new()
	o.kind = Kind.TURRET
	o.unit = unit_index
	o.bearing = dir
	return o


func describe() -> String:
	return "k%d u%d g%d t%d b%d" % [kind, unit, goal_tile, target, bearing]
