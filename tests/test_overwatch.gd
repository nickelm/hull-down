extends TestCase

## Overwatch as a per-tile interrupt — docs/decisions/0030.
##
## The interrupt is the piece that needed both halves of iteration 2 working at once: the trigger is
## a spotting question and the consequence is a combat one. Everything here is about the seam between
## them, and about the stream still being a complete account of a shorter move afterwards.

var cfg: Config
var sp: SpottingParams


func setup() -> void:
	cfg = Config.load_default()
	sp = SpottingParams.from_config(cfg)


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, facing: int, type_name: String = "medium") -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = facing
	u.turret = facing
	return u


## A watcher of side 1 at (4,12) looking east down row 12, and a mover of side 2 that starts at
## (18,4) and drives south across the lane. The tile it crosses the lane on is known by construction.
func _ambush() -> Array:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12, Grid.E))    # 0 — the watcher
	m.add_unit(_unit(md, 2, 18, 4, Grid.S))    # 1 — the mover
	m.active_side = 2
	return [md, m]


func _resolver(md: MapData, m: MatchState, seed_value: int = 991) -> ActionResolver:
	var r := ActionResolver.new(md, cfg, m, seed_value)
	r.refresh_knowledge()
	return r


func _watch(md: MapData, m: MatchState, watcher: int, aim: int) -> void:
	var was: int = m.active_side
	m.active_side = m.unit(watcher).side
	var r: ActionResult = ActionResolver.new(md, cfg, m, 1).resolve_overwatch(watcher, aim)
	assert_true(r.ok(), "the fixture could not go on overwatch: %d" % r.status)
	m.active_side = was


func _of_kind(r: ActionResult, kind: int) -> Array[ActionEvent]:
	var out: Array[ActionEvent] = []
	for e: ActionEvent in r.events:
		if e.kind == kind:
			out.append(e)
	return out


# --- laying the ambush ----------------------------------------------------------------------------

## Overwatch costs the whole action and ends the turn — 0003. That price is the only thing that makes
## it a decision rather than something you do with a spare moment.
func test_going_on_overwatch_costs_the_turn() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12, Grid.E))
	m.add_unit(_unit(md, 2, 18, 12, Grid.W))

	var u: UnitState = m.unit(0)
	var expected_mp: int = u.mp_after_action(cfg)

	var r: ActionResult = ActionResolver.new(md, cfg, m, 1).resolve_overwatch(0, Grid.E)
	assert_true(r.ok(), "overwatch was refused: %d" % r.status)
	assert_eq(u.overwatch_dir, Grid.E, "the gun was not laid down the bearing given")
	assert_eq(u.turret, Grid.E, "the turret did not follow the bearing")
	assert_eq(u.mp_left, expected_mp, "overwatch did not forfeit the rest of the action in progress")
	assert_true(u.activated, "overwatch did not end the unit's turn")
	assert_gt(float(u.overwatch_shots_left), 0.0, "overwatch was laid with no shots to take")


## The bearing has to be one the turret can reach without turning the hull — 0027. Overwatch aims at
## a place, and a place the gun cannot point at is not one you can promise to cover.
func test_overwatch_cannot_be_laid_outside_the_turret_arc() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12, Grid.E))
	m.add_unit(_unit(md, 2, 18, 12, Grid.W))

	assert_eq(Overwatch.legality(md, cfg, m, 0, Grid.W), ActionResult.Status.OUT_OF_ARC,
		"a gun was laid straight backwards over its own engine deck")

	m.unit(0).ammo = 0
	assert_eq(Overwatch.legality(md, cfg, m, 0, Grid.E), ActionResult.Status.NO_AMMO,
		"an empty tank went on overwatch")
	m.unit(0).ammo = 5
	m.unit(0).gun_damaged = true
	assert_eq(Overwatch.legality(md, cfg, m, 0, Grid.E), ActionResult.Status.GUN_DAMAGED,
		"a tank with a wrecked gun went on overwatch")


# --- the trigger ----------------------------------------------------------------------------------

