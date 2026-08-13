class_name MatchState
extends RefCounted

## Who is on the board, whose turn it is, and which unit is selected.
##
## Iteration 1 is hot-seat: two units a side, side-alternating, and the player drives both sides
## because there is no AI yet (docs/decisions/0012). Ending a turn hands control over rather than
## triggering anything.
##
## Pure data, like everything in `sim/`. The view layer reads this and follows it; it never reaches
## back. Selection lives here rather than in `PlayerController` so that "which unit is selected"
## and "whose turn is it" cannot disagree — the controller used to hold a `_selected: bool` that
## nothing read, which is what happens when that state has no owner.


var units: Array[UnitState] = []
var turn: int = 1
var active_side: int = 1
var side_count: int = 2
## Index into `units`, or -1 when nothing is selected.
var selected: int = -1

## One contact list per side, indexed `side - 1` — docs/decisions/0024. Sides are 1-based everywhere
## else in this file and there is no side 0, so an array with a shift beats a dictionary whose key
## order `sim/` is not allowed to iterate anyway.
##
## Sound contacts get their own array beside this one rather than another state in `SideKnowledge`
## (0033). Two kinds of information, two containers.
var knowledge: Array[SideKnowledge] = []

## What each side has heard, indexed the same way — docs/decisions/0033 and 0037. The sibling
## promised above, and it is a genuinely different shape: `knowledge` is one slot per unit because a
## sighting is about a unit, and this is a list because a noise is not about anything.
##
## Not resized by `add_unit` for that reason. There is no per-unit slot here to grow.
var sound: Array[SideSound] = []

## Which side holds each objective, and for how many of its turns in a row — parallel to
## `MapData.objectives`. Zero means nobody. `Victory` owns the rules; this is where they are kept,
## because they are match state and the map is not.
var objective_holder: PackedInt32Array = PackedInt32Array()
var objective_held_turns: PackedInt32Array = PackedInt32Array()


static func create(sides: int = 2) -> MatchState:
	var m := MatchState.new()
	m.side_count = maxi(sides, 1)
	for s: int in range(1, m.side_count + 1):
		m.knowledge.append(SideKnowledge.create(s, 0))
		m.sound.append(SideSound.create(s))
	return m


func add_unit(u: UnitState) -> int:
	units.append(u)
	for k: SideKnowledge in knowledge:
		k.resize(units.size())
	return units.size() - 1


## One side's contact list, or null for a side that does not exist.
func knowledge_for(side: int) -> SideKnowledge:
	if side < 1 or side > knowledge.size():
		return null
	return knowledge[side - 1]


## One side's sound contacts, or null for a side that does not exist.
func sound_for(side: int) -> SideSound:
	if side < 1 or side > sound.size():
		return null
	return sound[side - 1]


## What `side` knows about `unit`, flattened for drawing. Null if it knows nothing.
##
## This is where the "a live contact is at the unit's tile, a ghost is at a remembered one" rule
## lives, and it lives in exactly one place — a call site that got it wrong would draw a ghost that
## followed its unit around, which is perfect intelligence wearing a dim color.
func contact(side: int, unit_index: int) -> Contact:
	var k: SideKnowledge = knowledge_for(side)
	var u: UnitState = unit(unit_index)
	if k == null or u == null or not k.knows_of(unit_index):
		return null

	var c := Contact.new()
	c.unit = unit_index
	c.state = k.state_of(unit_index)
	c.ghost_turns_left = k.ghost_turns_left(unit_index)
	c.unit_type = u.unit_type
	if c.is_live():
		c.tile = u.tile
		c.facing = u.facing
		c.turret = u.turret
	else:
		c.tile = k.ghost_tile(unit_index)
		c.facing = k.ghost_facing(unit_index)
		c.turret = c.facing
	return c


## Everything `side` knows about, in unit order. What the roster panel and the ghost markers draw.
func contacts(side: int) -> Array[Contact]:
	var out: Array[Contact] = []
	var k: SideKnowledge = knowledge_for(side)
	if k == null:
		return out
	for index: int in k.known_units():
		var c: Contact = contact(side, index)
		if c != null:
			out.append(c)
	return out


