extends TestCase

## The spotting rules — docs/decisions/0024, and docs/design/rules.md 3.3.
##
## There is no RNG anywhere in this file and there must never be one: spotting is deterministic, and
## every assertion below is an exact answer rather than a band. That is the property that lets the
## move preview say where you will be seen before you commit to driving there.
##
## The maps are hand-built and flat, with terrain set *after* the transitions are classified — so
## `md.terrain` (which is what concealment reads) can be changed without disturbing `md.move_cost` or
## `md.blocker_h` (which is what line of sight reads). Concealment and occlusion are separate axes
## here on purpose; a fixture that moved both at once could pass for the wrong reason.

var cfg: Config
var p: SpottingParams


func setup() -> void:
	cfg = Config.load_default()
	p = SpottingParams.from_config(cfg)


func _flat(size: int = 20) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, type_name: String = "medium") -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


func _pair(md: MapData, ax: int, ay: int, bx: int, by: int, type_name: String = "medium") -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, ax, ay, type_name))
	m.add_unit(_unit(md, 2, bx, by, type_name))
	return m


func _optics(type_name: String) -> float:
	return float((cfg.unit(type_name)["optics"] as Dictionary)["base_range_m"])


# --- asymmetry, which is the headline claim -------------------------------------------------------

## A spotting B implies nothing about B spotting A.
##
## Two identical mediums, fourteen tiles apart on flat ground with clear sight both ways. The only
## difference is the ground they stand on: one is in the open, one in heavy woods. The tank in the
## open is visible at four hundred meters; the one in the woods is not visible past a hundred. So the
## contact runs one way and only one way, in the same call pair, and this is what gives a recon
## vehicle a job.
func test_spotting_runs_one_way_when_the_ground_is_not_the_same() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 16, 10)
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY

	var dist: float = md.dist_m(m.unit(0).tile, m.unit(1).tile)
	assert_almost_eq(dist, 140.0, 0.001, "the fixture is not the distance the reasoning assumes")

	assert_true(Spotting.can_see(md, cfg, p, m, 1, 0),
		"the tank in the woods cannot see the one standing in the open at %.0f m" % dist)
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 1),
		"the tank in the open can see one hidden in heavy woods at %.0f m" % dist)


## The same asymmetry, with the ground held constant and the optics varied instead. A light tank sees
## a heavy before the heavy sees it — which is the entire argument for the optics spread in
## units.json being a real number rather than flavor text.
func test_better_optics_see_first() -> void:
	var md: MapData = _flat(40)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 20, "light"))
	m.add_unit(_unit(md, 2, 38, 20, "heavy"))
	md.terrain[m.unit(0).tile] = TerrainTyper.Type.WOODS_HEAVY
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY

	# light optics 500 x 0.25 = 125 m; heavy optics 320 x 0.25 = 80 m; the pair is 360 m apart, so
	# neither reaches — bring them to 100 m, between the two thresholds.
	m.unit(1).tile = md.idx(12, 20)
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY
	assert_almost_eq(md.dist_m(m.unit(0).tile, m.unit(1).tile), 100.0, 0.001, "fixture distance")

	assert_true(Spotting.can_see(md, cfg, p, m, 0, 1), "the light tank's optics bought it nothing")
	assert_false(Spotting.can_see(md, cfg, p, m, 1, 0), "the heavy tank saw as far as the light one")


# --- knowledge is side-level ----------------------------------------------------------------------