## The lane is a lane. A mover outside the arc the gun was laid along walks past untouched, and one
## inside it does not — which is the whole reason overwatch is a decision about *where* rather than a
## toggle.
func test_the_trigger_respects_the_arc_it_was_laid_along() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)
	ActionResolver.new(md, cfg, m, 1).refresh_knowledge()

	# Due east of the watcher: dead center of the lane.
	m.unit(1).tile = md.idx(18, 12)
	assert_true(Overwatch.triggers(md, cfg, sp, m, 0, 1), "a mover in the lane did not trigger")

	# One step off the bearing is still in the lane — the cone is 90 degrees wide.
	m.unit(1).tile = md.idx(16, 4)
	assert_eq(Armor.bearing(md, m.unit(0).tile, m.unit(1).tile), Grid.NE, "fixture bearing")
	assert_true(Overwatch.triggers(md, cfg, sp, m, 0, 1),
		"a mover one step off the laid bearing was outside the lane")

	# Due north is two steps off, and outside it. This is what makes *where* you lay the ambush a
	# decision: at a wider arc one watcher covers the whole approach and the choice evaporates.
	m.unit(1).tile = md.idx(4, 4)
	assert_eq(Armor.bearing(md, m.unit(0).tile, m.unit(1).tile), Grid.N, "fixture bearing")
	assert_false(Overwatch.triggers(md, cfg, sp, m, 0, 1),
		"a mover at right angles to the lane triggered anyway")

	# And behind is right out.
	m.unit(1).tile = md.idx(1, 12)
	assert_false(Overwatch.triggers(md, cfg, sp, m, 0, 1),
		"a watcher shot at something behind it")


## A watcher that cannot see it does not shoot at it, however well the arc lines up. This is the
## dependency that made overwatch the last thing built rather than the first.
func test_a_watcher_does_not_shoot_at_what_it_cannot_see() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)

	m.unit(1).tile = md.idx(18, 12)
	ActionResolver.new(md, cfg, m, 1).refresh_knowledge()
	assert_true(Overwatch.triggers(md, cfg, sp, m, 0, 1), "the fixture does not trigger to start with")

	for y: int in md.size:
		md.blocker_h[md.idx(11, y)] = 14.0
	assert_false(Overwatch.triggers(md, cfg, sp, m, 0, 1), "a watcher shot through a hill")


func test_a_watcher_with_nothing_laid_never_triggers() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.unit(1).tile = md.idx(18, 12)
	ActionResolver.new(md, cfg, m, 1).refresh_knowledge()
	assert_false(Overwatch.triggers(md, cfg, sp, m, 0, 1), "a unit not on overwatch fired anyway")


func test_a_watcher_does_not_shoot_its_own_side() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.unit(1).side = 1
	_watch(md, m, 0, Grid.E)
	m.unit(1).tile = md.idx(18, 12)
	assert_false(Overwatch.triggers(md, cfg, sp, m, 0, 1), "a watcher shot at a friend")


# --- the interrupt ---------------------------------------------------------------------------------

## The whole point, end to end: a mover crossing the lane is shot at *on the tile it crosses on*, the
## move stops there, and the stream still says so consistently.
func test_crossing_the_lane_stops_the_move_where_it_was_shot_at() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)

	var resolver: ActionResolver = _resolver(md, m)
	var goal: int = md.idx(18, 20)
	var r: ActionResult = resolver.resolve_move(1, goal)
	assert_true(r.ok(), "no route: %d" % r.status)

	var fires: Array[ActionEvent] = _of_kind(r, ActionEvent.Kind.FIRE)
	assert_gt(float(fires.size()), 0.0, "driving across the lane was never fired on")
	assert_true(fires[0].is_overwatch(), "the shot was not flagged as reaction fire")
	assert_eq(fires[0].unit, 0, "the shot came from the wrong unit")
	assert_eq(fires[0].other, 1, "the shot was aimed at the wrong unit")

	assert_true(r.interrupted, "the result does not report having been interrupted")
	assert_ne(r.destination(), goal, "the mover reached its destination through an ambush")

	# Which tile it stops on is a property of the ambush's geometry, not something to write down here
	# — so it is read off the stream. The claim is that the *last* step is the one that was fired on,
	# and that the stream ends there.
	var last_step: int = -1
	for k: int in r.events.size():
		if r.events[k].kind == ActionEvent.Kind.STEP:
			last_step = k
	assert_ge(float(last_step), 0.0, "the move has no steps at all")
	assert_eq(r.destination(), r.events[last_step].tile,
		"the stream ends somewhere other than the last tile actually entered")

	var fired_after_last_step: bool = false
	for k2: int in range(last_step, r.events.size()):
		if r.events[k2].kind == ActionEvent.Kind.FIRE:
			fired_after_last_step = true
	assert_true(fired_after_last_step, "the move stopped on a tile nothing was fired from")

	# The stream is a complete account of the *shorter* move.
	assert_eq(m.unit(1).tile, r.destination(), "the unit is not where the stream says it stopped")
	assert_eq(m.unit(1).mp_left, r.last().mp_left, "the unit's movement disagrees with END")


