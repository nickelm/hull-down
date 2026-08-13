extends TestCase

## The weave: what the rest of the board does while a unit is moving — docs/decisions/0025 and 0026.
##
## The claim under test is that a reveal happens **on the tile it happens on**, not at a turn
## boundary, and that the stream carrying it is still a complete account of the action. Those two
## together are what overwatch will be spliced into, so if either is loose the interrupt built on top
## of it inherits the looseness.

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


func _resolver(md: MapData, m: MatchState) -> ActionResolver:
	var r := ActionResolver.new(md, cfg, m)
	r.refresh_knowledge()
	return r


func _of_kind(r: ActionResult, kind: int) -> Array[ActionEvent]:
	var out: Array[ActionEvent] = []
	for e: ActionEvent in r.events:
		if e.kind == kind:
			out.append(e)
	return out


func _index_of(r: ActionResult, kind: int, other: int) -> int:
	for k: int in r.events.size():
		if r.events[k].kind == kind and r.events[k].other == other:
			return k
	return -1


## A wall of tall cover with one gap in it, and a mover that drives from behind the wall out into the
## gap. The tile the reveal must land on is known by construction rather than by observation.
##
## Side 1's unit 0 sits still at the far end of the corridor looking east. Side 2's unit 1 starts
## masked behind the wall and drives north into the open lane.
func _screened() -> Array:
	var md: MapData = _flat()
	for y: int in md.size:
		if y == 10:
			continue
		md.blocker_h[md.idx(12, y)] = 14.0

	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10, Grid.E))     # 0 — the watcher, side 1
	m.add_unit(_unit(md, 2, 18, 14, Grid.N))    # 1 — the mover, side 2, masked to start
	return [md, m]


# --- the reveal lands on the tile it happens on ---------------------------------------------------

## The headline claim of 0025. A turn-start sweep can say *that* a tank became visible; only a check
## per tile entered can say **where**, and the whole overwatch mechanism is built on being able to
## say where.
func test_a_reveal_lands_on_the_step_that_earned_it() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2

	assert_false(m.knowledge_for(1).sees(1), "the mover is visible before it has moved")

	var r: ActionResult = _resolver(md, m).resolve_move(1, md.idx(18, 8))
	assert_true(r.ok(), "no route: %d" % r.status)

	var at: int = _index_of(r, ActionEvent.Kind.SPOT, 1)
	assert_ge(float(at), 0.0, "driving into the open never revealed the mover")

	var spot: ActionEvent = r.events[at]
	assert_eq(spot.value, 1, "the reveal was recorded against the wrong side")
	assert_eq(spot.other, 1, "the reveal names the wrong unit")
	assert_eq(md.ty(spot.tile), 10, "the reveal did not land on the tile in the gap")
	assert_eq(spot.tile, m.unit(1).tile if md.ty(m.unit(1).tile) == 10 else spot.tile,
		"the reveal's tile is not the mover's pose at that moment")

	# And the step immediately before it is the one that entered that tile.
	var prev: ActionEvent = r.events[at - 1]
	assert_eq(prev.kind, ActionEvent.Kind.STEP, "a reveal was not preceded by the step that caused it")
	assert_eq(prev.tile, spot.tile, "the reveal names a different tile from the step before it")


## Nothing is revealed before the mover has gone anywhere. A stream whose first event after `BEGIN`
## was a reveal would mean the sweep and the weave disagree about the starting position.
func test_nothing_is_revealed_before_the_first_step() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2

	var r: ActionResult = _resolver(md, m).resolve_move(1, md.idx(18, 8))
	assert_true(r.ok(), "no route")

	var first_step: int = -1
	for k: int in r.events.size():
		if r.events[k].kind == ActionEvent.Kind.STEP:
			first_step = k
			break
	assert_ge(float(first_step), 0.0, "the move has no steps")

	for k2: int in first_step:
		assert_ne(r.events[k2].kind, ActionEvent.Kind.SPOT,
			"a reveal was emitted before the mover had moved")


## Driving back out of sight leaves a ghost, mid-path, at the tile contact was lost on.
func test_driving_back_into_cover_leaves_a_ghost_mid_path() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2
	m.unit(1).tile = md.idx(18, 10)   # start in the gap, in plain view

	var resolver: ActionResolver = _resolver(md, m)
	assert_true(m.knowledge_for(1).sees(1), "the fixture does not start visible")

	var r: ActionResult = resolver.resolve_move(1, md.idx(18, 14))
	assert_true(r.ok(), "no route")

	var at: int = _index_of(r, ActionEvent.Kind.LOST, 1)
	assert_ge(float(at), 0.0, "driving back behind the wall never broke contact")
	assert_eq(r.events[at].value, 1, "the loss was recorded against the wrong side")
	assert_eq(m.knowledge_for(1).state_of(1), SideKnowledge.State.GHOST, "no ghost was left")
	assert_eq(m.knowledge_for(1).ghost_tile(1), r.events[at].tile,
		"the ghost is not where the LOST event says it is")


