extends TestCase

## The play loop: the free turret traverse, the two cycling keys, contacts as the view reads them, and
## the force each side is handed — docs/decisions/0035, and 0024 for the contact half.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, facing: int = Grid.E) -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), "medium")
	u.side = side
	u.facing = facing
	u.turret = facing
	return u


func _state(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 3, 3))
	m.add_unit(_unit(md, 1, 3, 9))
	m.add_unit(_unit(md, 1, 3, 15))
	m.add_unit(_unit(md, 2, 20, 20))
	m.selected = 0
	return m


func _resolver(md: MapData, m: MatchState) -> ActionResolver:
	return ActionResolver.new(md, cfg, m)


# --- the free turret traverse ---------------------------------------------------------------------


## The bearing one notch clockwise of where the gun currently points.
func _one_notch(m: MatchState, unit_index: int, step: int) -> int:
	return posmod(m.unit(unit_index).turret + step, 8)


## Free means free: no movement points, and it does not read as movement to spotting either. A crew
## traversing the gun is not the tank that sprinted across a field.
func test_traversing_costs_nothing_at_all() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	var mp: int = u.mp_left

	var r: ActionResult = _resolver(md, m).resolve_turret(0, _one_notch(m, 0, 1))
	assert_true(r.ok(), "the traverse was refused: %d" % r.status)
	assert_eq(u.mp_left, mp, "traversing spent movement points")
	assert_eq(u.mp_moved, 0, "traversing read as movement to spotting")
	assert_eq(r.cost(), 0, "the stream charged for a free traverse")


## And it moves the turret without moving the hull. That split is the whole of 0035: what you present
## to a gun is settled by where you drove, and traversing must not touch it.
func test_traversing_swings_the_gun_and_leaves_the_hull_alone() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	u.facing = Grid.N
	u.turret = Grid.N

	_resolver(md, m).resolve_turret(0, Grid.NE)
	assert_eq(u.turret, Grid.NE, "a clockwise order did not swing the gun one notch")
	assert_eq(u.facing, Grid.N, "traversing the turret turned the hull")

	_resolver(md, m).resolve_turret(0, Grid.NW)
	assert_eq(u.turret, Grid.NW, "an anticlockwise order did not swing the gun back past north")
	assert_eq(u.facing, Grid.N, "traversing the turret turned the hull")


## Unlimited within the arc — docs/decisions/0035. There is no per-turn allowance and deliberately no
## tunable for one: the arc already bounds where the gun can point, and a crew traverses as often as it
## likes in the time a turn represents.
func test_traversing_is_not_rationed() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	m.unit(0).facing = Grid.N
	m.unit(0).turret = Grid.N

	for bearing: int in [Grid.NE, Grid.E, Grid.NE, Grid.N, Grid.NW, Grid.W]:
		var r: ActionResult = _resolver(md, m).resolve_turret(0, bearing)
		assert_true(r.ok(), "a traverse was rationed: bearing %d refused with %d" % [bearing, r.status])
	assert_eq(m.unit(0).turret, Grid.W, "the last traverse in the run did not land")


## The case the rule exists for. A tank with nothing left is exactly the tank that needs this, so
## being spent must not be a refusal.
func test_a_spent_unit_can_still_traverse() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	u.mp_left = 0
	u.activated = true

	var r: ActionResult = _resolver(md, m).resolve_turret(0, _one_notch(m, 0, 1))
	assert_true(r.ok(), "a unit at zero movement points could not traverse: %d" % r.status)
	assert_true(u.activated, "traversing un-marked a unit that had already acted")


## The other half of the same sentence, and the half 0032 had backwards: at zero movement points the
## hull does not move. There is no free hull step any more, so the only way to turn is to pay.
func test_a_spent_unit_cannot_turn_its_hull() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	var was: int = u.facing
	u.mp_left = 0

	# The cheapest possible hull movement: one tile, straight ahead.
	var ahead: int = md.idx(md.tx(u.tile) + Grid.DX[u.facing], md.ty(u.tile) + Grid.DY[u.facing])
	var r: ActionResult = _resolver(md, m).resolve_move(0, ahead)

	assert_false(r.ok(), "a unit with no movement points moved its hull anyway")
	assert_eq(u.facing, was, "a refused move turned the hull")


func test_a_unit_of_the_idle_side_cannot_traverse() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).resolve_turret(3, Grid.N)
	assert_false(r.ok(), "an idle side's unit traversed its gun")
	assert_eq(r.status, ActionResult.Status.WRONG_SIDE, "the refusal gave the wrong reason")


