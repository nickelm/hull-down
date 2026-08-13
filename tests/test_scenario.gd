extends TestCase

## 2f and 2g — the scenario format, entrenchment, asymmetric deployment, and waves.
## docs/decisions/0041.
##
## The flat-board half tests the mechanics one rule at a time; the generated-map half at the
## bottom is the two acceptance checks — the attacking AI advances into unspotted defenders, and
## the mission plays end to end to a graded result.

const SEED := 1017
const SCENARIO_PATH := "res://data/scenarios/dig_in.json"

static var _cached: MapData = null

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


func _unit(md: MapData, side: int, x: int, y: int, type_name: String = "medium") -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


func _generated() -> MapData:
	if _cached == null:
		_cached = MapGenerator.generate_small(cfg, SEED)
	return _cached


# --- entrenchment ----------------------------------------------------------------------------------


func test_an_entrenched_tank_is_hull_down_on_open_ground() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12))
	m.add_unit(_unit(md, 2, 10, 12))
	m.unit(1).entrenched = true

	assert_eq(Spotting.exposure_between(md, cfg, m, 0, 1), Los.Exposure.HULL_DOWN,
		"a dug-in tank on a billiard table was not hull down to the eye")

	Spotting.recompute_all(md, cfg, sp, m)
	var pf: FireForecast = FireAction.preview(md, cfg, sp, HitParams.from_config(cfg), m, 0, 1)
	if pf.ok():
		assert_eq(pf.exposure, Los.Exposure.HULL_DOWN,
			"the gun disagrees with the eye about a dug-in target")

	# And never the other way: entrenchment shields the entrenched, not their enemies.
	assert_eq(Spotting.exposure_between(md, cfg, m, 1, 0), Los.Exposure.EXPOSED,
		"the attacker inherited the defender's entrenchment")


func test_entrenchment_shortens_the_range_a_tank_is_seen_at() -> void:
	var md: MapData = _flat(64)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 32))
	# 30 tiles = 300 m: inside a medium's 400 m optics in the open, outside it once the
	# entrenchment multiplier (0.5) and the hull-down exposure multiplier both apply.
	m.add_unit(_unit(md, 2, 32, 32))

	assert_true(Spotting.can_see(md, cfg, sp, m, 0, 1),
		"the fixture is broken — the target should be visible before digging in")
	m.unit(1).entrenched = true
	assert_false(Spotting.can_see(md, cfg, sp, m, 0, 1),
		"digging in did not shorten the spotting range")


func test_moving_digs_the_tank_out_permanently() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12))
	m.unit(0).entrenched = true
	var resolver := ActionResolver.new(md, cfg, m, 7)
	resolver.refresh_knowledge()

	var r: ActionResult = resolver.resolve_move(0, md.idx(6, 12))
	assert_true(r.ok(), "the fixture's move was refused")
	assert_false(m.unit(0).entrenched, "driving off the position kept the entrenchment")

	# And it does not come back at the turn boundary — the position was left, not rested.
	resolver.end_turn()
	resolver.end_turn()
	assert_false(m.unit(0).entrenched, "entrenchment regenerated at a turn boundary")


func test_traversing_the_turret_does_not_dig_the_tank_out() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12))
	m.unit(0).entrenched = true
	var resolver := ActionResolver.new(md, cfg, m, 7)

	var r: ActionResult = resolver.resolve_turret(0, Grid.NE)
	assert_true(r.ok(), "the traverse was refused")
	assert_true(m.unit(0).entrenched,
		"swinging the gun broke the camouflage — only the hull moving should")


func test_firing_reveals_but_does_not_dig_out() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12))
	m.add_unit(_unit(md, 2, 10, 12))
	m.unit(0).entrenched = true
	var resolver := ActionResolver.new(md, cfg, m, 7)
	resolver.refresh_knowledge()

	var r: ActionResult = resolver.resolve_fire(0, 1)
	assert_true(r.ok(), "the fixture's shot was refused")
	assert_true(m.unit(0).entrenched,
		"firing dug the tank out — a dug-in gun that shoots is revealed, and still hull down")


# --- off-board reserves — 2g -----------------------------------------------------------------------


func _with_reserve(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12))
	m.add_unit(_unit(md, 2, 20, 12))
	var reserve: UnitState = _unit(md, 2, 0, 0)
	reserve.on_board = false
	reserve.tile = -1
	reserve.arrival_turn = 3
	reserve.arrival_edge = Grid.E
	m.add_unit(reserve)
	return m


func test_a_reserve_is_absent_from_the_board_in_every_sense() -> void:
	var md: MapData = _flat()
	var m: MatchState = _with_reserve(md)

	assert_false(m.side_units(2).has(2), "an off-board reserve is cyclable")
	assert_eq(m.side_alive_count(2), 2, "the reserve does not count as alive")
	assert_eq(m.occupancy(md.n).count(1), 2, "an off-board reserve blocks a tile")

	Spotting.recompute_all(md, cfg, sp, m)
	assert_false(m.knowledge_for(1).knows_of(2), "side 1 spotted a tank that has not arrived")


