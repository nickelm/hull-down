class_name UnitState
extends RefCounted

## A unit as the simulation sees it: where it is, which way it points, and what it has left.
## No rendering, no node, no animation — the view in game/ reads this and follows it.

var tile: int = 0
## The **hull's** heading. Armor is computed from it, changing it costs movement points, and it is
## half of the pathfinding search state — docs/decisions/0008 and 0027.
var facing: int = Grid.N
## The turret's bearing, **absolute** and in the same 0-7 numbering as the hull, not relative to it.
##
## Absolute is the load-bearing half of 0027. A relative turret swings with the hull, so laying an
## ambush down a road and then turning the hull to present frontal armor would silently point the
## gun at the sky. Overwatch aims at a *place*, and a rule where the place moves when you shuffle is
## a rule nobody can plan around.
var turret: int = Grid.N
var unit_type: StringName = &"medium"
## Which traversal graph this unit moves on. Every unit in iteration 1 is tracked; the field exists
## so nothing has to be retrofitted when something that is not turns up.
var movement_class: int = MovementClass.REFERENCE
var mp_max: int = 220
var mp_left: int = 220
var side: int = 1
## Whether this unit has already acted this turn. Advisory in iteration 1 — it drives the "who has
## not acted" indicator and the order Tab cycles in, and nothing else. The two-actions-per-unit
## budget from docs/decisions/0003 arrives with combat in iteration 2.
var activated: bool = false

## Movement points spent **driving and turning** this turn. Read by `Spotting`, which ramps how far
## away a unit can be seen from how hard it drove — a tank that crept one tile is nearly as quiet as
## one that never moved.
##
## Accumulated by `EventApplier` rather than derived from `mp_max - mp_left`, and that is not a
## duplicate: firing forfeits the remainder of the action in progress (0021), and a unit that stood
## still and shot has spent movement points without having made a sound worth widening a spotting
## range over. It is already revealed, by `fired_this_turn`, for a better reason.
var mp_moved: int = 0
## Fired this turn. A muzzle flash reveals the firer to anything with line of sight, at any range,
## and the flag is cleared in `begin_turn` — so it survives the enemy's entire turn, which is what
## makes firing a commitment rather than a flicker.
var fired_this_turn: bool = false

## The bearing overwatch is laid along, or -1 for none. Survives the enemy's turn — that is when it
## fires — and is cleared in `begin_turn`, alongside the reveal flag and for the same reason.
var overwatch_dir: int = -1
var overwatch_shots_left: int = 0

## Still fighting. A destroyed unit stays in `units` at its own index — identity is positional, and
## compacting the array would renumber every contact every side holds — but it stops being something
## the turn cycles to, spots, or shoots at. Its tile stays blocked and gains cover: it is a wreck now,
## not an absence. docs/decisions/0031.
var alive: bool = true
## Millimeters shot off each plate, indexed by `Armor.Facing`. Permanent — armor never regenerates
## (0004), so this only ever rises and `Armor.current_mm` only ever falls.
##
## An array rather than five named fields because `Armor.Facing` indexes it, and an enum that
## indexes named fields is an enum that will be wrong once.
var shred_mm: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0])
## Turns of shaken crew left. The temporary half of 0004's no-null-results rule, and what makes a
## light tank's fast small gun worth firing at a heavy it cannot hurt.
var shaken_turns: int = 0
## Component criticals — exactly two in iteration 2, and neither is recoverable.
var immobilised: bool = false
var gun_damaged: bool = false
## Rounds left. From `gun.ammo`, falling back to `combat.default_ammo`.
var ammo: int = 0
## Crossed a rough transition this turn, so it cannot fire — `docs/design/rules.md` §2.4, computed as
## `PathResult.blocks_firing` since iteration 1 and finally read by something.
var fire_blocked: bool = false

## Dug in at deployment — 2f, docs/decisions/0041. Counts as hull down to every observer and gun
## regardless of terrain, and multiplies concealment on top of the ground's own. Cleared by the
## first `STEP` or `TURN` the unit ever applies, permanently — the position was prepared, and a
## tank cannot take a prepared position with it.
var entrenched: bool = false

