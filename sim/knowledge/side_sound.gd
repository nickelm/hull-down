class_name SideSound
extends RefCounted

## What one side has *heard* — docs/decisions/0033 and 0037.
##
## The sibling of `SideKnowledge`, and sibling is the whole point. 0033 refused to add a fourth
## `HEARD` value to that class's `State`, because a marker built from a noise is not a fainter version
## of a marker built from a sighting: it needs no line of sight, its position is deliberately wrong,
## it carries no identity, and it decays on its own schedule. Sharing one enum would put those into
## one code path and every consumer would then have to ask "is this the precise kind or the imprecise
## kind" at the point of use — which is the check that gets forgotten once. Two containers make the
## question unaskable.
##
## **This container is list-shaped, not unit-indexed, and that is structural rather than an
## optimisation.** `SideKnowledge` is one slot per unit because a sighting is *about* a unit. A sound
## is not. There is nowhere here to put a unit index, so no consumer can recover one, so no marker can
## quietly acquire an identity later — 0033's "identity: not known" row enforced by the shape of the
## arrays rather than by anyone remembering it.
##
## **The stored tile is the errored one.** The true tile never enters this class, is never passed to
## it, and cannot be recovered from it. `Sound` does the displacement and hands over the result; if
## the truth were kept here "for the renderer to interpolate" or any other reason, the layer would be
## perfect intelligence wearing a blur.

## What made the noise. Not identity — a gun and an engine sound different, which is a fact about the
## noise and not about who produced it.
enum Source {
	FIRE = 0,
	MOVE = 1,
}

var side: int = 0

## Structure-of-arrays, parallel, and all four the same length. `_heard_tile` is the **errored** tile.
var _heard_tile: PackedInt32Array = PackedInt32Array()
var _heard_source: PackedByteArray = PackedByteArray()
## The uncertainty radius the marker is drawn at, in decimeters. An integer because `fingerprint`
## has to be exactly reproducible and a float that survives one arithmetic path may not survive
## another — the same argument 0010 makes about pinning maps.
var _heard_error_dm: PackedInt32Array = PackedInt32Array()
var _heard_turns_left: PackedInt32Array = PackedInt32Array()


static func create(for_side: int) -> SideSound:
	var s := SideSound.new()
	s.side = for_side
	return s


func count() -> int:
	return _heard_tile.size()


func tile_at(k: int) -> int:
	return _heard_tile[k] if k >= 0 and k < _heard_tile.size() else -1


func source_at(k: int) -> int:
	return _heard_source[k] if k >= 0 and k < _heard_source.size() else Source.FIRE


func error_dm_at(k: int) -> int:
	return _heard_error_dm[k] if k >= 0 and k < _heard_error_dm.size() else 0


func turns_left_at(k: int) -> int:
	return _heard_turns_left[k] if k >= 0 and k < _heard_turns_left.size() else 0


## Record a noise at `tile` — already errored — and report whether it was news.
##
## **The dedupe is what makes the `HEARD` arm of `EventApplier` idempotent**, which every non-arithmetic
## arm has to be: the resolver applies each event as it appends it and a stream may be replayed over a
## state that already has it. Two noises of the same source at the same errored tile are one contact,
## so applying the same event twice adds nothing the second time, and re-applying a whole stream from
## the live state is a no-op exactly as `mark_seen` is.
##
## Keying the dedupe on (tile, source) rather than on turns or radius is deliberate: those two are what
## the player can see. A second shot from the same place refreshes the contact's life rather than
## stacking a second ripple on top of the first, which would read as two enemies.
func add(tile: int, source: int, error_dm: int, turns: int) -> bool:
	if tile < 0 or turns <= 0:
		return false
	for k: int in _heard_tile.size():
		if _heard_tile[k] == tile and _heard_source[k] == source:
			_heard_turns_left[k] = maxi(_heard_turns_left[k], turns)
			return false
	_heard_tile.append(tile)
	_heard_source.append(source)
	_heard_error_dm.append(maxi(error_dm, 0))
	_heard_turns_left.append(turns)
	return true


## Age every contact by one turn and drop the ones that have run out, returning how many went. Called
## once as this side takes over, never per action — the same rule and the same reason as ghost decay.
##
## Walks backwards so a removal cannot shift an index this loop has not reached yet. The arrays are
## members and are written through directly rather than aliased: `Packed*Array` is a value type, and
## `var t := _heard_tile` would give a private copy whose `remove_at` this class would never see.
func decay() -> int:
	var gone: int = 0
	for k: int in range(_heard_tile.size() - 1, -1, -1):
		_heard_turns_left[k] -= 1
		if _heard_turns_left[k] <= 0:
			_heard_tile.remove_at(k)
			_heard_source.remove_at(k)
			_heard_error_dm.remove_at(k)
			_heard_turns_left.remove_at(k)
			gone += 1
	return gone


func clear() -> void:
	_heard_tile.clear()
	_heard_source.clear()
	_heard_error_dm.clear()
	_heard_turns_left.clear()


## One integer standing for everything this side has heard, for a replay or determinism check.
## `Rng.fnv1a` for the reason `SideKnowledge` uses it: `String.hash()` is not promised stable across
## engine versions.
##
## Order-sensitive on purpose. Two sides that heard the same two noises in different orders hold
## genuinely different lists — `add` appends — and a fingerprint that hid that would hide a real
## divergence in the order events were emitted.
func fingerprint() -> int:
	var parts := PackedStringArray()
	parts.append("snd%d" % side)
	for k: int in _heard_tile.size():
		parts.append("h%d t%d s%d e%d l%d" % [
			k, _heard_tile[k], _heard_source[k], _heard_error_dm[k], _heard_turns_left[k]
		])
	return Rng.fnv1a("\n".join(parts))
