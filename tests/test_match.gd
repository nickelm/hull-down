extends TestCase

## The turn structure: two units a side, side-alternating, Tab cycling, End Turn.
## docs/decisions/0012.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


## A flat, fully drivable map with two deployment zones, so deployment has somewhere to put units
## without paying for terrain generation.
func _map(size: int = 20) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for x: int in size:
		for y: int in 4:
			md.deploy_zone[md.idx(x, y)] = 1
			md.deploy_zone[md.idx(x, size - 1 - y)] = 2
	return md


func _match(per_side: int = 2, sides: int = 2) -> MatchState:
	var m: MatchState = MatchState.create(sides)
	for side: int in range(1, sides + 1):
		for k: int in per_side:
			var u := UnitState.new()
			u.side = side
			u.tile = side * 100 + k
			u.mp_max = 220
			u.mp_left = 220
			m.add_unit(u)
	m.selected = m.side_units(1)[0]
	return m


# --- turn advance ------------------------------------------------------------------------------

func test_end_turn_hands_over_to_the_other_side() -> void:
	var m: MatchState = _match()
	assert_eq(m.active_side, 1, "the match starts on side 1")
	m.end_turn()
	assert_eq(m.active_side, 2, "end turn did not hand over")
	assert_eq(m.turn, 1, "the turn number advances on the wrap, not on every hand-over")


func test_the_turn_number_advances_once_every_side_has_gone() -> void:
	var m: MatchState = _match()
	m.end_turn()
	m.end_turn()
	assert_eq(m.active_side, 1, "two hand-overs should come back round to side 1")
	assert_eq(m.turn, 2, "the turn number did not advance on the wrap")


func test_end_turn_refills_movement_points() -> void:
	var m: MatchState = _match()
	for u: UnitState in m.units:
		u.mp_left = 3
		u.activated = true

	m.end_turn()
	for k: int in m.units.size():
		var u2: UnitState = m.units[k]
		if u2.side == m.active_side:
			assert_eq(u2.mp_left, u2.mp_max, "unit %d did not get its movement points back" % k)
			assert_false(u2.activated, "unit %d is still marked as having acted" % k)
		else:
			assert_eq(u2.mp_left, 3, "unit %d belongs to the idle side and should be untouched" % k)


## A match set up with only one side populated still has to advance, or the whole loop stalls.
func test_end_turn_skips_a_side_with_no_units() -> void:
	var m: MatchState = MatchState.create(2)
	for k: int in 2:
		var u := UnitState.new()
		u.side = 1
		u.mp_left = 0
		m.add_unit(u)
	m.selected = 0

	m.end_turn()
	assert_eq(m.active_side, 1, "with only side 1 populated the turn should come straight back")
	assert_eq(m.turn, 2, "the turn number did not advance")
	assert_eq(m.units[0].mp_left, m.units[0].mp_max, "movement points were not restored")


func test_begin_turn_clears_activation() -> void:
	var u := UnitState.new()
	u.activated = true
	u.mp_left = 0
	u.begin_turn()
	assert_false(u.activated, "begin_turn left the unit marked as having acted")
	assert_eq(u.mp_left, u.mp_max, "begin_turn did not restore movement points")


# --- selection ---------------------------------------------------------------------------------

func test_only_the_active_side_can_be_selected() -> void:
	var m: MatchState = _match()
	var enemy: int = m.side_units(2)[0]
	assert_false(m.select(enemy), "an idle side's unit should not be selectable")
	assert_ne(m.selected, enemy, "the selection changed anyway")
	assert_true(m.select(m.side_units(1)[1]), "the active side's own unit was refused")


func test_cycling_wraps_in_both_directions() -> void:
	var m: MatchState = _match()
	var side: PackedInt32Array = m.side_units(1)
	assert_eq(m.cycle(1), side[1], "forward from the first unit")
	assert_eq(m.cycle(1), side[0], "forward should wrap back to the first")
	assert_eq(m.cycle(-1), side[1], "backward should wrap to the last")


func test_cycling_prefers_units_that_have_not_acted() -> void:
	var m: MatchState = _match(3, 2)
	var side: PackedInt32Array = m.side_units(1)
	m.selected = side[0]
	m.units[side[1]].activated = true

	assert_eq(m.cycle(1), side[2], "cycling should have skipped the unit that already acted")


