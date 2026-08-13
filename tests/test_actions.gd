extends TestCase

## The action layer — docs/decisions/0022.
##
## What is asserted here is the thing the batch exists to establish: an action resolves completely,
## inside `sim/`, before anything draws. Every test in this file runs headless with no `TankView`
## anywhere in it, which is the point — activation used to be triggered by an animation finishing.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


## Flat drivable ground with transitions classified. The pathfinder reads `md.can_move`, so a map
## that skips `Quantizer.classify_transitions` has no legal edges at all and every route fails for
## the wrong reason.
func _open(size: int = 20) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, facing: int = Grid.E) -> UnitState:
	var u := UnitState.new()
	u.side = side
	u.tile = md.idx(x, y)
	u.facing = facing
	u.mp_max = 220
	u.mp_left = 220
	return u


## Two units a side. Side 1's first unit is selected and is what every test orders about.
func _state(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10))
	m.add_unit(_unit(md, 1, 2, 14))
	m.add_unit(_unit(md, 2, 17, 10))
	m.add_unit(_unit(md, 2, 17, 14))
	m.selected = 0
	return m


func _resolver(md: MapData, m: MatchState) -> ActionResolver:
	return ActionResolver.new(md, cfg, m)


func _kinds(r: ActionResult) -> Array[int]:
	var out: Array[int] = []
	for e: ActionEvent in r.events:
		out.append(e.kind)
	return out


## Every field of every unit that an event can write, as one comparable string. Whole-board rather
## than per-unit on purpose: a woven stream touches units that were never ordered, and a snapshot
## that only looked at the actor would call that agreement.
func _describe_state(m: MatchState) -> String:
	var parts := PackedStringArray()
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		parts.append(
			"u%d t%d f%d mp%d a%d" % [k, u.tile, u.facing, u.mp_left, 1 if u.activated else 0]
		)
	return "\n".join(parts)


func _capture(m: MatchState) -> Array:
	var tiles := PackedInt32Array()
	var facings := PackedInt32Array()
	var mps := PackedInt32Array()
	var acted := PackedByteArray()
	for u: UnitState in m.units:
		tiles.append(u.tile)
		facings.append(u.facing)
		mps.append(u.mp_left)
		acted.append(1 if u.activated else 0)
	return [tiles, facings, mps, acted]


func _restore(m: MatchState, snap: Array) -> void:
	var tiles: PackedInt32Array = snap[0]
	var facings: PackedInt32Array = snap[1]
	var mps: PackedInt32Array = snap[2]
	var acted: PackedByteArray = snap[3]
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		u.tile = tiles[k]
		u.facing = facings[k]
		u.mp_left = mps[k]
		u.activated = acted[k] == 1


# --- the shape of the stream ---------------------------------------------------------------------

func test_a_move_opens_with_begin_and_closes_with_end() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(8, 10))
	assert_true(r.ok(), "a clear route across open ground should be legal")
	assert_gt(float(r.events.size()), 2.0, "a real move needs more than its own bookends")

	assert_eq(r.events[0].kind, ActionEvent.Kind.BEGIN, "the stream must open with BEGIN")
	assert_eq(r.last().kind, ActionEvent.Kind.END, "the stream must close with END")
	for k: int in range(1, r.events.size()):
		assert_ne(r.events[k].kind, ActionEvent.Kind.BEGIN, "a second BEGIN at %d" % k)
	for k2: int in r.events.size() - 1:
		assert_ne(r.events[k2].kind, ActionEvent.Kind.END, "an END before the last event, at %d" % k2)


## BEGIN carries where the unit was, END where it ended up. Instant playback reads only these two,
## so if either is wrong the whole speed toggle is wrong in a way 1x hides.
func test_the_bookends_carry_the_start_and_final_pose() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	var start_tile: int = u.tile
	var start_facing: int = u.facing
	var goal: int = md.idx(9, 13)

	var r: ActionResult = _resolver(md, m).plan_move(0, goal)
	assert_true(r.ok(), "no route")

	assert_eq(r.first().tile, start_tile, "BEGIN does not carry the starting tile")
	assert_eq(r.first().facing, start_facing, "BEGIN does not carry the starting facing")
	assert_eq(r.first().mp_left, u.mp_left, "BEGIN does not carry the movement points on hand")
	assert_eq(r.last().tile, goal, "END does not carry the destination")
	assert_eq(r.last().facing, r.path.final_facing(), "END does not carry the final facing")
	assert_eq(r.last().mp_left, r.mp_after, "END does not carry what is left")