## Everything `side` has heard, in the order it heard it. What the sound markers draw.
##
## The counterpart to `contacts`, and deliberately not merged with it. A caller that wanted both would
## have to branch on which kind each entry was at the point of use, which is the check 0033 exists to
## make unaskable — you either ask for the layer that has positions or the layer that has guesses.
func sound_contacts(side: int) -> Array[SoundContact]:
	var out: Array[SoundContact] = []
	var s: SideSound = sound_for(side)
	if s == null:
		return out
	for k: int in s.count():
		var c := SoundContact.new()
		c.tile = s.tile_at(k)
		c.source = s.source_at(k)
		c.error_m = float(s.error_dm_at(k)) * 0.1
		c.turns_left = s.turns_left_at(k)
		out.append(c)
	return out


## Step the selection through **every** unit of the active side in deployment order, including ones
## that have already acted — docs/decisions/0032.
##
## The counterpart to `cycle`, not a replacement for it. `cycle` answers "what should I be doing
## next", which is the workflow key and skips units with nothing left. This answers "let me look at
## that one", which is a different question and the reason Steel Panthers had both. A single key that
## tried to be both is one that stops reaching half your force at exactly the point in a turn when
## you want to check on it.
func cycle_all(step: int) -> int:
	var side: PackedInt32Array = side_units(active_side)
	if side.is_empty():
		return -1

	var n: int = side.size()
	var at: int = -1
	for k: int in n:
		if side[k] == selected:
			at = k
			break

	var dir: int = 1 if step >= 0 else -1
	var base: int = at if at >= 0 else posmod(-dir, n)
	selected = side[posmod(base + dir, n)]
	return selected


func unit(index: int) -> UnitState:
	if index < 0 or index >= units.size():
		return null
	return units[index]


func selected_unit() -> UnitState:
	return unit(selected)


