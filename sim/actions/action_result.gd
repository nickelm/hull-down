class_name ActionResult
extends RefCounted

## What an action turned out to be: whether it was legal, and the ordered account of what happened.
##
## Produced by `MoveAction.plan`, which is pure — a planned result has a full event list and has
## changed nothing. `MoveAction.commit` walks that list into the state and sets `committed`.
## docs/decisions/0022.

## Why an action was refused, or OK.
##
## An enum rather than a message: `sim/` carries no English. The controller turns these into
## something a player reads, and an AI turns them into nothing at all.
enum Status {
	OK = 0,
	## No such unit index.
	NO_UNIT = 1,
	## The unit belongs to a side that is not the active one.
	WRONG_SIDE = 2,
	## Already marked done for this turn.
	ALREADY_ACTED = 3,
	## Not enough movement points left for even the cheapest step.
	NO_MOVEMENT = 4,
	## Ordered to the tile it is already standing on.
	SAME_TILE = 5,
	## Outside the reachable set for what it has left.
	UNREACHABLE = 6,
	## Reachable set says otherwise, or none was supplied, and the search still found nothing.
	NO_ROUTE = 7,
	## Something is standing on the destination.
	OCCUPIED = 8,
	## Retired with the free hull swivel — docs/decisions/0035 supersedes 0032. The slot is left
	## occupied rather than reclaimed: `status` is the first field `ActionResult.fingerprint()` writes,
	## so renumbering would silently change the meaning of every recorded fingerprint, which is the same
	## argument `ActionEvent.Kind` makes for appending and never inserting.
	RETIRED_9 = 9,
	## The racks are empty.
	NO_AMMO = 10,
	## A critical took the gun out — docs/decisions/0029.
	GUN_DAMAGED = 11,
	## The turret cannot be brought round that far without turning the hull — docs/decisions/0027.
	OUT_OF_ARC = 12,
	## The side has not spotted it, or this firer cannot see it from where it stands.
	NOT_VISIBLE = 13,
	## Crossed a rough transition this turn, so it cannot fire — docs/design/rules.md 2.4.
	FIRE_BLOCKED = 14,
	## Ordered to shoot at itself or at a friend.
	FRIENDLY = 15,
	## The target is already a wreck.
	TARGET_GONE = 16,
	## Immobilised, so it is not driving anywhere — docs/decisions/0029.
	IMMOBILISED = 17,
}

var status: int = Status.NO_UNIT
## Index into `MatchState.units`.
var unit: int = -1
## The ordered account. Empty for anything that was refused.
var events: Array[ActionEvent] = []
## The route the events were built from. Null if the action never got as far as a search.
var path: PathResult = null
var mp_before: int = 0
var mp_after: int = 0
## Set by `MoveAction.commit`. Guards against a result being applied twice.
var committed: bool = false
## Something cut the action short — reaction fire, in iteration 2. The stream is still a complete and
## self-consistent account, just of a shorter action than was planned: its `END` names the tile the
## unit actually stopped on. Nothing about replaying it needs to know this, which is the point. It is
## here so the controller can say so and the player is not left wondering why the tank stopped.
var interrupted: bool = false


func ok() -> bool:
	return status == Status.OK


func cost() -> int:
	return mp_before - mp_after


## Where the unit actually ended up, which is the `END` event's tile and not the route's last one.
##
## Those agree for an uninterrupted move and disagree for a truncated one, and the stream is the
## authority — `path` describes what was *planned*, and after 0026 that is no longer the same claim.
func destination() -> int:
	var e: ActionEvent = last()
	if e != null:
		return e.tile
	return path.destination() if path != null else -1


func final_facing() -> int:
	var e: ActionEvent = last()
	if e != null:
		return e.facing
	return path.final_facing() if path != null else 0


func event_count() -> int:
	return events.size()


## The first event, which carries the starting pose, or null.
func first() -> ActionEvent:
	return events[0] if not events.is_empty() else null


## The last event, which carries the final pose, or null. A replayer that understands only `first`
## and `last` can apply the whole action — which is exactly what instant playback is.
func last() -> ActionEvent:
	return events[events.size() - 1] if not events.is_empty() else null


## Whether the unit ran itself out of movement doing this.
func exhausted() -> bool:
	for e: ActionEvent in events:
		if e.kind == ActionEvent.Kind.ACTIVATED:
			return true
	return false


## A single integer standing for the whole event stream, so a determinism check is one comparison
## rather than an element-wise walk.
##
## `Rng.fnv1a`, not `String.hash()` — the engine does not promise the latter is stable across
## versions, and a determinism fingerprint that quietly changes with the engine is worse than none.
func fingerprint() -> int:
	var parts := PackedStringArray()
	parts.append("s%d u%d" % [status, unit])
	for e: ActionEvent in events:
		parts.append(e.describe())
	return Rng.fnv1a("\n".join(parts))


## Mechanical dump of the whole stream, one event per line. Tests and logs.
func describe() -> String:
	var parts := PackedStringArray()
	for e: ActionEvent in events:
		parts.append(e.describe())
	return "\n".join(parts)