func test_the_step_events_name_the_tiles_entered_in_order() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(11, 10))
	assert_true(r.ok(), "no route")

	var stepped := PackedInt32Array()
	for e: ActionEvent in r.events:
		if e.kind == ActionEvent.Kind.STEP:
			stepped.append(e.tile)

	assert_eq(stepped.size(), r.path.tiles.size() - 1,
		"there should be one STEP per tile entered, and none for the tile already stood on")
	for k: int in stepped.size():
		assert_eq(stepped[k], r.path.tiles[k + 1], "STEP %d entered the wrong tile" % k)


## The collapse semantics, pinned from the event side. `facings[k]` is the heading the tank departs
## `tiles[k]` with, so the turn on a tile comes *before* the step off it. Getting this backwards is
## the "tank turns a full tile early" bug the journal records; this is the test that stops it coming
## back through the new layer.
func test_a_turn_precedes_the_step_it_was_made_for() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	# Facing north, ordered due east: the tank must swing before it moves at all.
	m.unit(0).facing = Grid.N
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(8, 10))
	assert_true(r.ok(), "no route")

	var kinds: Array[int] = _kinds(r)
	assert_eq(kinds[1], ActionEvent.Kind.TURN, "the opening swing should come before any movement")
	assert_eq(r.events[1].tile, md.idx(2, 10), "the swing happens on the tile the tank is standing on")
	assert_eq(r.events[1].facing, Grid.E, "the swing should end pointing the way it is about to drive")

	# And every step's facing is the heading it was made on.
	for e: ActionEvent in r.events:
		if e.kind != ActionEvent.Kind.STEP or e.is_reversed():
			continue
		assert_eq(e.facing, Grid.E, "a forward step east recorded facing %d" % e.facing)


func test_a_reverse_step_is_flagged_and_keeps_its_facing() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	# One tile directly behind: reversing (16 mp) beats turning round and driving (10 + 24).
	m.unit(0).facing = Grid.E
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(1, 10))
	assert_true(r.ok(), "no route to the tile directly behind")

	var steps: Array[ActionEvent] = []
	for e: ActionEvent in r.events:
		if e.kind == ActionEvent.Kind.STEP:
			steps.append(e)
	assert_eq(steps.size(), 1, "one tile back should be one step")
	assert_true(steps[0].is_reversed(), "the step was not flagged as driven in reverse")
	assert_eq(steps[0].facing, Grid.E,
		"reversing does not turn the hull — the facing must still point the way it came from")


func test_a_rough_crossing_is_flagged_on_the_step_that_makes_it() -> void:
	var md: MapData = _open()
	# A step of three quanta is rough: over normal_max_dl (2), under rough_max_dl (4).
	for y: int in md.size:
		md.level[md.idx(5, y)] = 3
	Quantizer.classify_transitions(md, cfg)

	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(8, 10))
	assert_true(r.ok(), "no route over the step")

	var rough: int = 0
	for e: ActionEvent in r.events:
		if e.kind == ActionEvent.Kind.STEP and e.is_rough():
			rough += 1
	assert_gt(float(rough), 0.0, "a route over a rough transition flagged no step")
	assert_true(r.path.blocks_firing,
		"the path and the events disagree about whether rough ground was crossed")


# --- cost conservation ---------------------------------------------------------------------------