## On the board at all — 2g. A wave that has not arrived is alive, counts against annihilation,
## and is nothing else: not an observer, not a target, not a blocker, not orderable. `tile` is -1
## while this is false, so anything positional that forgot to check answers about a tile that does
## not exist rather than about a stale one.
var on_board: bool = true
## The turn this unit's wave enters, or 0 for the starting force.
var arrival_turn: int = 0
## The map edge it enters from, as a Grid cardinal, or -1.
var arrival_edge: int = -1


static func create(md: MapData, cfg: Config, start_tile: int, type_name: String) -> UnitState:
	var u := UnitState.new()
	u.tile = start_tile
	u.unit_type = StringName(type_name)

	var data: Dictionary = cfg.unit(type_name)
	var move: Dictionary = data.get("movement", {})
	u.mp_max = int(move.get("mp", cfg.i("movement.default_mp", 220)))
	u.mp_left = u.mp_max

	# An unrecognized class name falls back to the reference rather than to index 0 by accident —
	# they are the same today, and saying so is what stops that being a coincidence later.
	var found: int = cfg.class_by_name(str(move.get("class", "tracked")))
	u.movement_class = found if found >= 0 else MovementClass.REFERENCE
	u.turret = u.facing

	var gun: Dictionary = data.get("gun", {})
	u.ammo = int(gun.get("ammo", cfg.i("combat.default_ammo", 12)))
	u.shred_mm = PackedInt32Array([0, 0, 0, 0, 0])

	# The per-turn allowances start filled rather than empty. `begin_turn` is what refills them, and
	# it does not run until the *second* turn — so a unit built without this would spend the whole
	# first turn of a match unable to lay overwatch, for no reason a player could see.
	u.overwatch_shots_left = cfg.i("combat.overwatch_shots", 1)
	return u


## The nearest bearing to `bearing` that the turret can hold on a hull pointing `hull`.
##
## Returns `bearing` unchanged when it is already inside the arc. Outside it, the turret is dragged
## the short way round to the arc's edge — the short way, because a turret that traversed the long way
## to reach the same place would cross the arc it was just told it could not leave.
##
## An exact reversal has no short way; both directions are equally far. The signed difference below
## resolves that tie anticlockwise, consistently, because a tie broken differently on two runs is a
## determinism bug that only appears when a tank is ordered to turn completely round.
static func clamp_turret(hull: int, bearing: int, arc_steps: int) -> int:
	var arc: int = clampi(arc_steps, 0, 4)
	if Grid.turn_steps(hull, bearing) <= arc:
		return bearing & 7
	# posmod(d + 4, 8) - 4 maps the difference into [-4, 3], so an exact reversal lands on -4.
	var signed: int = posmod(bearing - hull + 4, 8) - 4
	return posmod(hull + (arc if signed > 0 else -arc), 8)


## Takes `cfg` because the per-turn allowances it restores are tunables, not constants. That ripples
## out to `MatchState.end_turn(cfg)` and everything that calls it, which is the price of the reveal
## flag having exactly one place it can be cleared.
func begin_turn(cfg: Config) -> void:
	mp_left = mp_max
	activated = false
	mp_moved = 0
	fired_this_turn = false
	overwatch_dir = -1
	overwatch_shots_left = cfg.i("combat.overwatch_shots", 1)
	fire_blocked = false
	# A shake wears off; shred does not. That asymmetry is the whole of 0004's "no null results":
	# one outcome is permanent progress and the other is a window.
	shaken_turns = maxi(shaken_turns - 1, 0)


## Movement points one action buys — docs/decisions/0014. Derived rather than stored: a second
## budget that can only ever be `mp_left / per_action` is a quantity pretending to be state, and the
## kind of thing that goes out of sync.
func action_mp(cfg: Config) -> int:
	var actions: int = maxi(cfg.i("movement.actions_per_turn", 2), 1)
	return maxi(mp_max / actions, 1)