## A watching tank re-lays its watch along the new bearing rather than losing it — docs/decisions/0035.
##
## 0032's free hull turn *canceled* overwatch, because a free re-aim would have made "overwatch costs
## your whole turn" meaningless. That does not carry over: the bearing a unit watches down **is** where
## its gun points, so leaving the two disagreed would be a bug rather than a price.
func test_traversing_relays_the_watch_rather_than_cancelling_it() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	u.facing = Grid.N
	u.turret = Grid.N
	u.overwatch_dir = Grid.N
	var shots: int = u.overwatch_shots_left

	var r: ActionResult = _resolver(md, m).resolve_turret(0, Grid.NE)
	assert_true(r.ok(), "the traverse was refused")
	assert_eq(u.overwatch_dir, Grid.NE, "the watch did not follow the gun it is laid along")
	assert_eq(u.overwatch_shots_left, shots, "re-aiming a watch cost it a shot")

	var relaid: bool = false
	for e: ActionEvent in r.events:
		if e.kind == ActionEvent.Kind.WATCH:
			relaid = true
			assert_eq(e.facing, Grid.NE, "the re-lay in the stream names the wrong bearing")
	assert_true(relaid, "the watch moved but the stream does not say so")


## A unit that was not watching emits no `WATCH` at all. A stream must not carry events for things that
## did not happen, or a replay narrates them.
func test_a_unit_that_was_not_watching_emits_no_watch_event() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).resolve_turret(0, _one_notch(m, 0, 1))
	for e: ActionEvent in r.events:
		assert_ne(e.kind, ActionEvent.Kind.WATCH, "a watch was laid for overwatch nobody had")


## The arc is a property of the mounting, measured from the hull, and free does not mean unbounded —
## docs/decisions/0027. Dead astern is the one bearing a turret cannot reach without turning the tank.
func test_the_gun_cannot_be_laid_outside_the_arc() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	var arc: int = cfg.i("combat.turret_arc_steps", 3)
	u.facing = Grid.N
	u.turret = Grid.N

	var astern: int = posmod(Grid.N + 4, 8)
	assert_gt(float(Grid.turn_steps(Grid.N, astern)), float(arc),
		"the fixture's arc reaches dead astern, so this proves nothing")

	var r: ActionResult = _resolver(md, m).resolve_turret(0, astern)
	assert_false(r.ok(), "the gun was laid straight backwards over the engine deck")
	assert_eq(r.status, ActionResult.Status.OUT_OF_ARC, "the refusal gave the wrong reason")
	assert_eq(u.turret, Grid.N, "a refused traverse moved the gun anyway")


## An order that changes nothing is refused rather than emitted as an empty account of having happened.
func test_laying_the_gun_where_it_already_points_is_refused() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).resolve_turret(0, m.unit(0).turret)
	assert_false(r.ok(), "an order that changed nothing was accepted")
	assert_eq(r.status, ActionResult.Status.SAME_TILE, "the refusal gave the wrong reason")
	assert_eq(r.events.size(), 0, "a refused traverse produced events")


## Applied twice, it must land in the same place — every arm of `EventApplier` assigns an absolute
## snapshot rather than adjusting, precisely so this holds (0026).
func test_replaying_a_traverse_is_idempotent() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	u.facing = Grid.N
	u.turret = Grid.N
	u.overwatch_dir = Grid.N

	var r: ActionResult = _resolver(md, m).resolve_turret(0, Grid.NE)
	assert_true(r.ok(), "the traverse was refused")
	var turret: int = u.turret
	var facing: int = u.facing
	var watch: int = u.overwatch_dir
	var mp: int = u.mp_left

	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(u.turret, turret, "replaying the traverse swung the gun again")
	assert_eq(u.facing, facing, "replaying the traverse turned the hull")
	assert_eq(u.overwatch_dir, watch, "replaying the traverse moved the watch again")
	assert_eq(u.mp_left, mp, "replaying the traverse charged for it")


# --- the two cycling keys -------------------------------------------------------------------------

## Tab answers "what should I do next" and skips the finished. The roster key answers "let me look at
## that one" and skips nothing. A single key trying to be both stops reaching half the force at
## exactly the point in a turn when you want to check on it.
func test_the_roster_key_reaches_units_tab_has_finished_with() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	m.unit(1).activated = true

	m.selected = 0
	assert_eq(m.cycle(1), 2, "Tab landed on a unit that has already acted")

	m.selected = 0
	assert_eq(m.cycle_all(1), 1, "the roster key skipped a unit that had acted")
	assert_eq(m.cycle_all(1), 2, "the roster key did not carry on in deployment order")
	assert_eq(m.cycle_all(1), 0, "the roster key did not wrap")
	assert_eq(m.cycle_all(-1), 2, "the roster key does not run backwards")


## Neither key ever leaves the active side, whichever of them is pressed.
func test_neither_cycling_key_reaches_the_other_side() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	for _hop: int in 8:
		assert_eq(m.unit(m.cycle_all(1)).side, m.active_side, "the roster key crossed sides")
		assert_eq(m.unit(m.cycle(1)).side, m.active_side, "Tab crossed sides")


## Even with every unit finished, the roster key still moves. A key that does nothing reads as broken
## rather than as a finished turn — the same argument `cycle` makes for its fallback sweep.
func test_the_roster_key_still_moves_when_everyone_is_done() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	for k: int in m.units.size():
		m.units[k].activated = true
	m.selected = 0
	assert_eq(m.cycle_all(1), 1, "the roster key stopped working once the turn was spent")


# --- contacts, as the view reads them -------------------------------------------------------------