## The mover gains contacts too. Spotting runs for **both** sides every step, because cresting a ridge
## reveals what is on the other side of it as surely as it reveals you.
func test_the_mover_gains_contacts_as_well_as_giving_itself_away() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2

	# Stopping *in* the gap rather than driving through it. Ending north of the lane would gain both
	# contacts and lose them again on the same path, which is correct behavior and tests nothing
	# about whether either side held what it gained.
	var r: ActionResult = _resolver(md, m).resolve_move(1, md.idx(16, 10))
	assert_true(r.ok(), "no route")
	assert_eq(md.ty(m.unit(1).tile), 10, "the fixture did not stop in the gap")

	assert_ge(float(_index_of(r, ActionEvent.Kind.SPOT, 0)), 0.0,
		"the mover never spotted the stationary watcher it drove into view of")
	assert_ge(float(_index_of(r, ActionEvent.Kind.SPOT, 1)), 0.0,
		"the mover was never revealed to the watcher")
	assert_true(m.knowledge_for(2).sees(0), "side 2 does not hold the contact it gained")
	assert_true(m.knowledge_for(1).sees(1), "side 1 does not hold the contact it gained")
	assert_eq(_of_kind(r, ActionEvent.Kind.LOST).size(), 0,
		"a contact was lost on a path that ends in plain view")


## A reveal is emitted once. `mark_seen` reports news rather than truth precisely so that walking
## along in plain view does not emit a fresh `SPOT` per tile — which would be a marker flashing on
## every step of every move.
func test_staying_visible_emits_no_further_reveals() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10))
	m.add_unit(_unit(md, 2, 8, 10))
	m.active_side = 2

	var r: ActionResult = _resolver(md, m).resolve_move(1, md.idx(12, 10))
	assert_true(r.ok(), "no route")
	assert_gt(float(_of_kind(r, ActionEvent.Kind.STEP).size()), 1.0, "the fixture barely moved")
	assert_eq(_of_kind(r, ActionEvent.Kind.SPOT).size(), 0,
		"a unit already in plain view was re-revealed while driving")
	assert_eq(_of_kind(r, ActionEvent.Kind.LOST).size(), 0, "a unit in plain view was lost")


# --- the stream is still a complete account — docs/decisions/0026 -----------------------------------

func _describe_state(m: MatchState) -> String:
	var parts := PackedStringArray()
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		parts.append("u%d t%d f%d r%d mp%d mv%d a%d" % [
			k, u.tile, u.facing, u.turret, u.mp_left, u.mp_moved, 1 if u.activated else 0
		])
	for side: int in range(1, m.side_count + 1):
		parts.append("k%d %d" % [side, m.knowledge_for(side).fingerprint()])
	return "\n".join(parts)


func _capture(m: MatchState) -> Array:
	var out: Array = []
	for u: UnitState in m.units:
		out.append([u.tile, u.facing, u.turret, u.mp_left, u.mp_moved, u.activated])
	var books: Array = []
	for k: SideKnowledge in m.knowledge:
		books.append([k._visual_state.duplicate(), k._visual_tile.duplicate(),
			k._visual_facing.duplicate(), k._visual_ghost_left.duplicate()])
	out.append(books)
	return out


func _restore(m: MatchState, snap: Array) -> void:
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		var row: Array = snap[k]
		u.tile = row[0]
		u.facing = row[1]
		u.turret = row[2]
		u.mp_left = row[3]
		u.mp_moved = row[4]
		u.activated = row[5]
	var books: Array = snap[m.units.size()]
	for s: int in m.knowledge.size():
		var b: Array = books[s]
		m.knowledge[s]._visual_state = b[0]
		m.knowledge[s]._visual_tile = b[1]
		m.knowledge[s]._visual_facing = b[2]
		m.knowledge[s]._visual_ghost_left = b[3]