## The invariant the whole layer rests on. If the events do not add up to what the search charged,
## the status line, the preview and the simulation are three different numbers.
func test_the_event_costs_sum_to_what_the_move_charged() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var res: ActionResolver = _resolver(md, m)

	var checked: int = 0
	for gx: int in range(4, 16, 3):
		for gy: int in range(4, 17, 4):
			var goal: int = md.idx(gx, gy)
			if m.unit_at(goal) >= 0:
				continue
			var r: ActionResult = res.plan_move(0, goal)
			if not r.ok():
				continue
			checked += 1
			var total: int = 0
			for e: ActionEvent in r.events:
				total += e.cost
			assert_eq(total, r.path.cost,
				"events charge %d, the search charged %d, for (%d,%d)"
					% [total, r.path.cost, gx, gy])
			assert_eq(r.cost(), r.path.cost, "mp_before - mp_after disagrees with the path cost")
	assert_gt(float(checked), 6.0, "too few routes were actually exercised")


func test_the_movement_snapshots_only_ever_fall() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(12, 15))
	assert_true(r.ok(), "no route")

	var previous: int = r.first().mp_left
	for k: int in range(1, r.events.size()):
		var e: ActionEvent = r.events[k]
		assert_le(float(e.mp_left), float(previous),
			"event %d reports more movement left than the one before it" % k)
		assert_eq(e.mp_left, previous - e.cost, "event %d's snapshot does not match its cost" % k)
		previous = e.mp_left
	assert_eq(previous, r.mp_after, "the last snapshot is not what the action left the unit with")


# --- legality ------------------------------------------------------------------------------------

func test_an_unknown_unit_is_refused() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	assert_eq(_resolver(md, m).legality(99, md.idx(8, 10)), ActionResult.Status.NO_UNIT,
		"an index off the end of the unit list should be NO_UNIT")


func test_a_unit_of_the_idle_side_cannot_be_ordered() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	assert_eq(m.active_side, 1, "the fixture should start on side 1")
	assert_eq(_resolver(md, m).legality(2, md.idx(12, 10)), ActionResult.Status.WRONG_SIDE,
		"side 2's units are inspectable while side 1 is acting, not orderable")


func test_a_unit_that_has_acted_cannot_move() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	m.mark_activated(0)
	assert_eq(_resolver(md, m).legality(0, md.idx(8, 10)), ActionResult.Status.ALREADY_ACTED,
		"a unit marked done should refuse further orders")


func test_a_unit_with_nothing_left_cannot_move() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	m.unit(0).mp_left = cfg.i("movement.base_ortho", 10) - 1
	assert_eq(_resolver(md, m).legality(0, md.idx(8, 10)), ActionResult.Status.NO_MOVEMENT,
		"a unit that cannot afford the cheapest step has no move to make")


func test_ordering_a_unit_to_where_it_already_is_is_refused() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	assert_eq(_resolver(md, m).legality(0, m.unit(0).tile), ActionResult.Status.SAME_TILE,
		"standing still is not an order")


## Ahead of the reachability answer on purpose: an occupied tile is also unreachable, because it is
## a blocker in the flood fill, and "someone is standing there" is the more useful of the two.
func test_an_occupied_destination_is_refused_as_occupied() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var res: ActionResolver = _resolver(md, m)
	var friend: int = m.unit(1).tile
	assert_eq(res.legality(0, friend, res.reachable(0)), ActionResult.Status.OCCUPIED,
		"a tile with a unit on it should say so rather than reporting no route")


func test_a_tile_beyond_the_budget_is_unreachable() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	m.unit(0).mp_left = 30
	var res: ActionResolver = _resolver(md, m)
	assert_eq(res.legality(0, md.idx(18, 18), res.reachable(0)), ActionResult.Status.UNREACHABLE,
		"the far corner is not 30 movement points away")


func test_an_unroutable_tile_is_refused() -> void:
	var md: MapData = _open()
	# Wall the far side off entirely with impassable ground.
	for y: int in md.size:
		md.move_cost[md.idx(10, y)] = -10
	Quantizer.classify_transitions(md, cfg)

	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(15, 10))
	assert_eq(r.status, ActionResult.Status.NO_ROUTE, "there is no way through a solid wall")
	assert_eq(r.path, null, "a refused order should not report a route")


