class_name SideKnowledge
extends RefCounted

## What one side knows about the enemy — docs/decisions/0024.
##
## Knowledge is **side-level**. If one of your tanks sees something, your whole side sees it. Per-unit
## knowledge is more realistic and it doubles the state, complicates every query, and asks the player
## to remember which of their tanks is looking at what. Side-level is the version anyone can hold in
## their head.
##
## A contact is in one of three states. `SEEN` means some living unit of this side can see it right
## now. `GHOST` means it was seen, is not any more, and the side remembers where it was for
## `spotting.ghost_turns` turns. `UNKNOWN` means nothing — never seen, or the ghost has gone cold.
##
## **A `SEEN` contact's position is not stored here.** It is, by definition, the unit's actual tile,
## and duplicating it would be a second copy that can go stale — the objection 0014 raised to
## `ap_left`. Only a ghost needs a memory, and it is written exactly once, at the moment contact is
## lost. That is also what makes the model replay-safe: a moving unit that stays visible produces no
## knowledge change at all, so there is nothing for the event stream to have to record.
##
## Structure-of-arrays, and the fields are prefixed `_visual_` on purpose. Sound contacts (iteration
## 2.5) are a **sibling class** with their own arrays and their own slot on `MatchState`, never a
## fourth value in `State` — docs/decisions/0033. A marker built from a noise is not a fainter version
## of a marker built from a sighting, and the day the two share an enum is the day the UI conflates
## them.

enum State {
	UNKNOWN = 0,
	SEEN = 1,
	GHOST = 2,
}

var side: int = 0

var _visual_state: PackedByteArray = PackedByteArray()
## Where the contact was when it was lost. Meaningful only while the state is `GHOST`.
var _visual_tile: PackedInt32Array = PackedInt32Array()
var _visual_facing: PackedInt32Array = PackedInt32Array()
var _visual_ghost_left: PackedInt32Array = PackedInt32Array()


static func create(for_side: int, unit_count: int) -> SideKnowledge:
	var k := SideKnowledge.new()
	k.side = for_side
	k.resize(unit_count)
	return k


## Grow to cover `unit_count` units, preserving what is already known. Units are only ever appended
## to `MatchState`, so growing is the only case; shrinking would renumber every contact.
func resize(unit_count: int) -> void:
	var was: int = _visual_state.size()
	if unit_count <= was:
		return
	_visual_state.resize(unit_count)
	_visual_tile.resize(unit_count)
	_visual_facing.resize(unit_count)
	_visual_ghost_left.resize(unit_count)
	for k: int in range(was, unit_count):
		_visual_state[k] = State.UNKNOWN
		_visual_tile[k] = -1
		_visual_facing[k] = -1
		_visual_ghost_left[k] = 0


func size() -> int:
	return _visual_state.size()


func state_of(u: int) -> int:
	if u < 0 or u >= _visual_state.size():
		return State.UNKNOWN
	return _visual_state[u]


## Visible right now. The question that gates firing.
func sees(u: int) -> bool:
	return state_of(u) == State.SEEN


## Visible or remembered. The question that gates drawing a marker, and — once there is speculative
## fire — the question that gates shooting at a place rather than at a tank.
func knows_of(u: int) -> bool:
	return state_of(u) != State.UNKNOWN


## Where a **ghost** was last seen, or -1. Deliberately not answered for a `SEEN` contact: that one's
## position is the unit's own, and asking this instead would be reading a copy.
func ghost_tile(u: int) -> int:
	if state_of(u) != State.GHOST:
		return -1
	return _visual_tile[u]


func ghost_facing(u: int) -> int:
	if state_of(u) != State.GHOST:
		return -1
	return _visual_facing[u]


func ghost_turns_left(u: int) -> int:
	if state_of(u) != State.GHOST:
		return 0
	return _visual_ghost_left[u]


## Every unit this side has any information about, ascending. Sorted by construction rather than by
## sorting, because `sim/` must not iterate a `Dictionary`'s key order and this is the same rule one
## container down.
func known_units() -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in _visual_state.size():
		if _visual_state[k] != State.UNKNOWN:
			out.append(k)
	return out


func seen_units() -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in _visual_state.size():
		if _visual_state[k] == State.SEEN:
			out.append(k)
	return out


## Record that this side can see `u`. Returns true only when that is *news* — a contact that was
## already `SEEN` returns false.
##
## The return value is what drives `SPOT` emission, so a second call for a contact already in hand
## must be silent or the stream fills with duplicate reveals and the presentation layer flashes a
## marker that never went away.
func mark_seen(u: int) -> bool:
	if u < 0 or u >= _visual_state.size():
		return false
	if _visual_state[u] == State.SEEN:
		return false
	_visual_state[u] = State.SEEN
	_visual_ghost_left[u] = 0
	return true


## Record that contact with `u` has been lost, freezing where it was. Returns true only if it had
## been `SEEN` — losing something never held is not an event.
##
## The tile and facing are passed in rather than read, because this is the one moment the position
## has to be *copied* out of the live unit and into memory, and the caller is the thing that knows
## which position it means.
func mark_lost(u: int, tile: int, facing: int, ghost_turns: int) -> bool:
	if u < 0 or u >= _visual_state.size():
		return false
	if _visual_state[u] != State.SEEN:
		return false
	if ghost_turns <= 0:
		_visual_state[u] = State.UNKNOWN
		_visual_tile[u] = -1
		_visual_facing[u] = -1
		_visual_ghost_left[u] = 0
		return true
	_visual_state[u] = State.GHOST
	_visual_tile[u] = tile
	_visual_facing[u] = facing
	_visual_ghost_left[u] = ghost_turns
	return true


## Age every ghost by one turn and return the ones that went cold. Called once at the start of a
## turn, never per action — a ghost decays in *turns*, which is what makes "two turns" a length a
## player can plan around rather than a function of how much anyone happened to move.
func decay() -> PackedInt32Array:
	var expired := PackedInt32Array()
	for k: int in _visual_state.size():
		if _visual_state[k] != State.GHOST:
			continue
		_visual_ghost_left[k] -= 1
		if _visual_ghost_left[k] <= 0:
			_visual_state[k] = State.UNKNOWN
			_visual_tile[k] = -1
			_visual_facing[k] = -1
			_visual_ghost_left[k] = 0
			expired.append(k)
	return expired


## One integer standing for everything this side knows, so a determinism or replay check is a
## comparison rather than an element-wise walk. `Rng.fnv1a` for the reason `ActionResult` uses it:
## `String.hash()` is not promised stable across engine versions.
func fingerprint() -> int:
	var parts := PackedStringArray()
	parts.append("side%d" % side)
	for k: int in _visual_state.size():
		parts.append("u%d s%d t%d f%d g%d" % [
			k, _visual_state[k], _visual_tile[k], _visual_facing[k], _visual_ghost_left[k]
		])
	return Rng.fnv1a("\n".join(parts))