## The rule that lives in exactly one place: a live contact is at the unit's actual tile, a ghost is
## at a remembered one. A call site that got this wrong would draw a ghost that followed its unit
## around, which is perfect intelligence wearing a dim color.
func test_a_live_contact_tracks_its_unit_and_a_ghost_does_not() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10))
	m.add_unit(_unit(md, 2, 8, 10))

	var p: SpottingParams = SpottingParams.from_config(cfg)
	Spotting.recompute_all(md, cfg, p, m)

	var live: Contact = m.contact(1, 1)
	assert_not_null(live, "side 1 has no contact for a tank in plain view")
	assert_true(live.is_live(), "a visible tank is not a live contact")
	assert_eq(live.tile, m.unit(1).tile, "a live contact is not at its unit's tile")
	assert_eq(live.unit_type, m.unit(1).unit_type, "the contact does not say what it is")

	# Move it out of sight and it freezes.
	var was: int = m.unit(1).tile
	md.blocker_h[md.idx(5, 10)] = 14.0
	Spotting.recompute_all(md, cfg, p, m)
	m.unit(1).tile = md.idx(12, 10)

	var ghost: Contact = m.contact(1, 1)
	assert_not_null(ghost, "the contact vanished instead of becoming a ghost")
	assert_true(ghost.is_ghost(), "a lost contact is not a ghost")
	assert_eq(ghost.tile, was, "the ghost followed its unit")


func test_an_unknown_unit_has_no_contact() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	assert_eq(m.contact(1, 3), null, "a side has a contact for something it has never seen")
	assert_eq(m.contacts(1).size(), 0, "a side that knows nothing listed something")
	assert_eq(m.contact(9, 0), null, "a side that does not exist answered a contact query")


## A ghost fades as it ages, and the arithmetic is one rule rather than one per marker type.
func test_a_ghost_reports_how_stale_it_is() -> void:
	var md: MapData = _flat()
	var m: MatchState = _state(md)
	var full: int = cfg.i("spotting.ghost_turns", 2)

	var k: SideKnowledge = m.knowledge_for(1)
	k.mark_seen(3)
	k.mark_lost(3, md.idx(20, 20), Grid.N, full)

	var fresh: Contact = m.contact(1, 3)
	assert_almost_eq(fresh.staleness(full), 0.0, 0.001, "a ghost lost this turn is already stale")

	k.decay()
	var older: Contact = m.contact(1, 3)
	assert_gt(older.staleness(full), fresh.staleness(full), "a ghost did not fade as it aged")
	assert_le(older.staleness(full), 1.0, "staleness ran past the end of the ghost's life")


# --- the force each side is handed ----------------------------------------------------------------

## One of each type, per side, in the same order for both. Three is the smallest force that puts every
## column of units.json into play at once, and identical rosters are what make an outcome attributable
## to what the player did rather than to what they were handed.
func test_both_sides_field_one_of_each_type() -> void:
	var md: MapData = _flat(40)
	md.deploy_zone.fill(0)
	for y: int in range(2, 12):
		for x: int in range(2, 12):
			md.deploy_zone[md.idx(x, y)] = 1
		for x2: int in range(28, 38):
			md.deploy_zone[md.idx(x2, y)] = 2

	var m: MatchState = Deployment.deploy(md, cfg)
	assert_eq(m.units.size(), 6, "a two-sided match did not deploy three a side")

	for side: int in [1, 2]:
		var types := PackedStringArray()
		for index: int in m.side_units(side):
			types.append(String(m.unit(index).unit_type))
		assert_eq(types.size(), 3, "side %d did not get three units" % side)
		for wanted: String in ["light", "medium", "heavy"]:
			assert_true(types.has(wanted), "side %d fielded no %s tank" % [side, wanted])

	# The roster is per-side, so the two sides get the same list in the same order.
	var a: PackedInt32Array = m.side_units(1)
	var b: PackedInt32Array = m.side_units(2)
	for k: int in a.size():
		assert_eq(m.unit(a[k]).unit_type, m.unit(b[k]).unit_type,
			"the two sides were handed different forces at position %d" % k)


## The types have to differ in the ways the roster claims, or the force mix is decoration. Each of
## these is read by a rule: movement by the pathfinder, optics by spotting, armor by penetration.
func test_the_deployed_types_actually_differ() -> void:
	var md: MapData = _flat(40)
	md.deploy_zone.fill(0)
	for y: int in range(2, 12):
		for x: int in range(2, 12):
			md.deploy_zone[md.idx(x, y)] = 1

	var m: MatchState = Deployment.deploy(md, cfg, 3)
	var by_type: Dictionary = {}
	for index: int in m.side_units(1):
		by_type[String(m.unit(index).unit_type)] = m.unit(index)

	var light: UnitState = by_type["light"]
	var heavy: UnitState = by_type["heavy"]
	assert_gt(float(light.mp_max), float(heavy.mp_max), "the light tank is not faster")
	assert_gt(Spotting.optics_m(cfg, light), Spotting.optics_m(cfg, heavy),
		"the light tank does not have the better optics")
	assert_eq(light.turret, light.facing, "a deployed unit's gun is not down its hull")