## Once everyone is done, Tab still has to move — a key that does nothing reads as broken rather
## than as a finished turn.
func test_cycling_still_moves_when_every_unit_has_acted() -> void:
	var m: MatchState = _match()
	var side: PackedInt32Array = m.side_units(1)
	for k: int in side.size():
		m.units[side[k]].activated = true
	m.selected = side[0]

	assert_eq(m.cycle(1), side[1], "cycling stalled once every unit had acted")


func test_cycling_from_no_selection_lands_on_the_first_unit() -> void:
	var m: MatchState = _match()
	m.selected = -1
	assert_eq(m.cycle(1), m.side_units(1)[0], "forward from nothing selected")
	m.selected = -1
	assert_eq(m.cycle(-1), m.side_units(1)[0], "backward from nothing selected")


# --- activation --------------------------------------------------------------------------------

func test_a_unit_with_no_movement_left_cannot_act() -> void:
	var u := UnitState.new()
	u.mp_left = cfg.i("movement.base_ortho", 10) - 1
	assert_false(u.can_act(cfg), "a unit that cannot afford one step should be done")
	u.mp_left = cfg.i("movement.base_ortho", 10)
	assert_true(u.can_act(cfg), "a unit that can afford exactly one step is not done")


func test_remaining_counts_only_the_active_side() -> void:
	var m: MatchState = _match()
	assert_eq(m.remaining_on_side(), 2, "both of side 1's units start un-acted")
	m.mark_activated(m.side_units(1)[0])
	assert_eq(m.remaining_on_side(), 1, "marking one should leave one")
	m.mark_activated(m.side_units(1)[1])
	assert_true(m.all_activated(), "side 1 should be finished")


func test_unit_at_finds_the_occupant() -> void:
	var m: MatchState = _match()
	m.units[0].tile = 42
	assert_eq(m.unit_at(42), 0, "the unit standing on the tile was not found")
	assert_eq(m.unit_at(43), -1, "an empty tile should report nothing")


# --- deployment --------------------------------------------------------------------------------

func test_deployment_puts_two_units_on_each_side() -> void:
	var md: MapData = _map()
	var m: MatchState = Deployment.deploy(md, cfg)

	assert_eq(m.units.size(), 4, "two units a side on a two-side match")
	assert_eq(m.side_units(1).size(), 2, "side 1")
	assert_eq(m.side_units(2).size(), 2, "side 2")
	assert_ne(m.selected, -1, "deployment left nothing selected")

	for k: int in m.units.size():
		assert_true(md.is_passable(m.units[k].tile),
			"unit %d was deployed onto impassable ground" % k)


func test_deployment_puts_each_side_in_its_own_zone() -> void:
	var md: MapData = _map()
	var m: MatchState = Deployment.deploy(md, cfg)
	for k: int in m.units.size():
		var u: UnitState = m.units[k]
		assert_eq(int(md.deploy_zone[u.tile]), u.side,
			"unit %d of side %d started outside its zone" % [k, u.side])


func test_deployment_spaces_units_apart() -> void:
	var md: MapData = _map()
	var m: MatchState = Deployment.deploy(md, cfg)
	var side: PackedInt32Array = m.side_units(1)
	var a: int = m.units[side[0]].tile
	var b: int = m.units[side[1]].tile
	assert_ne(a, b, "both of side 1's units were deployed onto the same tile")


## No RNG anywhere in deployment, so the same map always sets up the same way.
func test_deployment_is_deterministic() -> void:
	var md: MapData = _map()
	var first: MatchState = Deployment.deploy(md, cfg)
	var second: MatchState = Deployment.deploy(md, cfg)
	for k: int in first.units.size():
		assert_eq(second.units[k].tile, first.units[k].tile, "unit %d moved between runs" % k)
		assert_eq(second.units[k].facing, first.units[k].facing, "unit %d turned between runs" % k)


## A zone that is entirely impassable must not deadlock deployment — falling back to any passable
## tile is worse than intended and much better than a match with no units in it.
func test_deployment_falls_back_when_a_zone_is_unusable() -> void:
	var md: MapData = _map()
	for i: int in md.n:
		if md.deploy_zone[i] == 2:
			md.move_cost[i] = -10

	var m: MatchState = Deployment.deploy(md, cfg)
	assert_eq(m.side_units(2).size(), 2, "side 2 was not deployed at all")
	for k: int in m.side_units(2).size():
		var t: int = m.units[m.side_units(2)[k]].tile
		assert_true(md.is_passable(t), "the fallback still put a unit on impassable ground")
