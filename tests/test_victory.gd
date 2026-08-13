extends TestCase

## Holding objectives to win — `docs/design/rules.md` §6.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _map(size: int = 30) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	md.objectives = PackedInt32Array([md.idx(5, 5), md.idx(15, 15), md.idx(25, 25)])
	return md


func _unit(md: MapData, side: int, x: int, y: int) -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), "medium")
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


func _state(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 28, 28))
	return m


# --- holding ---------------------------------------------------------------------------------------

func test_nobody_holds_an_objective_nobody_is_near() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	for k: int in md.objectives.size():
		assert_eq(Victory.holder_of(md, cfg, m, md.objectives[k]), 0,
			"objective %d was held with nobody on it" % k)


func test_standing_on_an_objective_holds_it() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	m.unit(0).tile = md.idx(5, 5)
	assert_eq(Victory.holder_of(md, cfg, m, md.idx(5, 5)), 1, "standing on it did not hold it")

	# And the capture radius really is a radius, not just the tile.
	var radius: int = cfg.i("victory.capture_radius_tiles", 1)
	m.unit(0).tile = md.idx(5 + radius, 5)
	assert_eq(Victory.holder_of(md, cfg, m, md.idx(5, 5)), 1, "the capture radius is not honored")
	m.unit(0).tile = md.idx(5 + radius + 1, 5)
	assert_eq(Victory.holder_of(md, cfg, m, md.idx(5, 5)), 0, "the capture radius has no edge")


## Contested is nobody's. Walking a scout onto a tile the enemy is sitting on does not take it off
## them, which is what stops the last turn of a match being a race of suicidal dashes.
func test_an_objective_both_sides_are_on_is_held_by_neither() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	m.unit(0).tile = md.idx(5, 5)
	m.unit(1).tile = md.idx(5, 6)
	assert_eq(Victory.holder_of(md, cfg, m, md.idx(5, 5)), 0, "a contested objective was awarded")


## A wreck holds nothing. It still blocks its tile — that is 0031 — but it is not a garrison.
func test_a_wreck_does_not_hold_an_objective() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	m.unit(0).tile = md.idx(5, 5)
	m.unit(0).alive = false
	assert_eq(Victory.holder_of(md, cfg, m, md.idx(5, 5)), 0, "a burnt-out tank held ground")


## The seam the capture ticker diffs across (docs/decisions/0044): a resolved move into the
## capture radius flips `held_by` immediately — possession is occupancy, not something `tick`
## confers at the boundary.
func test_a_resolved_move_onto_an_objective_flips_held_by() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	# Outside the capture radius to start, or the flag is held before the move.
	m.unit(0).tile = md.idx(5 - cfg.i("victory.capture_radius_tiles", 1) - 2, 5)
	var resolver := ActionResolver.new(md, cfg, m, 7)
	resolver.refresh_knowledge()

	var before: PackedInt32Array = Victory.held_by(md, cfg, m)
	assert_eq(before, PackedInt32Array([0, 0, 0]), "the fixture starts with a flag already held")

	var r: ActionResult = resolver.resolve_move(0, md.idx(5, 5))
	assert_true(r.ok(), "the fixture's move was refused")

	var after: PackedInt32Array = Victory.held_by(md, cfg, m)
	assert_eq(after, PackedInt32Array([1, 0, 0]), "driving onto the flag did not take it")


# --- the count ---------------------------------------------------------------------------------------

## Held for how many turns *in a row*. A side that loses an objective and retakes it has not been
## holding it throughout, and the counter has to say so or `hold_turns` means nothing.
func test_holding_is_counted_in_consecutive_turns() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	m.unit(0).tile = md.idx(5, 5)

	Victory.tick(md, cfg, m)
	assert_eq(m.objective_holder[0], 1, "the holder was not recorded")
	assert_eq(m.objective_held_turns[0], 1, "the first turn of holding was not counted")

	Victory.tick(md, cfg, m)
	assert_eq(m.objective_held_turns[0], 2, "a second turn of holding was not counted")

	# Driven off, and the count starts again from nothing.
	m.unit(0).tile = md.idx(20, 20)
	Victory.tick(md, cfg, m)
	assert_eq(m.objective_holder[0], 0, "the objective was still recorded as held")
	assert_eq(m.objective_held_turns[0], 0, "the count survived losing the objective")

	m.unit(0).tile = md.idx(5, 5)
	Victory.tick(md, cfg, m)
	assert_eq(m.objective_held_turns[0], 1, "retaking an objective resumed the old count")


# --- winning ---------------------------------------------------------------------------------------

func test_the_match_is_undecided_while_both_sides_are_short() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	assert_eq(Victory.evaluate(md, cfg, m), 0, "somebody won before anything happened")

	m.unit(0).tile = md.idx(5, 5)
	for _turn: int in 5:
		Victory.tick(md, cfg, m)
	assert_eq(Victory.evaluate(md, cfg, m), 0,
		"one objective held forever won a match that needs more than one")