## Movement points left in the action **already in progress** — docs/decisions/0021.
##
## This is what the overlay's near band is drawn at, and it is not `action_mp`. A unit that has
## driven four tiles of a five-tile action has one tile of that action left, not five: the action was
## begun and paying for it again is not on offer. Measuring a fresh action's worth from wherever the
## tank now stands hands it back the movement it just spent, which reads as though a short move cost
## nothing.
##
## Still derived rather than stored, which is the point 0014 was making. Movement fills the action
## points in order, so how far into the current one we are follows from how much has been spent:
##
##     spent    = mp_max - mp_left
##     index    = spent / per_action        (which action we are inside)
##     boundary = (index + 1) * per_action  (where it ends)
##
## and what remains of it is `boundary - spent`, clamped to what the unit actually has. When that
## clamp bites there is under one action left in the whole turn, the near and far bands coincide, and
## the overlay correctly draws one region instead of two.
func near_mp(cfg: Config) -> int:
	var per: int = action_mp(cfg)
	var spent: int = mp_max - mp_left
	var boundary: int = (spent / per + 1) * per
	return clampi(boundary - spent, 0, mp_left)


## Spend whatever is left of the action in progress without moving.
##
## The counterpart of `near_mp`, and the price of it. If a part-spent action can be finished later,
## then something that costs a *whole* action point — shooting, in iteration 2 — has to forfeit the
## fraction of the current one that was never used. Otherwise a unit banks slivers of movement across
## actions and the budget stops being two actions at all.
##
## Nothing calls this yet, because movement is the only action iteration 1 has. It is here because
## the rule is decided (0021), and a decided rule that is not written down is one that gets
## rediscovered as a bug.
func commit_action(cfg: Config) -> void:
	mp_left = mp_after_action(cfg)


## What `commit_action` *would* leave, without leaving it.
##
## Firing has to put the post-forfeit figure on its `FIRE` event as an absolute snapshot, so that
## applying the stream is idempotent (0026) and so that the preview can show the price before the
## player commits. Both of those want the arithmetic without the mutation, and having them recompute
## it is how the two drift.
func mp_after_action(cfg: Config) -> int:
	var per: int = action_mp(cfg)
	var spent: int = mp_max - mp_left
	var boundary: int = (spent / per + 1) * per
	return maxi(mp_max - boundary, 0)


## Whether the unit can still do anything. A unit that cannot afford even the cheapest step is done
## whether or not it has been marked, so this is what the turn tracking actually asks.
func can_act(cfg: Config) -> bool:
	return not activated and mp_left >= cfg.i("movement.base_ortho", 10)


## There is deliberately no `apply(path)` here any more.
##
## `MoveAction.commit` walks an action's event list into the state and is the only thing that moves
## a unit — docs/decisions/0022. Two ways to move one is how they drift, and the version that lived
## here could only ever express "it ended up over there", which is a summary rather than an account
## and has nowhere to put an interruption partway along.


## Whether the gun can be brought to bear on a bearing at all.
##
## The question is about the *hull*, not about where the turret currently points: traversing is free
## and unlimited within the arc, so anything inside the arc is already aimable and anything outside it
## needs the tank to turn — which costs movement and is a different decision. This is what
## `FireAction.legality` asks, and it is why the turret's current bearing does not appear in it.
func can_bear_on(dir: int, cfg: Config) -> bool:
	if dir < 0:
		return false
	return Grid.turn_steps(facing, dir) <= cfg.i("combat.turret_arc_steps", 3)


func turret_height_m(cfg: Config) -> float:
	var dims: Dictionary = cfg.unit(String(unit_type)).get("dimensions", {})
	return float(dims.get("turret_h_m", cfg.f("visibility.turret_h_m", 2.6)))


func hull_height_m(cfg: Config) -> float:
	var dims: Dictionary = cfg.unit(String(unit_type)).get("dimensions", {})
	return float(dims.get("hull_h_m", cfg.f("visibility.hull_h_m", 1.4)))