## Every way of being refused, in one place: nothing is planned and nothing is touched.
func test_a_refused_order_produces_no_events_and_changes_nothing() -> void:
	var md: MapData = _open()
	var goal: int = md.idx(8, 10)

	var cases: Array = [
		[99, goal],                                  # NO_UNIT
		[2, md.idx(12, 10)],                         # WRONG_SIDE
	]
	for c: Array in cases:
		var m: MatchState = _state(md)
		var before: PackedInt32Array = _snapshot(m)
		var r: ActionResult = _resolver(md, m).resolve_move(int(c[0]), int(c[1]))
		assert_false(r.ok(), "case %s should have been refused" % str(c))
		assert_eq(r.events.size(), 0, "a refused order produced %d events" % r.events.size())
		assert_false(r.committed, "a refused order reported itself committed")
		_assert_unchanged(m, before, "case %s" % str(c))

	# The two that need the state set up first.
	var m2: MatchState = _state(md)
	m2.mark_activated(0)
	var b2: PackedInt32Array = _snapshot(m2)
	var r2: ActionResult = _resolver(md, m2).resolve_move(0, goal)
	assert_eq(r2.status, ActionResult.Status.ALREADY_ACTED, "expected ALREADY_ACTED")
	assert_eq(r2.events.size(), 0, "ALREADY_ACTED produced events")
	_assert_unchanged(m2, b2, "already acted")

	var m3: MatchState = _state(md)
	var b3: PackedInt32Array = _snapshot(m3)
	var r3: ActionResult = _resolver(md, m3).resolve_move(0, m3.unit(1).tile)
	assert_eq(r3.status, ActionResult.Status.OCCUPIED, "expected OCCUPIED")
	assert_eq(r3.events.size(), 0, "OCCUPIED produced events")
	_assert_unchanged(m3, b3, "occupied destination")


# --- occupancy, carried across from docs/decisions/0015 -------------------------------------------

## The resolver hands `MatchState.occupancy()` to the search, so a route does not drive through a
## tank standing in the way. The gap is deliberately one tile wide, so a route that ignored the
## blocker would go straight through it and be measurably shorter.
func test_a_route_goes_around_a_unit_rather_than_through_it() -> void:
	var md: MapData = _open()
	for y: int in md.size:
		if y != 10:
			md.move_cost[md.idx(9, y)] = -10
	Quantizer.classify_transitions(md, cfg)

	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 10))
	m.add_unit(_unit(md, 1, 9, 10))  # sitting in the only doorway
	m.selected = 0

	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(14, 10))
	assert_eq(r.status, ActionResult.Status.NO_ROUTE,
		"the only gap is occupied, so there is no way past — a route was found through the unit")

	# Move the blocker aside and the same order succeeds, which is what proves the wall is not the
	# thing refusing it.
	m.unit(1).tile = md.idx(4, 14)
	var r2: ActionResult = _resolver(md, m).plan_move(0, md.idx(14, 10))
	assert_true(r2.ok(), "with the doorway clear the route should exist")


# --- purity and determinism -----------------------------------------------------------------------

func test_planning_changes_nothing() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var before: PackedInt32Array = _snapshot(m)
	var r: ActionResult = _resolver(md, m).plan_move(0, md.idx(13, 13))
	assert_true(r.ok(), "no route")
	assert_false(r.committed, "a plan should not report itself committed")
	_assert_unchanged(m, before, "plan_move")


## Two identical states, planned independently, must produce the same stream. This is the property
## the ordered input log in docs/decisions/0005 needs, reduced to one integer comparison.
func test_the_same_order_plans_the_same_stream_twice() -> void:
	var md: MapData = _open()
	var goal: int = md.idx(15, 6)
	var a: ActionResult = _resolver(md, _state(md)).plan_move(0, goal)
	var b: ActionResult = _resolver(md, _state(md)).plan_move(0, goal)
	assert_true(a.ok() and b.ok(), "no route")
	assert_eq(a.events.size(), b.events.size(), "the two streams are different lengths")
	assert_eq(a.fingerprint(), b.fingerprint(),
		"the same order planned twice produced different streams:\n%s\n---\n%s"
			% [a.describe(), b.describe()])