## One tank sees it, the whole side sees it. The second unit of side 1 has no line of sight at all and
## is never consulted — that is the point of a side-level model, and it is what stops the player
## having to remember which of their tanks is looking at what.
func test_one_unit_seeing_it_puts_it_on_the_whole_sides_list() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10))    # 0: far away, in the open, will see it
	m.add_unit(_unit(md, 1, 2, 2))     # 1: behind a wall, sees nothing
	m.add_unit(_unit(md, 2, 8, 10))    # 2: the target

	# A screen of tall cover between unit 1 and the target, and nothing else.
	for y: int in range(0, 8):
		md.blocker_h[md.idx(5, y)] = 12.0

	assert_true(Spotting.can_see(md, cfg, p, m, 0, 2), "the fixture's observer cannot see the target")
	assert_false(Spotting.can_see(md, cfg, p, m, 1, 2), "the blind observer can see through the wall")

	var gained := PackedInt32Array()
	var lost := PackedInt32Array()
	assert_true(Spotting.recompute_side(md, cfg, p, m, 1, gained, lost), "nothing changed at all")
	assert_eq(gained.size(), 1, "the sighting was not reported once")
	assert_eq(gained[0], 2, "the wrong unit was reported")
	assert_true(m.knowledge_for(1).sees(2), "the side does not hold a contact one of its units has")


## A side never puts its own units on its contact list. They are not contacts, they are yours, and a
## model that reported them would make every "how many do we know about" answer wrong.
func test_a_side_does_not_spot_itself() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 4, 10)
	m.add_unit(_unit(md, 1, 3, 10))

	var gained := PackedInt32Array()
	var lost := PackedInt32Array()
	Spotting.recompute_side(md, cfg, p, m, 1, gained, lost)
	assert_false(m.knowledge_for(1).knows_of(0), "a side listed itself as a contact")
	assert_false(m.knowledge_for(1).knows_of(2), "a side listed a friendly unit as a contact")
	assert_true(m.knowledge_for(1).sees(1), "the actual enemy was not spotted")


## Losing sight leaves a ghost where the contact was, and the whole cycle runs through one function.
func test_driving_out_of_sight_leaves_a_ghost_where_it_was() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 8, 10)
	var gained := PackedInt32Array()
	var lost := PackedInt32Array()

	Spotting.recompute_side(md, cfg, p, m, 1, gained, lost)
	assert_true(m.knowledge_for(1).sees(1), "the target was never spotted")

	var was: int = m.unit(1).tile
	md.terrain[was] = TerrainTyper.Type.WOODS_HEAVY
	m.unit(1).tile = md.idx(18, 10)   # well beyond the woods threshold
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY

	Spotting.recompute_side(md, cfg, p, m, 1, gained, lost)
	assert_eq(lost.size(), 1, "losing the contact was not reported")
	assert_eq(m.knowledge_for(1).state_of(1), SideKnowledge.State.GHOST, "no ghost was left behind")
	assert_eq(m.knowledge_for(1).ghost_tile(1), md.idx(18, 10),
		"the ghost was left at the tile the target was first seen on, not where it was lost")
	assert_eq(m.knowledge_for(1).ghost_turns_left(1), p.ghost_turns,
		"the ghost did not start with the life the rules give it")


# --- the three modifiers --------------------------------------------------------------------------

## Concealment scales the range by exactly the number in the data file, and nothing else. Asserted as
## a ratio rather than as a threshold, so a retune of the table moves the test with it instead of
## breaking it.
func test_concealment_scales_the_range_by_the_table() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 12, 10)
	var tracked: int = MovementClass.Kind.TRACKED

	md.terrain[m.unit(1).tile] = TerrainTyper.Type.OPEN
	var in_open: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)

	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY
	var in_woods: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)

	assert_almost_eq(in_open, _optics("medium"), 0.01, "an open tile is not the unmodified range")
	assert_almost_eq(
		in_woods,
		in_open * cfg.concealment(tracked, TerrainTyper.Type.WOODS_HEAVY),
		0.01,
		"the range in heavy woods is not the open range times the table's multiplier"
	)


## The axis the per-class table exists for, before the units that need it exist. Same tile, same
## optics, same distance — a foot unit is spotted at strictly shorter range than a tracked one, and
## if that ever stops being true the restructure in 0028 bought four identical rows.
func test_the_same_ground_hides_infantry_better_than_armor() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 10, 10)
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY

	assert_almost_eq(md.dist_m(m.unit(0).tile, m.unit(1).tile), 80.0, 0.001, "fixture distance")
	assert_true(Spotting.can_see(md, cfg, p, m, 0, 1), "a tank in heavy woods is invisible at 80 m")

	m.unit(1).movement_class = MovementClass.Kind.FOOT
	assert_lt(
		Spotting.target_range_m(md, cfg, p, m, 0, 1),
		_optics("medium") * cfg.concealment(MovementClass.Kind.TRACKED, TerrainTyper.Type.WOODS_HEAVY),
		"a rifle section is spotted as far away as a tank on the same ground"
	)
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 1),
		"a rifle section in heavy woods is as visible at 80 m as the tank was")


