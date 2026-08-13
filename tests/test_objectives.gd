extends TestCase

## 2e-iii on a real generated map: objectives sit on generator features and carry their values,
## and a headless AI-versus-AI match terminates with a graded result — the acceptance check.

const SEED := 1017

## Generated once and shared across the methods — the runner makes a fresh instance per test, and
## a static survives that. Quarter-scale generation costs seconds; paying it five times would put
## this file alone over the suite's budget.
static var _cached: MapData = null

var cfg: Config
var md: MapData


func setup() -> void:
	cfg = Config.load_default()
	if _cached == null:
		_cached = MapGenerator.generate_small(cfg, SEED)
	md = _cached


func test_the_map_generated() -> void:
	assert_not_null(md, "seed %d no longer generates a connected map" % SEED)


func test_objectives_are_placed_with_values() -> void:
	if md == null:
		return
	var want: int = cfg.i("zones.objective_count", 3)
	assert_eq(md.objectives.size(), want, "the map placed the wrong number of objectives")
	assert_eq(md.objective_value.size(), md.objectives.size(),
		"objective values are not parallel to the objectives")
	for k: int in md.objectives.size():
		assert_gt(float(md.objective_worth(k)), 0.0, "objective %d is worth nothing" % k)


## The value on each objective must match the ground under it — a value-3 flag off a village is a
## scoring rule and a placement rule silently disagreeing.
func test_each_value_names_the_feature_under_it() -> void:
	if md == null:
		return
	var v_village: int = cfg.i("victory.value_village", 3)
	var v_bridge: int = cfg.i("victory.value_bridge", 2)
	for k: int in md.objectives.size():
		var t: int = md.objectives[k]
		var v: int = md.objective_worth(k)
		assert_true(md.is_passable(t), "objective %d sits on impassable ground" % k)
		if v == v_village:
			assert_eq(int(md.terrain[t]), TerrainTyper.Type.VILLAGE,
				"objective %d is priced as a village and is not on one" % k)
		elif v == v_bridge:
			assert_eq(int(md.water[t]), MapData.Water.BRIDGE,
				"objective %d is priced as a bridge and is not on one" % k)


## A map that has villages must use one — the round-robin exists so features outrank bare hills.
func test_a_village_map_fields_a_village_objective() -> void:
	if md == null:
		return
	var has_village_tile: bool = false
	for i: int in md.n:
		if md.terrain[i] == TerrainTyper.Type.VILLAGE and md.deploy_zone[i] == 0:
			has_village_tile = true
			break
	if not has_village_tile:
		return   # this seed built no reachable village; nothing to assert
	var v_village: int = cfg.i("victory.value_village", 3)
	var found: bool = false
	for k: int in md.objectives.size():
		if md.objective_worth(k) == v_village:
			found = true
	assert_true(found, "the map has villages and no objective landed on one")


func test_objectives_round_trip_through_the_codec() -> void:
	if md == null:
		return
	var path: String = "user://maps/test_objectives.hdmap"
	assert_eq(MapCodec.save(md, path), OK, "the map did not save")
	var back: MapData = MapCodec.load_map(path)
	assert_not_null(back, "the map did not load back")
	if back == null:
		return
	assert_eq(back.objectives, md.objectives, "objectives changed in the round trip")
	assert_eq(back.objective_value, md.objective_value, "values changed in the round trip")
	assert_eq(back.content_hash(), md.content_hash(), "the round trip changed the map's identity")


## The acceptance check: a headless AI-versus-AI match terminates with a graded result.
func test_an_ai_match_terminates_with_a_graded_result() -> void:
	if md == null:
		return
	var policies: Array[Policy] = [UtilityPolicy.new(SEED), UtilityPolicy.new(SEED + 1)]
	var runner: MatchRunner = MatchRunner.create(md, cfg, SEED, policies)
	var s: Dictionary = runner.play()

	var limit: int = cfg.i("victory.turn_limit", 24)
	assert_le(float(s["turns"]), float(limit + 1), "the match ran past its turn limit")

	for side: int in [1, 2]:
		var g: int = int(s["grade_%d" % side])
		assert_in_range(float(g),
			float(Victory.Grade.DECISIVE_DEFEAT), float(Victory.Grade.DECISIVE_VICTORY),
			"side %d's grade is off the ladder" % side)
	assert_eq(int(s["grade_1"]), -int(s["grade_2"]),
		"the two sides' grades do not mirror")