func test_a_side_reduced_to_reserves_is_not_annihilated() -> void:
	var md: MapData = _flat()
	var m: MatchState = _with_reserve(md)
	m.unit(1).alive = false

	assert_eq(Victory.evaluate(md, cfg, m), 0,
		"a side with a wave still coming was declared annihilated")

	# And the hand-over still gives that side its turns, or the wave could never arrive.
	m.end_turn(cfg)
	assert_eq(m.active_side, 2, "the reserves' side was skipped at the hand-over")


func test_a_wave_arrives_on_its_turn_at_its_edge() -> void:
	var md: MapData = _flat()
	var m: MatchState = _with_reserve(md)
	var sc := Scenario.new()

	# Not due yet: side 2's turn on turn 1.
	m.end_turn(cfg)
	assert_true(sc.spawn_due(md, cfg, m).is_empty(), "the wave arrived early")

	m.turn = 3
	var spawned: PackedInt32Array = sc.spawn_due(md, cfg, m)
	assert_eq(spawned, PackedInt32Array([2]), "the due wave did not arrive on its turn")
	var u: UnitState = m.unit(2)
	assert_true(u.on_board, "the spawned unit is still off-board")
	assert_ge(float(md.tx(u.tile)), float(md.size - 4), "an east-edge wave arrived somewhere else")
	assert_true(md.is_passable(u.tile), "the wave arrived on impassable ground")


# --- the scenario file -----------------------------------------------------------------------------


func test_list_available_finds_the_dig_in_mission() -> void:
	var listed: Array[Dictionary] = Scenario.list_available()
	var found: bool = false
	for entry: Dictionary in listed:
		if str(entry["name"]) == "Dig In":
			found = true
			assert_not_null(Scenario.load_file(str(entry["path"])),
				"the listed path does not load")
	assert_true(found, "the dig-in mission is not enumerated")


func test_list_available_is_sorted_skips_garbage_and_names_the_nameless() -> void:
	var dir := "user://test_scenarios_tmp"
	DirAccess.make_dir_recursive_absolute(dir)
	for pair: Array in [
		["b_second.json", "{\"name\": \"Bravo\", \"map_seed\": 1}"],
		["a_first.json", "{\"name\": \"Alpha\", \"map_seed\": 1}"],
		["c_unnamed.json", "{\"map_seed\": 1}"],
		["broken.json", "not json at all"],
		["notes.txt", "not a mission"],
	]:
		var fa: FileAccess = FileAccess.open(dir.path_join(str(pair[0])), FileAccess.WRITE)
		fa.store_string(str(pair[1]))
		fa.close()

	var listed: Array[Dictionary] = Scenario.list_available(dir)
	assert_eq(listed.size(), 3, "expected the two named missions plus the nameless one")
	if listed.size() == 3:
		assert_eq(str(listed[0]["name"]), "Alpha", "the list is not in filename order")
		assert_eq(str(listed[1]["name"]), "Bravo", "the list is not in filename order")
		assert_eq(str(listed[2]["name"]), "c_unnamed",
			"a nameless mission should fall back to its filename stem")

	for f: String in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func test_the_dig_in_scenario_parses() -> void:
	var sc: Scenario = Scenario.load_file(SCENARIO_PATH)
	assert_not_null(sc, "the scenario file did not parse")
	if sc == null:
		return
	assert_eq(sc.forces.size(), 2, "the scenario should field two sides")
	assert_gt(float(sc.turn_limit), 0.0, "the mission has no clock")

	var attacker: Scenario.Force = sc.forces[0]
	var defender: Scenario.Force = sc.forces[1]
	assert_eq(defender.deploy, &"objectives", "the defender does not deploy on the objectives")
	assert_true(defender.entrenched, "the defender does not start dug in")
	assert_eq(attacker.deploy, &"zone", "the attacker does not deploy from its zone")

	# 2g's ratio: attacker outnumbers defender three or four to one, counting the waves.
	var attackers: int = attacker.units.size()
	for wave: Scenario.Wave in attacker.waves:
		attackers += wave.units.size()
	var ratio: float = float(attackers) / float(defender.units.size())
	assert_in_range(ratio, 3.0, 4.0, "the attacker fields %.1f to one" % ratio)

	# Every unit named in the scenario exists in units.json.
	for f: Scenario.Force in sc.forces:
		for type_name: String in f.units:
			assert_false(cfg.unit(type_name).is_empty(), "unknown unit '%s'" % type_name)
		for wave2: Scenario.Wave in f.waves:
			for type_name2: String in wave2.units:
				assert_false(cfg.unit(type_name2).is_empty(), "unknown unit '%s'" % type_name2)