## Movement is a ramp, not a switch. A tank that crept one tile stays nearly as hidden as one that
## never moved; a tank that spent its whole allowance is loud enough to be seen half again as far.
## This is the shape the modifier was asked for, and a binary flag would fail the middle assertion.
func test_how_hard_it_drove_widens_the_range_in_proportion() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 12, 10)
	var t: UnitState = m.unit(1)

	t.mp_moved = 0
	var still: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)
	t.mp_moved = 14
	var crept: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)
	t.mp_moved = t.mp_max / 2
	var half: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)
	t.mp_moved = t.mp_max
	var flat_out: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)

	assert_almost_eq(still, _optics("medium"), 0.01, "a stationary unit is not at the base range")
	assert_almost_eq(flat_out, still * p.moved_max_mult, 0.01,
		"a unit that spent everything is not at the full movement multiplier")
	assert_lt(crept, half, "creeping and driving half the turn are treated the same")
	assert_lt(half, flat_out, "driving half the turn and sprinting are treated the same")

	# The ramp is linear, so half the allowance is half the way up it.
	assert_almost_eq(half, still + (flat_out - still) * 0.5, 0.5, "the movement ramp is not linear")

	# Spending everything on a *shorter* turn is just as loud. mp_max is the denominator because the
	# question is how hard it drove, not how much it had to start with.
	t.mp_moved = t.mp_max * 2
	assert_almost_eq(Spotting.target_range_m(md, cfg, p, m, 0, 1), flat_out, 0.01,
		"the movement ramp is not clamped at the top")


## Hull down is harder to see than exposed, asserted directly on the range rather than through a
## geometry that could produce the right answer for the wrong reason.
func test_a_hull_down_target_is_seen_at_shorter_range_than_an_exposed_one() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 12, 10)

	var exposed: float = Spotting.effective_range_m(md, cfg, p, m, 0, 1, Los.Exposure.EXPOSED)
	var hull_down: float = Spotting.effective_range_m(md, cfg, p, m, 0, 1, Los.Exposure.HULL_DOWN)
	var masked: float = Spotting.effective_range_m(md, cfg, p, m, 0, 1, Los.Exposure.MASKED)

	assert_lt(hull_down, exposed, "hull down buys nothing against being spotted")
	assert_eq(masked, 0.0, "a masked target has a spotting range at all")


## The early-out's licence, swept rather than argued.
##
## `can_see` rejects a pair without casting a ray when the distance already exceeds the range *before*
## exposure is applied. That is sound only while exposure can shrink a range and never grow one. If
## this ever fails, spotting starts silently missing contacts that are genuinely visible, and nothing
## else in the suite would notice.
func test_exposure_can_only_ever_shrink_the_range() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 12, 10)

	for terrain: int in cfg.type_count():
		md.terrain[m.unit(1).tile] = terrain
		for moved: int in [0, 50, m.unit(1).mp_max]:
			m.unit(1).mp_moved = moved
			var before: float = Spotting.target_range_m(md, cfg, p, m, 0, 1)
			for exposure: int in [Los.Exposure.MASKED, Los.Exposure.HULL_DOWN, Los.Exposure.EXPOSED]:
				assert_le(
					Spotting.effective_range_m(md, cfg, p, m, 0, 1, exposure), before,
					"exposure %d on '%s' grew the range past its pre-exposure value"
						% [exposure, cfg.terrain_names[terrain]]
				)


# --- point blank and reveal-on-fire ---------------------------------------------------------------