## Amended for docs/decisions/0025, exactly as its previous version said it would have to be.
##
## Resolving is no longer planning plus applying: the weave splices in what the rest of the board did
## about the move, and on an open map with four tanks on it that means reveals. So the two streams
## legitimately differ — but they must differ *only* by the reactions. What the tank itself did has to
## be identical, or the preview the player committed to was not the move they got.
##
## This is the sharper claim, not a weakened one. The old version could only say the streams matched
## while nothing could ever be spliced into one.
func test_resolving_reacts_to_the_board_but_does_not_change_the_move() -> void:
	var md: MapData = _open()
	var goal: int = md.idx(14, 12)
	var planned: ActionResult = _resolver(md, _state(md)).plan_move(0, goal)
	var resolved: ActionResult = _resolver(md, _state(md)).resolve_move(0, goal)
	assert_true(planned.ok() and resolved.ok(), "no route")

	assert_eq(_own_moves(planned), _own_moves(resolved),
		"resolving produced a different account of the tank's own movement than planning did")
	assert_eq(resolved.destination(), planned.destination(), "the two disagree about where it ended")
	assert_eq(resolved.mp_after, planned.mp_after, "the two disagree about what the move cost")

	# And the difference really is reactions rather than an empty claim: this fixture has four tanks
	# in the open, so something is seen.
	assert_gt(float(resolved.event_count()), float(planned.event_count()),
		"the weave spliced nothing in, so this test proves nothing about what it splices")


## Just the acting unit's own movement, as one fingerprint. Reactions name other units or are
## knowledge changes; neither is part of what the tank did.
func _own_moves(r: ActionResult) -> int:
	var parts := PackedStringArray()
	for e: ActionEvent in r.events:
		match e.kind:
			ActionEvent.Kind.BEGIN, ActionEvent.Kind.TURN, ActionEvent.Kind.STEP, \
			ActionEvent.Kind.TURRET, ActionEvent.Kind.ACTIVATED, ActionEvent.Kind.END:
				if e.unit == r.unit:
					parts.append(e.describe())
			_:
				pass
	return Rng.fnv1a("\n".join(parts))


# --- commit ---------------------------------------------------------------------------------------

func test_resolving_moves_the_unit_and_spends_the_points() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	var before_mp: int = u.mp_left
	var goal: int = md.idx(10, 10)

	var r: ActionResult = _resolver(md, m).resolve_move(0, goal)
	assert_true(r.ok(), "no route")
	assert_true(r.committed, "resolve_move did not commit")
	assert_eq(u.tile, goal, "the unit is not at the destination")
	assert_eq(u.facing, r.path.final_facing(), "the unit is not facing the way the route ended")
	assert_eq(u.mp_left, r.mp_after, "the unit's movement points disagree with the stream")
	assert_eq(before_mp - u.mp_left, r.path.cost, "the wrong number of movement points was spent")


## The state after a commit is exactly what the last event said it would be, because the commit
## walked the events to get there rather than reading the path.
func test_commit_leaves_the_state_where_the_last_event_says() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(7, 14))
	assert_true(r.ok(), "no route")
	var u: UnitState = m.unit(0)
	assert_eq(u.tile, r.last().tile, "the unit is not where END says")
	assert_eq(u.facing, r.last().facing, "the unit is not facing where END says")
	assert_eq(u.mp_left, r.last().mp_left, "the unit has not got what END says")


# --- the stream is the authoritative account — docs/decisions/0026 ---------------------------------

## The assertion 0022 wanted and could not write.
##
## While `commit` *was* the only path from an action to the state, "the events are what happened" was
## unfalsifiable: commit agreed with the path because commit was the path, and a thing can always be
## shown to agree with itself. Now that the resolver applies events as it appends them and `commit`
## replays the finished list, there are two routes to the same state and it is worth checking they
## arrive at it. This is the test that makes the interruption machinery in iteration 2 safe to build.
func test_replaying_the_stream_reproduces_the_state_that_resolving_left() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var before: Array = _capture(m)

	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(11, 13))
	assert_true(r.ok(), "no route")
	var resolved: String = _describe_state(m)

	_restore(m, before)
	assert_ne(_describe_state(m), resolved, "the fixture never left the pre-action state")

	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(
		_describe_state(m), resolved, "replaying the stream did not reproduce the resolved state"
	)