## The wave attacker is worse than the defense on every quality axis — 2g's composition claim,
## asserted against the data so a retune cannot quietly hand the attacker good eyes.
func test_the_assault_tank_is_poor_on_every_axis_but_numbers() -> void:
	var assault: Dictionary = cfg.unit("assault")
	var medium: Dictionary = cfg.unit("medium")
	assert_false(assault.is_empty(), "the assault tank is missing from units.json")

	assert_lt(float((assault["armor"] as Dictionary)["front"]),
		float((medium["armor"] as Dictionary)["front"]), "the assault tank is not thin-skinned")
	assert_lt(float((assault["gun"] as Dictionary)["penetration_mm"]),
		float((medium["armor"] as Dictionary)["front"]),
		"the assault gun goes through a medium's front plate — flanking is optional")
	for other: String in ["light", "medium", "heavy"]:
		assert_lt(float((assault["optics"] as Dictionary)["base_range_m"]),
			float((cfg.unit(other)["optics"] as Dictionary)["base_range_m"]),
			"the assault tank sees as far as the '%s'" % other)


# --- acceptance, on the generated map --------------------------------------------------------------


func test_the_defense_deploys_around_the_objectives_unspotted() -> void:
	var md: MapData = _generated()
	if md == null:
		fail_hard("seed %d no longer generates" % SEED)
		return
	var sc: Scenario = Scenario.load_file(SCENARIO_PATH)
	var m: MatchState = sc.build_state(md, cfg)
	var resolver := ActionResolver.new(md, cfg, m, SEED)
	resolver.refresh_knowledge()

	var radius: float = 0.0
	for f: Scenario.Force in sc.forces:
		if f.deploy == &"objectives":
			radius = float(f.radius_tiles)

	var defenders: PackedInt32Array = m.side_units(2)
	assert_eq(defenders.size(), 4, "the defense did not deploy whole")
	for k: int in defenders.size():
		var u: UnitState = m.unit(defenders[k])
		assert_true(u.entrenched, "a defender deployed without its entrenchment")
		var nearest: float = INF
		for o: int in md.objectives.size():
			nearest = minf(nearest, float(maxi(
				absi(md.tx(u.tile) - md.tx(md.objectives[o])),
				absi(md.ty(u.tile) - md.ty(md.objectives[o]))
			)))
		assert_le(nearest, radius, "a defender deployed %0.f tiles from any objective" % nearest)

	# The attacker knows nothing — the whole point of the mission.
	assert_eq(m.knowledge_for(1).known_units().size(), 0,
		"the attacker starts the mission already seeing the dug-in defense")


func test_the_attacking_ai_advances_into_the_unspotted_defense() -> void:
	var md: MapData = _generated()
	if md == null:
		fail_hard("seed %d no longer generates" % SEED)
		return
	var sc: Scenario = Scenario.load_file(SCENARIO_PATH)
	var policies: Array[Policy] = [UtilityPolicy.new(SEED), NullPolicy.new()]
	var runner: MatchRunner = MatchRunner.for_scenario(md, cfg, sc, SEED, policies)

	var attackers: PackedInt32Array = runner.state.side_units(1)
	var before: float = _mean_objective_dist(md, runner.state, attackers)
	assert_eq(runner.state.knowledge_for(1).known_units().size(), 0,
		"the attacker can already see the defense")

	runner.step()   # attacker's first turn
	var after: float = _mean_objective_dist(md, runner.state, attackers)
	assert_lt(after, before, "the attacking AI did not advance toward the objectives")


func _mean_objective_dist(md: MapData, m: MatchState, units: PackedInt32Array) -> float:
	var total: float = 0.0
	var counted: int = 0
	for k: int in units.size():
		var u: UnitState = m.unit(units[k])
		if u == null or not u.alive or not u.on_board:
			continue
		var nearest: float = INF
		for o: int in md.objectives.size():
			nearest = minf(nearest, md.dist_m(u.tile, md.objectives[o]))
		total += nearest
		counted += 1
	return total / float(maxi(counted, 1))


## 2g's acceptance: the mission is playable end to end and produces a graded result, with the
## waves actually arriving along the way.
func test_the_mission_plays_end_to_end_to_a_graded_result() -> void:
	var md: MapData = _generated()
	if md == null:
		fail_hard("seed %d no longer generates" % SEED)
		return
	var sc: Scenario = Scenario.load_file(SCENARIO_PATH)
	var policies: Array[Policy] = [UtilityPolicy.new(SEED), UtilityPolicy.new(SEED + 1)]
	var runner: MatchRunner = MatchRunner.for_scenario(md, cfg, sc, SEED, policies)
	var s: Dictionary = runner.play()

	assert_le(float(s["turns"]), float(sc.turn_limit + 1), "the mission ran past its clock")
	assert_eq(int(s["grade_1"]), -int(s["grade_2"]), "the grades do not mirror")
	assert_in_range(float(int(s["grade_1"])),
		float(Victory.Grade.DECISIVE_DEFEAT), float(Victory.Grade.DECISIVE_VICTORY),
		"the attacker's grade is off the ladder")

	# Every wave whose turn came arrived on the board (or died trying — arrived either way).
	for k: int in runner.state.units.size():
		var u: UnitState = runner.state.units[k]
		if u.arrival_turn > 0 and u.arrival_turn < runner.state.turn:
			assert_true(u.on_board, "a wave due on turn %d never arrived" % u.arrival_turn)