## The strongest assertion in the batch, and the one that makes the interrupt machinery safe to
## build. Everything the action touched — both units' full field sets, both sides' contact lists — is
## snapshotted, the action is resolved, the snapshot is restored, and the finished stream is replayed
## over the pre-action state. The two have to land in the same place.
##
## This is precisely the check that was impossible before 0026: while `commit` was the only route from
## an action to the state, it agreed with itself and nothing was learned.
func test_replaying_a_woven_stream_reproduces_the_state_resolving_left() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2

	var resolver: ActionResolver = _resolver(md, m)
	var before: Array = _capture(m)

	var r: ActionResult = resolver.resolve_move(1, md.idx(18, 8))
	assert_true(r.ok(), "no route")
	assert_gt(float(_of_kind(r, ActionEvent.Kind.SPOT).size()), 0.0,
		"the fixture produced no reveals, so this proves nothing about them")
	var resolved: String = _describe_state(m)

	_restore(m, before)
	assert_ne(_describe_state(m), resolved, "the fixture never left the pre-action state")

	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(_describe_state(m), resolved,
		"replaying the woven stream did not reproduce the state the weave left")


## And replaying it a second time changes nothing. The weave applies as it appends and `commit` may
## walk the same list again, so every arm has to survive being applied twice — the rule 0026 states.
func test_replaying_a_woven_stream_twice_changes_nothing() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2

	var resolver: ActionResolver = _resolver(md, m)
	var before: Array = _capture(m)
	var r: ActionResult = resolver.resolve_move(1, md.idx(18, 8))
	assert_true(r.ok(), "no route")
	var resolved: String = _describe_state(m)

	_restore(m, before)
	EventApplier.apply_all(cfg, md, m, r.events)
	EventApplier.apply_all(cfg, md, m, r.events)
	assert_eq(_describe_state(m), resolved, "a woven stream is not idempotent")


## With nothing to react to, the weave must cost nothing. The movement half of a woven stream has to
## be byte-identical to the planned one, or every move in the game is quietly a different move now.
func test_the_weave_changes_nothing_when_there_is_nothing_to_react_to() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 20, 20))
	# A wall between them, so nothing is ever spotted and no reveal can enter the stream.
	for y: int in md.size:
		md.blocker_h[md.idx(11, y)] = 14.0

	var planned: ActionResult = ActionResolver.new(md, cfg, m).plan_move(0, md.idx(6, 6))
	assert_true(planned.ok(), "no route")
	var expected: int = planned.fingerprint()

	var resolved: ActionResult = _resolver(md, m).resolve_move(0, md.idx(6, 6))
	assert_true(resolved.ok(), "no route")
	assert_eq(_of_kind(resolved, ActionEvent.Kind.SPOT).size(), 0, "the fixture spotted something")
	assert_eq(resolved.fingerprint(), expected,
		"the weave altered a move that nothing on the board reacted to")


## The tail is rebuilt by the weave rather than carried over from the plan, so it has to come out the
## same when nothing interrupted. `close_stream` has one implementation for exactly this reason.
func test_the_rebuilt_tail_matches_the_planned_one() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 20, 20))

	var planned: ActionResult = ActionResolver.new(md, cfg, m).plan_move(0, md.idx(9, 9))
	assert_true(planned.ok(), "no route")
	var resolved: ActionResult = _resolver(md, m).resolve_move(0, md.idx(9, 9))
	assert_true(resolved.ok(), "no route")

	assert_eq(resolved.last().describe(), planned.last().describe(), "the rebuilt END differs")
	assert_eq(resolved.exhausted(), planned.exhausted(), "the rebuilt tail disagrees about activation")
	assert_eq(resolved.mp_after, planned.mp_after, "the weave and the plan disagree about the cost")
	assert_eq(resolved.destination(), md.idx(9, 9), "the stream does not end where it was sent")


## A move that spends the unit still closes with `ACTIVATED` before `END`, through the rebuilt tail.
func test_a_move_that_spends_the_unit_is_still_marked_by_the_rebuilt_tail() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 20, 20))
	m.unit(0).mp_left = 22

	var r: ActionResult = _resolver(md, m).resolve_move(0, md.idx(4, 2))
	assert_true(r.ok(), "no route")
	assert_true(r.exhausted(), "a spent unit was not marked activated")
	assert_true(m.unit(0).activated, "the mark never reached the unit")
	assert_eq(r.last().kind, ActionEvent.Kind.END, "ACTIVATED came after END")


# --- the turn sweep and the stream agree ----------------------------------------------------------

## The turn-boundary sweep is kept as belt to the stream's braces. It is idempotent and it must agree
## with what the weave already decided — a sweep that disagreed would flip contacts every hand-over.
func test_the_turn_sweep_agrees_with_what_the_weave_decided() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	m.active_side = 2

	var resolver: ActionResolver = _resolver(md, m)
	resolver.resolve_move(1, md.idx(18, 8))
	var after_weave: int = m.knowledge_for(1).fingerprint()

	resolver.refresh_knowledge()
	assert_eq(m.knowledge_for(1).fingerprint(), after_weave,
		"the turn sweep disagreed with the reveals the weave had already made")