## Indices of one side's **living, on-board** units, in deployment order.
##
## A wreck is excluded here and deliberately still counted by `occupancy` and still found by
## `unit_at` — it stops being something you cycle to, spot, or shoot at, and goes on being something
## you cannot drive through. docs/decisions/0031. A wave that has not arrived (2g) is excluded for
## the mirror-image reason: it is nothing on the board at all, and `side_alive_count` is the
## question that still counts it.
func side_units(side: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in units.size():
		if units[k].side == side and units[k].alive and units[k].on_board:
			out.append(k)
	return out


## Living units of a side including reserves not yet on the board — 2g. The annihilation test and
## the hand-over both ask this rather than `side_units`: a side whose first wave died with two more
## waves coming is bloodied, not beaten, and skipping its turns would strand those waves off-board
## forever.
func side_alive_count(side: int) -> int:
	var n: int = 0
	for k: int in units.size():
		if units[k].side == side and units[k].alive:
			n += 1
	return n


## Every unit of a side including its wrecks, in deployment order. What a roster panel lists, and what
## a victory check counts losses from.
func side_roster(side: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in units.size():
		if units[k].side == side:
			out.append(k)
	return out


## Select a unit, if it belongs to the side whose turn it is. Returns false and changes nothing
## otherwise — an inactive side's units are inspectable on the map but not orderable.
func select(index: int) -> bool:
	var u: UnitState = unit(index)
	if u == null or u.side != active_side:
		return false
	selected = index
	return true


func is_selectable(index: int) -> bool:
	var u: UnitState = unit(index)
	return u != null and u.alive and u.side == active_side


## Step the selection through the active side's units, wrapping. Returns the new index, or -1 if
## the side has no units at all.
##
## Units that have already acted are skipped on the first sweep, so Tab walks the units still worth
## giving orders to. Once every one of them is done it falls back to plain wraparound, because a
## Tab that does nothing reads as a broken key rather than as a finished turn.
func cycle(step: int) -> int:
	var side: PackedInt32Array = side_units(active_side)
	if side.is_empty():
		return -1

	var n: int = side.size()
	var at: int = -1
	for k: int in n:
		if side[k] == selected:
			at = k
			break

	var dir: int = 1 if step >= 0 else -1
	# With nothing selected, start one step behind the direction of travel so the first hop lands
	# on the first unit rather than skipping it.
	var base: int = at if at >= 0 else posmod(-dir, n)

	for hop: int in range(1, n + 1):
		var cand: int = side[posmod(base + dir * hop, n)]
		if not units[cand].activated:
			selected = cand
			return cand

	selected = side[posmod(base + dir, n)]
	return selected


func mark_activated(index: int) -> void:
	var u: UnitState = unit(index)
	if u != null:
		u.activated = true


## Units on the active side that can still be given an order. Off-board reserves are not owed a
## decision — there is nothing to decide about a tank that has not arrived.
func remaining_on_side() -> int:
	var left: int = 0
	for k: int in units.size():
		var u: UnitState = units[k]
		if u.side == active_side and u.alive and u.on_board and not u.activated:
			left += 1
	return left


func all_activated() -> bool:
	return remaining_on_side() == 0


## Hand over to the next side that has any units, restore its movement points, and select its first
## unit that can still act.
##
## The side search is bounded by `side_count` and skips empty sides, so a match set up with only one
## side populated still advances the turn counter and refills movement points instead of stalling.
## Takes `cfg` because `begin_turn` does — the per-turn allowances it restores are tunables. Nothing
## here reads the map, so the knowledge sweep that also belongs at a turn boundary lives one layer up
## in `ActionResolver.end_turn`, which is the object that can see the ground.
func end_turn(cfg: Config) -> void:
	for k: int in units.size():
		if units[k].side == active_side:
			units[k].activated = true

	for _hop: int in side_count:
		active_side += 1
		if active_side > side_count:
			active_side = 1
			turn += 1
		# Alive including off-board reserves, not `side_units` — a side waiting on its next wave
		# must keep getting turns or the wave can never arrive (2g).
		if side_alive_count(active_side) > 0:
			break

	# Only the side taking over ages its ghosts, and only as it takes over. A ghost's life is
	# measured in *that side's* turns — "my information is two turns old" — which is the length a
	# player can actually plan around. Ageing every side on every hand-over would make
	# `ghost_turns: 2` mean one full round in a two-sided match and half a round in a four-sided one,
	# and nothing in the data file would say so.
	var taking_over: SideKnowledge = knowledge_for(active_side)
	if taking_over != null:
		taking_over.decay()

	# The sound layer ages here too, and charged to the same side for the same reason: a contact's life
	# is measured in *that side's* turns. It is a separate call rather than a line inside `decay`
	# because the two containers age on separate schedules by design (0033) — `sound.turns` is 1 and
	# `spotting.ghost_turns` is 2, and folding them together is how those quietly become one number.
	var listening: SideSound = sound_for(active_side)
	if listening != null:
		listening.decay()

	for k2: int in units.size():
		if units[k2].side == active_side:
			units[k2].begin_turn(cfg)

	selected = -1
	var side: PackedInt32Array = side_units(active_side)
	if not side.is_empty():
		selected = side[0]


## The unit standing on a tile, or -1. Linear over a handful of units; there is no index to keep in
## sync and nothing calls this in a hot loop.
func unit_at(tile: int) -> int:
	for k: int in units.size():
		if units[k].tile == tile:
			return k
	return -1


## Where units are standing, as the dynamic blocker overlay the pathfinder takes.
##
## `exclude_unit` is the one being given the order: a unit must not block itself, or every path it
## could take begins on an impassable tile and it can never move again.
##
## Every occupied tile is a hard block, friend or enemy — nothing drives through anything in
## iteration 1. Whether friendly units should be passable is a real rule with a real answer, and it
## belongs with combat in iteration 2 rather than being decided here by accident.
## `tile_count` is the map's `n` rather than `Grid.COUNT`: the tests run quarter-scale maps, and an
## overlay sized to the shipping grid would index past the end of a small one.
func occupancy(tile_count: int, exclude_unit: int = -1) -> PackedByteArray:
	var out := PackedByteArray()
	if units.is_empty():
		return out
	out.resize(tile_count)
	for k: int in units.size():
		if k == exclude_unit:
			continue
		var t: int = units[k].tile
		if t >= 0 and t < tile_count:
			out[t] = 1
	return out