## Close enough is close enough. A target inside `point_blank_m` is seen whatever the ground and
## whatever it is doing — but line of sight still applies, because you cannot see a tank through a
## hill however near it is.
func test_a_target_close_enough_is_seen_whatever_the_ground_says() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 6, 10, 10, 10, "heavy")
	m.unit(1).movement_class = MovementClass.Kind.FOOT
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY

	var dist: float = md.dist_m(m.unit(0).tile, m.unit(1).tile)
	assert_almost_eq(dist, 40.0, 0.001, "fixture distance")
	assert_lt(Spotting.target_range_m(md, cfg, p, m, 0, 1), dist,
		"the fixture is not actually beyond its own spotting range")
	assert_le(dist, p.point_blank_m, "the fixture is not inside point blank")

	assert_true(Spotting.can_see(md, cfg, p, m, 0, 1), "a target inside point blank was not seen")

	# The same target, behind cover. Point blank is a range rule, not an x-ray.
	md.blocker_h[md.idx(8, 10)] = 12.0
	assert_eq(Los.classify(md, cfg, m.unit(0).tile, m.unit(1).tile), Los.Exposure.MASKED,
		"the fixture's screen does not actually block sight")
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 1), "point blank saw through a hill")


## A muzzle flash is not subtle. Having fired, a unit is seen by anything with line of sight to it at
## any range — which is what makes firing a commitment rather than a free action.
func test_firing_reveals_a_unit_at_any_range() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 16, 10)
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 1), "the fixture starts already visible")

	m.unit(1).fired_this_turn = true
	assert_true(Spotting.can_see(md, cfg, p, m, 0, 1), "firing did not reveal the firer")

	# And still not through a ridge.
	md.blocker_h[md.idx(9, 10)] = 12.0
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 1), "a muzzle flash was seen through a hill")


# --- line of sight is a gate, not a modifier ------------------------------------------------------

func test_no_line_of_sight_means_no_contact_however_close() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 4, 10)
	md.blocker_h[md.idx(3, 10)] = 12.0

	assert_false(Spotting.can_see(md, cfg, p, m, 0, 1), "a masked target two tiles away was spotted")
	assert_false(Spotting.can_see(md, cfg, p, m, 1, 0), "masking is not symmetric in this fixture")


func test_a_unit_does_not_spot_itself_or_a_unit_that_is_not_there() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 6, 10)
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 0), "a unit spotted itself")
	assert_false(Spotting.can_see(md, cfg, p, m, 0, 99), "a unit spotted something that is not there")
	assert_false(Spotting.can_see(md, cfg, p, m, -1, 1), "a unit that is not there spotted something")


# --- the sweep ------------------------------------------------------------------------------------

## Running the sweep twice in a row must report nothing the second time. It is the belt to the event
## stream's braces and it runs at every turn boundary, so an idempotence failure here would emit a
## fresh reveal for every contact on the board, every turn.
func test_sweeping_a_second_time_reports_nothing_new() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 8, 10)
	var gained := PackedInt32Array()
	var lost := PackedInt32Array()

	assert_true(Spotting.recompute_side(md, cfg, p, m, 1, gained, lost), "the first sweep saw nothing")
	assert_false(Spotting.recompute_side(md, cfg, p, m, 1, gained, lost),
		"the second sweep reported a change that had already happened")
	assert_eq(gained.size(), 0, "the second sweep reported a fresh sighting")
	assert_eq(lost.size(), 0, "the second sweep reported a fresh loss")


## `recompute_all` covers every side, and the two sides genuinely disagree — the whole point of the
## asymmetry is that one contact list is not the other's mirror.
func test_the_sweep_covers_every_side_and_they_can_disagree() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md, 2, 10, 16, 10)
	md.terrain[m.unit(1).tile] = TerrainTyper.Type.WOODS_HEAVY

	Spotting.recompute_all(md, cfg, p, m)
	assert_false(m.knowledge_for(1).sees(1), "side 1 spotted the tank hiding in heavy woods")
	assert_true(m.knowledge_for(2).sees(0), "side 2 did not spot the tank standing in the open")
	assert_ne(m.knowledge_for(1).fingerprint(), m.knowledge_for(2).fingerprint(),
		"two sides with genuinely different information fingerprint the same")