## Being shot at costs tempo, not the turn. 0021's forfeit rule is about *paying* for a whole action,
## and taking fire is not a payment — so an interrupted tank can be ordered on again, into the same
## ambush if the player insists.
func test_an_interrupted_mover_keeps_what_it_had_left() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)

	var resolver: ActionResolver = _resolver(md, m)
	var r: ActionResult = resolver.resolve_move(1, md.idx(18, 20))
	assert_true(r.ok() and r.interrupted, "the fixture was not interrupted")

	var u: UnitState = m.unit(1)
	if not u.alive:
		return  # It was destroyed rather than merely stopped; there is nothing left to order.
	assert_gt(float(u.mp_left), 0.0, "an interrupted mover was stripped of its movement")
	assert_false(u.activated, "an interrupted mover had its turn ended for it")
	assert_eq(resolver.legality(1, md.idx(18, 20)), ActionResult.Status.OK,
		"an interrupted mover cannot be ordered on again")


## Reveals precede the tracer. A watcher cannot shoot at something it has not seen, and the stream has
## to say so in that order or the presentation layer fires a round at an empty tile.
func test_the_reveal_comes_before_the_shot() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12, Grid.E))
	m.add_unit(_unit(md, 2, 20, 12, Grid.W))
	# A screen with a gap in the watcher's lane, so the mover is masked until it steps into it.
	for y: int in md.size:
		if y != 12:
			md.blocker_h[md.idx(12, y)] = 14.0
	m.unit(1).tile = md.idx(20, 8)
	m.active_side = 2
	_watch(md, m, 0, Grid.E)

	var r: ActionResult = _resolver(md, m).resolve_move(1, md.idx(20, 16))
	assert_true(r.ok(), "no route")

	var first_fire: int = -1
	var reveal: int = -1
	for k: int in r.events.size():
		var e: ActionEvent = r.events[k]
		if reveal < 0 and e.kind == ActionEvent.Kind.SPOT and e.other == 1 and e.value == 1:
			reveal = k
		if first_fire < 0 and e.kind == ActionEvent.Kind.FIRE:
			first_fire = k
	if first_fire < 0:
		return  # nothing fired in this geometry; the ordering claim is vacuous rather than false
	assert_ge(float(reveal), 0.0, "a shot was fired at a mover that was never revealed")
	assert_lt(float(reveal), float(first_fire), "the round came out before the contact appeared")


## Overwatch fires the number of times it was given and no more. Without the cap a single watcher
## empties itself into one move.
func test_a_watcher_fires_only_as_often_as_it_was_given() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)
	var allowance: int = m.unit(0).overwatch_shots_left

	var resolver: ActionResolver = _resolver(md, m)
	var total: int = 0
	for _order: int in 4:
		if not m.unit(1).alive:
			break
		var r: ActionResult = resolver.resolve_move(1, md.idx(18, 20))
		if not r.ok():
			break
		total += _of_kind(r, ActionEvent.Kind.FIRE).size()
	assert_le(float(total), float(allowance),
		"a watcher fired %d times on an allowance of %d" % [total, allowance])
	assert_eq(m.unit(0).overwatch_shots_left, maxi(allowance - total, 0),
		"the watcher's remaining shots do not match what it fired")


## With nothing watching, the weave costs the move nothing at all.
func test_a_move_past_nobody_is_untouched() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]

	var goal: int = md.idx(18, 20)
	var planned: ActionResult = ActionResolver.new(md, cfg, m, 1).plan_move(1, goal)
	var r: ActionResult = _resolver(md, m).resolve_move(1, goal)
	assert_true(r.ok() and planned.ok(), "no route")
	assert_false(r.interrupted, "an unopposed move reported an interruption")
	assert_eq(r.destination(), goal, "an unopposed move did not arrive")
	assert_eq(_of_kind(r, ActionEvent.Kind.FIRE).size(), 0, "an unopposed move was fired on")


