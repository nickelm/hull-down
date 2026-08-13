extends TestCase

## `ViewState.filter` against streams a resolver actually produced — docs/decisions/0034.
##
## `tests/test_view_state.gd` says what the rule is, over hand-built streams. This says the rule
## survives contact with the weave: real routes, real spotting rechecks per tile entered (0025), real
## event ordering. The two fail differently and that is the point of having both — a hand-built stream
## cannot catch the filter being right about a shape the resolver never emits.
##
## The fixture is `tests/test_reactions.gd`'s wall-with-a-gap, kept deliberately identical. That file
## proves the reveal lands on the tile in the gap; this one proves the watching side is shown nothing
## before it.

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


## A wall of tall cover with one gap at y = 10. Unit 0 is side 1's watcher at the west end of the lane;
## unit 1 is side 2's mover, starting masked behind the wall and driving north through the gap.
func _screened() -> Array:
	var md: MapData = _flat()
	for y: int in md.size:
		if y == 10:
			continue
		md.blocker_h[md.idx(12, y)] = 14.0

	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10, Grid.E))
	m.add_unit(_unit(md, 2, 18, 14, Grid.N))
	m.active_side = 2

	var r := ActionResolver.new(md, cfg, m)
	r.refresh_knowledge()
	return [md, m, r]


func _tiles_of(events: Array[ActionEvent], kind: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for e: ActionEvent in events:
		if e.kind == kind:
			out.append(e.tile)
	return out


# --- the watching side ----------------------------------------------------------------------------

## The acceptance case. Side 1 watches side 2 drive out from behind cover: everything before the reveal
## must be gone from what side 1 replays, and the first thing it sees must be the reveal itself, on the
## tile that earned it.
##
## Note the ordering the test depends on, because the caller depends on it too: the mask is snapshotted
## **before** the action resolves. Resolving mutates knowledge, so a mask taken afterwards would say the
## mover had been visible all along and the filter would pass everything through.
func test_the_watcher_sees_nothing_before_the_reveal() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var before: PackedByteArray = ViewState.all(m, 1)
	assert_eq(before[1], ViewState.Kind.HIDDEN, "the mover was visible before it moved")

	var res: ActionResult = r.resolve_move(1, md.idx(18, 8))
	assert_true(res.ok(), "no route: %d" % res.status)

	var seen: Array[ActionEvent] = ViewState.filter(res.events, before, 1)
	assert_gt(float(seen.size()), 0.0, "the watcher was shown nothing at all")
	assert_eq(seen[0].kind, ActionEvent.Kind.SPOT, "the watcher's replay does not open on the reveal")

	# Everything the watcher is shown happens at or after the gap. The mover approached from the south
	# (higher y), so any tile below the gap row is one it was entitled to keep to itself.
	var reveal_row: int = md.ty(seen[0].tile)
	assert_eq(reveal_row, 10, "the reveal did not land in the gap")
	for e: ActionEvent in seen:
		if e.tile < 0:
			continue
		assert_le(float(md.ty(e.tile)), float(reveal_row),
			"the watcher was shown tile %d, south of the gap it was revealed in" % e.tile)


## The complement, and the one that would catch a filter that simply dropped everything: with the mover
## already in contact, its whole move replays for the watching side.
func test_a_mover_already_in_contact_replays_in_full() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	# Put the mover in the open lane to begin with, so contact exists before the action does.
	m.unit(1).tile = md.idx(18, 10)
	r.refresh_knowledge()

	var before: PackedByteArray = ViewState.all(m, 1)
	assert_eq(before[1], ViewState.Kind.SEEN, "the fixture did not establish contact")

	var res: ActionResult = r.resolve_move(1, md.idx(16, 10))
	assert_true(res.ok(), "no route: %d" % res.status)

	var seen: Array[ActionEvent] = ViewState.filter(res.events, before, 1)
	assert_eq(
		_tiles_of(seen, ActionEvent.Kind.STEP).size(),
		_tiles_of(res.events, ActionEvent.Kind.STEP).size(),
		"a mover in plain sight had steps withheld from the watcher"
	)


# --- the moving side ------------------------------------------------------------------------------

## The side giving the order watches its own tank in full, keeps the reveals addressed to **its own**
## knowledge, and is told nothing about what the enemy learned.
##
## Driving into the gap is mutual: side 1 gains the mover and side 2 gains the watcher, in the same
## stream, and the filter has to split them by the side each reveal is addressed to. Dropping every
## `SPOT` would pass a laxer version of this test and lose side 2 the moment it earned its own contact;
## keeping every `SPOT` would tell side 2 that it had been spotted, which is the leak running backwards.
func test_the_mover_watches_itself_but_not_the_enemys_knowledge() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var before: PackedByteArray = ViewState.all(m, 2)
	var res: ActionResult = r.resolve_move(1, md.idx(18, 8))
	assert_true(res.ok(), "no route: %d" % res.status)

	var own: Array[ActionEvent] = ViewState.filter(res.events, before, 2)

	assert_eq(
		_tiles_of(own, ActionEvent.Kind.STEP).size(),
		_tiles_of(res.events, ActionEvent.Kind.STEP).size(),
		"a side had steps of its own tank withheld from it"
	)

	var mine: int = 0
	for e: ActionEvent in own:
		if e.kind != ActionEvent.Kind.SPOT:
			continue
		assert_eq(e.value, 2, "the moving side was told the enemy had spotted it")
		mine += 1
	assert_gt(float(mine), 0.0, "driving into the open never revealed the watcher to the mover")

	# The reveal side 1 earned is in the unfiltered stream and must be the thing that got dropped.
	var theirs: int = 0
	for e: ActionEvent in res.events:
		if e.kind == ActionEvent.Kind.SPOT and e.value == 1:
			theirs += 1
	assert_gt(float(theirs), 0.0, "the fixture never revealed the mover to the watcher at all")


# --- the bracket contract -------------------------------------------------------------------------

## 0022 brackets a stream with `BEGIN` and `END`. A filtered stream is a *shorter account*, not a
## malformed one: whenever the actor is visible throughout, both brackets survive in place.
func test_a_fully_visible_stream_keeps_its_brackets() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var before: PackedByteArray = ViewState.all(m, 2)
	var res: ActionResult = r.resolve_move(1, md.idx(18, 8))
	var own: Array[ActionEvent] = ViewState.filter(res.events, before, 2)

	assert_eq(own[0].kind, ActionEvent.Kind.BEGIN, "the filtered stream lost its opening bracket")
	assert_eq(own[own.size() - 1].kind, ActionEvent.Kind.END,
		"the filtered stream lost its closing bracket")


## And when the actor is never visible, the account is empty rather than a pair of empty brackets. The
## replayer treats an empty stream as "nothing to watch" and unlocks immediately, so this is the shape
## that has to come out — a lone `BEGIN` would put a tank on screen at the tile it started from.
func test_an_invisible_actor_yields_no_brackets_at_all() -> void:
	var fixture: Array = _screened()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var before: PackedByteArray = ViewState.all(m, 1)
	# South, staying behind the wall the whole way, so no reveal ever fires.
	var res: ActionResult = r.resolve_move(1, md.idx(18, 17))
	assert_true(res.ok(), "no route: %d" % res.status)

	var seen: Array[ActionEvent] = ViewState.filter(res.events, before, 1)
	assert_eq(seen.size(), 0, "a move that stayed hidden was replayed to the watching side anyway")
