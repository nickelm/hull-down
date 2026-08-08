extends TestCase

## The relief-variety metric — docs/decisions/0013.
##
## `escarpment_fraction` counts the edges a tank cannot cross, so it says nothing about a map that
## has no walls and no folds either. That map is exactly what the generator was producing, and
## nothing measured it. These are the assertions that make "the terrain is boring" a number.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _flat(size: int) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	return md


func test_a_flat_map_has_no_relief_variety() -> void:
	var md: MapData = _flat(8)
	var r: Dictionary = MapMetrics.relief_variety(md)

	assert_almost_eq(float(r["mean_abs_dl"]), 0.0, 0.0001, "a flat map has no steps")
	assert_almost_eq(float(r["flat_edge_frac"]), 1.0, 0.0001, "every edge on a flat map is flat")
	assert_eq(int(r["level_span"]), 0, "a flat map spans no levels")


## A staircase running east, one quantum per tile. Every east-west edge steps by exactly 1 and
## every north-south edge is flat, so the mean over both is exactly the fraction that step.
func test_a_staircase_measures_its_own_step() -> void:
	var size: int = 8
	var md: MapData = _flat(size)
	for i: int in md.n:
		md.level[i] = md.tx(i)

	var r: Dictionary = MapMetrics.relief_variety(md)

	# Canonical slots are E, SE, S, SW. Counting only on-map edges: E and S contribute one edge per
	# interior tile, the diagonals likewise. E and SE step by 1; S is flat; SW steps by 1.
	assert_gt(float(r["mean_abs_dl"]), 0.0, "a staircase must register as varied")
	assert_lt(float(r["flat_edge_frac"]), 1.0, "a staircase has non-flat edges")
	assert_eq(int(r["level_span"]), size - 1, "the level span is the height of the staircase")


func test_a_single_step_counts_only_the_edges_that_cross_it() -> void:
	var md: MapData = _flat(4)
	# Raise the whole eastern half by two quanta.
	for i: int in md.n:
		if md.tx(i) >= 2:
			md.level[i] = 2

	var r: Dictionary = MapMetrics.relief_variety(md)
	assert_gt(float(r["mean_abs_dl"]), 0.0, "the step was not measured")
	assert_lt(float(r["flat_edge_frac"]), 1.0, "the edges crossing the step are not flat")
	assert_eq(int(r["level_span"]), 2, "the span is the height of the step")


## Reported through `evaluate` as well, since that is what the batch tool reads.
func test_evaluate_reports_relief_variety() -> void:
	var md: MapData = _flat(24)
	Quantizer.classify_transitions(md, cfg)
	var m: Dictionary = MapMetrics.evaluate(md, cfg, 1)

	assert_true(m.has("mean_abs_dl"), "evaluate does not report mean_abs_dl")
	assert_true(m.has("flat_edge_frac"), "evaluate does not report flat_edge_frac")
	assert_true(m.has("level_span"), "evaluate does not report level_span")
	assert_almost_eq(float(m["mean_abs_dl"]), 0.0, 0.0001, "a flat map through evaluate")
