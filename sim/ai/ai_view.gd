class_name AiView
extends RefCounted

## Everything one side's AI is allowed to know — docs/decisions/0038.
##
## The exact analogue of `ViewState` for the renderer (0034), and it exists for the same reason: the
## rule "the AI reads only its own side's knowledge" is only enforceable if there is one object that
## *is* that knowledge, and the policy is handed that object and nothing else. A policy holding a
## `MatchState` is one field access away from perfect intelligence forever, however honest its
## author meant to be.
##
## What is exposed, and why it is fair:
##
##   * the map, the config and the objectives — the briefing. Terrain is public knowledge.
##   * the side's own units, as live `UnitState`s — a side knows everything about its own tanks.
##   * enemies as `Contact`s and `SoundContact`s, flattened by `MatchState.contact` — a live
##     contact's tile is true *because* it is seen, a ghost's is a memory, and an unspotted enemy
##     is simply absent. The view cannot say more because it does not hold more.
##   * planning services delegated to the resolver — `plan_move` and `preview_fire` are pure, and
##     `preview_fire` refuses `NOT_VISIBLE` before it computes anything, so a probe at an unseen
##     enemy learns only that the shot is refused.
##
## Every internal field is underscore-prefixed, and the scan in `tests/test_ai_scaffold.gd` bans
## `._` reaches from policy code — GDScript has no private, so the convention is load-bearing and
## the test is what makes it a wall rather than a hint.

var side: int = 0

var _resolver: ActionResolver
var _state: MatchState


static func create(resolver: ActionResolver, for_side: int) -> AiView:
	var v := AiView.new()
	v._resolver = resolver
	v._state = resolver.state
	v.side = for_side
	return v


## The ground. Public knowledge — both sides were issued the same map.
func map() -> MapData:
	return _resolver.md


func config() -> Config:
	return _resolver.cfg


func objectives() -> PackedInt32Array:
	return _resolver.md.objectives


func turn() -> int:
	return _state.turn


## Indices of this side's living units, in deployment order.
func my_units() -> PackedInt32Array:
	return _state.side_units(side)


## One of this side's own units, or null — including null for every enemy. A side knows its own
## tanks completely; what it knows about anyone else's comes through `contacts()` and nothing else.
func my_unit(index: int) -> UnitState:
	var u: UnitState = _state.unit(index)
	if u == null or u.side != side:
		return null
	return u


## Everything this side knows about the enemy, in unit order. Live contacts, then ghosts — an
## unspotted enemy produces no entry, which is the whole fog of war stated as an absence.
func contacts() -> Array[Contact]:
	return _state.contacts(side)


## Everything this side has heard — position guesses, no identities. docs/decisions/0033 and 0037.
func sound_contacts() -> Array[SoundContact]:
	return _state.sound_contacts(side)


## Whether this side currently sees `unit_index`. The question that gates ordering a shot.
func sees(unit_index: int) -> bool:
	var k: SideKnowledge = _state.knowledge_for(side)
	return k != null and k.sees(unit_index)


## Cost to reach every tile for one of this side's units, -1 where unreachable.
func reachable(unit_index: int) -> PackedInt32Array:
	if my_unit(unit_index) == null:
		return PackedInt32Array()
	return _resolver.reachable(unit_index)


## What a move would be. Pure — a policy may call this while scoring candidates.
func plan_move(
	unit_index: int, goal_tile: int, reach: PackedInt32Array = PackedInt32Array()
) -> ActionResult:
	if my_unit(unit_index) == null:
		var r := ActionResult.new()
		r.unit = unit_index
		r.status = ActionResult.Status.NO_UNIT
		return r
	return _resolver.plan_move(unit_index, goal_tile, reach)


## What a shot would be. Pure, and it refuses `NOT_VISIBLE` before computing a single field, so a
## policy probing an unseen enemy gets a refusal and no geometry.
func preview_fire(unit_index: int, target: int) -> FireForecast:
	if my_unit(unit_index) == null:
		var out := FireForecast.new()
		out.status = ActionResult.Status.NO_UNIT
		return out
	return _resolver.preview_fire(unit_index, target)


## Whether one of this side's units may lay overwatch along `dir`, as a Status.
func overwatch_legality(unit_index: int, dir: int) -> int:
	if my_unit(unit_index) == null:
		return ActionResult.Status.NO_UNIT
	return Overwatch.legality(_resolver.md, _resolver.cfg, _state, unit_index, dir)


## Exposure of a tile as seen from another tile — pure map geometry, usable on any pair the policy
## can name. Asking about tiles is fair: the policy can only name tiles it got from its own units,
## its contacts, or the map, and the ground between two named points is knowable by anyone with the
## map and a protractor.
func exposure_between_tiles(observer_tile: int, target_tile: int) -> int:
	return Los.classify(_resolver.md, _resolver.cfg, observer_tile, target_tile)


## Concealment multiplier for a movement class standing on a tile. Terrain data — public.
func concealment_at(tile: int, movement_class: int) -> float:
	var md: MapData = _resolver.md
	return _resolver.cfg.concealment(movement_class, md.terrain[tile])


func dist_m(a: int, b: int) -> float:
	return _resolver.md.dist_m(a, b)


## Straight-line bearing from one tile toward another, 0-7, or -1 for the same tile.
func bearing_between(from_tile: int, to_tile: int) -> int:
	return Armor.bearing(_resolver.md, from_tile, to_tile)