## The resolver applies an event when it appends it and `commit` may apply the whole list again, so
## every movement arm has to assign rather than accumulate. `ev.mp_left` is what the unit has *after*
## the event, never what the event cost — the day that stops being true, a move charges twice and the
## only symptom is a tank that runs out of fuel early.
func test_applying_a_movement_stream_twice_changes_nothing_the_second_time() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var before: Array = _capture(m)

	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(9, 12))
	assert_true(r.ok(), "no route")
	var resolved: String = _describe_state(m)

	_restore(m, before)
	EventApplier.apply_all(cfg, md, m, r.events)
	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(_describe_state(m), resolved, "a movement stream is not idempotent")


func test_a_result_cannot_be_committed_twice() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(9, 10))
	assert_true(r.committed, "the first commit did not take")
	var mp_after_first: int = m.unit(0).mp_left

	assert_false(MoveAction.commit(cfg, md, m, r), "committing a spent result should refuse")
	assert_eq(m.unit(0).mp_left, mp_after_first, "a second commit double-charged the movement")


# --- activation, which is the point of the batch --------------------------------------------------

## The test that pins the removal of the view signal. There is no `TankView` in this file at all,
## and the unit is marked done by the time `resolve_move` returns.
func test_a_move_that_exhausts_the_unit_marks_it_activated_with_no_view_involved() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var u: UnitState = m.unit(0)
	# Just enough for two orthogonal steps and no more.
	u.mp_left = cfg.i("movement.base_ortho", 10) * 2

	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(4, 10))
	assert_true(r.ok(), "two cheap steps east should be affordable")
	assert_true(r.exhausted(), "the stream does not contain an ACTIVATED event")
	assert_true(u.activated, "the unit was not marked activated by the resolver")
	assert_false(u.can_act(cfg), "a unit with nothing left should not be able to act")


func test_a_move_that_leaves_movement_does_not_activate() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(5, 10))
	assert_true(r.ok(), "no route")
	assert_false(r.exhausted(), "a short move out of a full tank should not exhaust it")
	assert_false(m.unit(0).activated, "the unit was marked done with movement still in hand")
	assert_true(m.unit(0).can_act(cfg), "the unit should still be able to act")


## Ordering twice in a turn is legal while movement remains — that is what two actions' worth of
## movement points means (docs/decisions/0014) — and the second order starts from where the first
## one left off.
func test_a_second_order_in_the_same_turn_starts_from_the_new_position() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var res: ActionResolver = _resolver(md, m)

	var first: ActionResult = res.resolve_move(0, md.idx(6, 10))
	assert_true(first.ok(), "the first order failed")
	var second: ActionResult = res.resolve_move(0, md.idx(10, 10))
	assert_true(second.ok(), "the second order failed")

	assert_eq(second.first().tile, md.idx(6, 10),
		"the second order did not begin where the first one ended")
	assert_eq(second.mp_before, first.mp_after,
		"the second order did not begin with what the first one left")


# --- helpers ---------------------------------------------------------------------------------------

## tile, facing, mp_left and activated for every unit, flattened.
func _snapshot(m: MatchState) -> PackedInt32Array:
	var out := PackedInt32Array()
	for u: UnitState in m.units:
		out.append(u.tile)
		out.append(u.facing)
		out.append(u.mp_left)
		out.append(1 if u.activated else 0)
	return out


func _assert_unchanged(m: MatchState, before: PackedInt32Array, what: String) -> void:
	var now: PackedInt32Array = _snapshot(m)
	assert_eq(now.size(), before.size(), "%s: the unit list changed size" % what)
	for k: int in mini(now.size(), before.size()):
		assert_eq(now[k], before[k],
			"%s: unit %d's %s changed" % [
				what, k / 4, ["tile", "facing", "mp_left", "activated"][k % 4],
			])
