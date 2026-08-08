extends TestCase

## Stage 4.4. The acceptance check is that the maximum gradient falls below the configured angle
## of repose, which is asserted directly here rather than inspected in a dump.

const N := 96
const CELL := 20.833333  # keeps the test field 2 km across

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _limit() -> float:
	return tan(deg_to_rad(cfg.f("erosion.thermal.repose_deg", 40.0)))


## The sweep stops shedding from a cell once its total excess drops below converge_slack_m, so a
## settled field may sit that many metres above the cap on a single edge. Expressed as a slope that
## is slack / cell_m. Deriving the tolerance rather than picking a number keeps the test honest if
## either the slack or the cell size changes.
func _tolerance(cell: float) -> float:
	return cfg.f("erosion.thermal.converge_slack_m", 0.001) / cell + 1e-6


## Deliberately steeper than the shipping terrain.
##
## The map ships gentle — 50 m of relief over 2 km, well inside the angle of repose — so real
## terrain at this test's cell size gives thermal erosion nothing to do, and a test that runs
## against it asserts only that a no-op is a no-op. Exaggerating the vertical scale puts the field
## firmly over the limit so the stage is actually exercised.
func _eroded_relief(master_seed: int, steepen: float = 6.0) -> HeightField:
	var f: HeightField = BaseRelief.generate(cfg, master_seed, N, N, CELL)
	HydraulicErosion.run(f, cfg, master_seed, 3000)
	var d: PackedFloat32Array = f.data
	for i: int in d.size():
		d[i] *= steepen
	f.data = d
	return f


## The acceptance check for 4.4.
func test_no_slope_exceeds_the_angle_of_repose() -> void:
	var limit: float = _limit()
	for master_seed: int in [12345, 4242]:
		var f: HeightField = _eroded_relief(master_seed)
		var before: float = f.max_slope()
		var stats: Dictionary = ThermalErosion.run(f, cfg)

		assert_true(bool(stats["converged"]),
			"seed %d hit the %d-pass cap without settling (slope %.4f, limit %.4f)"
				% [master_seed, int(stats["passes"]), float(stats["slope_after"]), limit])
		assert_le(f.max_slope(), limit + _tolerance(CELL),
			"seed %d left a slope of %.4f above the repose limit of %.4f"
				% [master_seed, f.max_slope(), limit])
		assert_lt(f.max_slope(), before,
			"seed %d was not steep enough to exercise the stage at all" % master_seed)


## Thermal erosion only moves material between neighbours; nothing leaves the map and nothing is
## clamped away. Unlike the hydraulic stage, where droplets can walk off the edge, this one has no
## excuse for any drift at all.
func test_mass_is_conserved_exactly() -> void:
	var f: HeightField = _eroded_relief(777)
	var before: float = f.total_mass()
	var stats: Dictionary = ThermalErosion.run(f, cfg)
	var after: float = f.total_mass()

	assert_lt(float(stats["drift_pct"]), 0.01,
		"mass drifted %.6f%% — material is being created or destroyed" % float(stats["drift_pct"]))
	assert_almost_eq(after, before, absf(before) * 0.0001, "total mass before and after")


## Deltas accumulate into a side buffer and are applied between passes precisely so the outcome
## does not depend on the order cells are visited. Running the stage twice on identical input must
## therefore give bit-identical output.
func test_is_deterministic() -> void:
	var a: HeightField = _eroded_relief(31337)
	var b: HeightField = a.duplicate_field()
	ThermalErosion.run(a, cfg)
	ThermalErosion.run(b, cfg)

	var diffs: int = 0
	for i: int in a.data.size():
		if a.data[i] != b.data[i]:
			diffs += 1
	assert_eq(diffs, 0, "two identical runs differed in %d cells" % diffs)


## Idempotence. A settled field must have nothing left to shed, so a second run should exit on the
## first pass without moving anything.
func test_running_twice_changes_nothing() -> void:
	var f: HeightField = _eroded_relief(555)
	ThermalErosion.run(f, cfg)
	var settled: PackedFloat32Array = f.data.duplicate()

	var second: Dictionary = ThermalErosion.run(f, cfg)
	assert_true(bool(second["converged"]), "a settled field did not report convergence")

	var diffs: int = 0
	for i: int in f.data.size():
		if f.data[i] != settled[i]:
			diffs += 1
	assert_eq(diffs, 0, "a second run moved material in %d cells" % diffs)


## The behaviour in isolation: a single tall column must collapse into a talus cone standing at
## the angle of repose, not stay a spike and not flatten completely.
func test_a_spike_collapses_into_a_talus_cone() -> void:
	var f := HeightField.create(41, 41, 5.0)
	var centre: int = f.idx(20, 20)
	f.data[centre] = 200.0

	var before_mass: float = f.total_mass()
	var stats: Dictionary = ThermalErosion.run(f, cfg)

	assert_true(bool(stats["converged"]), "the spike did not settle within the pass cap")
	assert_le(f.max_slope(), _limit() + _tolerance(5.0),
		"the collapsed pile still stands at %.4f, above the repose limit" % f.max_slope())
	assert_almost_eq(f.total_mass(), before_mass, before_mass * 0.0001,
		"the collapse did not conserve mass")

	# Still a hill: the centre must remain the high point, and material must have spread outward.
	assert_gt(f.data[centre], 0.0, "the pile flattened to nothing")
	assert_lt(f.data[centre], 200.0, "the spike did not collapse at all")
	assert_gt(f.at(20, 18), 0.0, "no material reached two cells out")

	# A cone, not a cylinder: height must fall off monotonically away from the peak.
	assert_gt(f.at(20, 20), f.at(20, 22), "height does not decrease away from the peak")
	assert_gt(f.at(20, 22), f.at(20, 26), "height does not keep decreasing further out")


func test_a_flat_field_is_left_alone() -> void:
	var f := HeightField.create(32, 32, 5.0)
	var d: PackedFloat32Array = f.data
	d.fill(17.0)
	f.data = d

	var stats: Dictionary = ThermalErosion.run(f, cfg)
	assert_true(bool(stats["converged"]), "a flat field did not converge immediately")
	assert_eq(int(stats["passes"]), 0, "a flat field needed %d passes" % int(stats["passes"]))

	for i: int in f.data.size():
		if f.data[i] != 17.0:
			fail("a flat field was modified at cell %d" % i)
			return


## A slope already at the repose angle is legal and must survive untouched — otherwise the stage
## erodes every hillside on the map down to nothing over successive generations.
func test_a_slope_at_exactly_the_repose_angle_survives() -> void:
	var cell: float = 5.0
	var step: float = _limit() * cell * 0.98  # just inside the limit
	var f := HeightField.create(24, 24, cell)
	var d: PackedFloat32Array = f.data
	for y: int in 24:
		for x: int in 24:
			d[y * 24 + x] = float(y) * step
	f.data = d
	var before: PackedFloat32Array = f.data.duplicate()

	ThermalErosion.run(f, cfg)

	var moved: float = 0.0
	for i: int in f.data.size():
		moved += absf(f.data[i] - before[i])
	assert_lt(moved, 0.01, "a legal slope was eroded by %.4f m in total" % moved)


func test_no_nan_or_infinite_heights() -> void:
	var f: HeightField = _eroded_relief(8888)
	ThermalErosion.run(f, cfg)
	var bad: int = 0
	for i: int in f.data.size():
		var v: float = f.data[i]
		if is_nan(v) or is_inf(v):
			bad += 1
	assert_eq(bad, 0, "%d cells are NaN or infinite after thermal erosion" % bad)