func test_holding_enough_objectives_for_long_enough_wins() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	var need: int = cfg.i("victory.objectives_to_win", 2)
	var hold: int = cfg.i("victory.hold_turns", 2)

	# Enough units of side 1 to garrison the objectives it needs.
	for k: int in need:
		if k < m.units.size() and m.unit(k).side == 1:
			m.unit(k).tile = md.objectives[k]
		else:
			var extra: UnitState = _unit(md, 1, 0, 0)
			extra.tile = md.objectives[k]
			m.add_unit(extra)

	for turn: int in hold:
		Victory.tick(md, cfg, m)
		if turn < hold - 1:
			assert_eq(Victory.evaluate(md, cfg, m), 0,
				"the match was won after %d of the %d turns needed" % [turn + 1, hold])
	assert_eq(Victory.evaluate(md, cfg, m), 1, "holding the objectives long enough did not win")


## The other way to win, and what stops a match stalling: being the only side left with anything that
## can fight.
func test_the_last_side_standing_wins() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	assert_eq(Victory.evaluate(md, cfg, m), 0, "somebody had already won")

	m.unit(1).alive = false
	assert_eq(Victory.evaluate(md, cfg, m), 1, "wiping out a side did not win the match")


func test_a_side_that_holds_nothing_wins_nothing() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	m.unit(1).tile = md.idx(15, 15)
	for _turn: int in 6:
		Victory.tick(md, cfg, m)
	assert_eq(Victory.evaluate(md, cfg, m), 0,
		"one objective was enough to win against an intact enemy")


# --- grading — 2e-iii ------------------------------------------------------------------------------


func test_points_held_reads_the_objective_values() -> void:
	var md: MapData = _map()
	md.objective_value = PackedInt32Array([3, 2, 1])
	var m: MatchState = _state(md)
	m.unit(0).tile = md.idx(5, 5)

	assert_eq(Victory.points_held(md, cfg, m, 1), 3, "holding the village is worth its value")
	assert_eq(Victory.points_held(md, cfg, m, 2), 0, "the empty-handed side scored")

	# A map with no value array — every hand-built fixture until now — prices objectives at 1.
	md.objective_value = PackedInt32Array()
	assert_eq(Victory.points_held(md, cfg, m, 1), 1,
		"a valueless map must default each objective to 1, not to nothing")


func test_grades_are_symmetric_and_ordered() -> void:
	var md: MapData = _map()
	md.objective_value = PackedInt32Array([3, 2, 1])
	var m: MatchState = _state(md)

	assert_eq(Victory.grade(md, cfg, m, 1), Victory.Grade.DRAW, "an untouched match is not a draw")

	# One side holds the big objective and has drawn blood: its grade and its enemy's must mirror.
	m.unit(0).tile = md.idx(5, 5)
	m.unit(1).alive = false
	var g1: int = Victory.grade(md, cfg, m, 1)
	var g2: int = Victory.grade(md, cfg, m, 2)
	assert_eq(g1, -g2, "one side's victory is not the other side's defeat")
	assert_ge(float(g1), float(Victory.Grade.MARGINAL_VICTORY),
		"holding the village over a dead enemy graded below a marginal victory")


func test_an_outright_winner_grades_at_least_marginal() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	# Side 2 is annihilated but side 1 holds nothing: the margin alone is small, the win is real.
	m.unit(1).alive = false
	assert_eq(Victory.evaluate(md, cfg, m), 1, "the fixture no longer wins outright")
	assert_ge(float(Victory.grade(md, cfg, m, 1)), float(Victory.Grade.MARGINAL_VICTORY),
		"an outright winner was graded below marginal victory")
	assert_le(float(Victory.grade(md, cfg, m, 2)), float(Victory.Grade.MARGINAL_DEFEAT),
		"an outright loser was graded above marginal defeat")


func test_the_turn_limit_ends_the_match() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	assert_false(Victory.over(md, cfg, m), "a fresh match is already over")

	m.turn = cfg.i("victory.turn_limit", 24) + 1
	assert_true(Victory.over(md, cfg, m), "the config's turn limit did not end the match")

	# A scenario's own limit overrides the config's — 2f will lean on this.
	m.turn = 5
	assert_true(Victory.over(md, cfg, m, 4), "an explicit turn limit was ignored")
	assert_false(Victory.over(md, cfg, m, 10), "an explicit turn limit ended the match early")


## The turn boundary drives the count, so the whole thing works without anyone remembering to call it.
func test_ending_a_turn_advances_the_objective_count() -> void:
	var md: MapData = _map()
	var m: MatchState = _state(md)
	m.unit(0).tile = md.idx(5, 5)

	var resolver := ActionResolver.new(md, cfg, m, 7)
	resolver.end_turn()
	assert_eq(m.objective_holder[0], 1, "ending a turn did not record who holds what")
	assert_eq(m.objective_held_turns[0], 1, "ending a turn did not count the holding")
	assert_eq(resolver.winner(), 0, "the resolver declared a winner too early")