## Traversing the gun takes the ambush with it — docs/decisions/0035, checked end to end through
## `triggers` rather than only on the flag.
##
## This used to be 0032's *price*: the free hull swivel canceled overwatch outright, because otherwise
## a watcher re-aimed for free every turn and "overwatch costs your whole turn" stopped meaning
## anything. With the swivel withdrawn the price is gone and the rule is simpler — the bearing a unit
## watches down is where its gun points, so moving one moves the other. What that must *not* do is
## leave the two disagreed, which is what this asserts: aim the gun somewhere else and the lane it was
## covering goes cold.
func test_traversing_the_gun_takes_the_ambush_with_it() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)
	m.unit(1).tile = md.idx(18, 12)
	ActionResolver.new(md, cfg, m, 1).refresh_knowledge()
	assert_true(Overwatch.triggers(md, cfg, sp, m, 0, 1), "the fixture does not trigger to start with")

	m.active_side = 1
	var r: ActionResult = ActionResolver.new(md, cfg, m, 1).resolve_turret(0, Grid.N)
	assert_true(r.ok(), "the traverse was refused: %d" % r.status)
	assert_eq(m.unit(0).overwatch_dir, Grid.N, "the watch did not follow the gun")
	assert_false(Overwatch.triggers(md, cfg, sp, m, 0, 1),
		"the gun was laid elsewhere but the old lane stayed armed")


# --- the interrupted stream is still an account ----------------------------------------------------

## The single most valuable assertion in the batch. Everything the action touched is snapshotted, the
## move is resolved through an ambush, the snapshot is restored, and the finished stream is replayed
## from the pre-action state. It has to land in exactly the same place — including the truncation,
## which `commit` never learns about.
func test_replaying_an_interrupted_stream_reproduces_what_the_weave_left() -> void:
	var fixture: Array = _ambush()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	_watch(md, m, 0, Grid.E)
	var resolver: ActionResolver = _resolver(md, m)

	var before: Array = _capture(m, md)
	var r: ActionResult = resolver.resolve_move(1, md.idx(18, 20))
	assert_true(r.ok() and r.interrupted, "the fixture was not interrupted")
	var resolved: String = _describe(m, md)

	_restore(m, md, before)
	assert_ne(_describe(m, md), resolved, "the fixture never left the pre-action state")

	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(_describe(m, md), resolved,
		"replaying an interrupted stream did not reproduce the state the weave left")

	# And a second application changes nothing further.
	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(_describe(m, md), resolved, "an interrupted stream is not idempotent")


func _describe(m: MatchState, md: MapData) -> String:
	var parts := PackedStringArray()
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		parts.append("u%d t%d f%d r%d mp%d mv%d a%d al%d am%d ow%d os%d sh%d im%d gd%d %s" % [
			k, u.tile, u.facing, u.turret, u.mp_left, u.mp_moved, int(u.activated), int(u.alive),
			u.ammo, u.overwatch_dir, u.overwatch_shots_left, u.shaken_turns,
			int(u.immobilised), int(u.gun_damaged), str(u.shred_mm),
		])
	for side: int in range(1, m.side_count + 1):
		parts.append("k%d %d" % [side, m.knowledge_for(side).fingerprint()])
	parts.append("dyn %d" % Rng.fnv1a(str(md.blocker_dyn)))
	return "\n".join(parts)


func _capture(m: MatchState, md: MapData) -> Array:
	var out: Array = []
	for u: UnitState in m.units:
		out.append([
			u.tile, u.facing, u.turret, u.mp_left, u.mp_moved, u.activated, u.alive, u.ammo,
			u.overwatch_dir, u.overwatch_shots_left, u.shaken_turns, u.immobilised, u.gun_damaged,
			u.shred_mm.duplicate(), u.fired_this_turn, u.fire_blocked,
		])
	var books: Array = []
	for k: SideKnowledge in m.knowledge:
		books.append([
			k._visual_state.duplicate(), k._visual_tile.duplicate(),
			k._visual_facing.duplicate(), k._visual_ghost_left.duplicate(),
		])
	out.append(books)
	out.append(md.blocker_dyn.duplicate())
	return out


func _restore(m: MatchState, md: MapData, snap: Array) -> void:
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		var row: Array = snap[k]
		u.tile = row[0]; u.facing = row[1]; u.turret = row[2]; u.mp_left = row[3]
		u.mp_moved = row[4]; u.activated = row[5]; u.alive = row[6]; u.ammo = row[7]
		u.overwatch_dir = row[8]; u.overwatch_shots_left = row[9]; u.shaken_turns = row[10]
		u.immobilised = row[11]; u.gun_damaged = row[12]; u.shred_mm = row[13]
		u.fired_this_turn = row[14]; u.fire_blocked = row[15]
	var books: Array = snap[m.units.size()]
	for s: int in m.knowledge.size():
		var b: Array = books[s]
		m.knowledge[s]._visual_state = b[0]
		m.knowledge[s]._visual_tile = b[1]
		m.knowledge[s]._visual_facing = b[2]
		m.knowledge[s]._visual_ghost_left = b[3]
	md.blocker_dyn = snap[m.units.size() + 1]
