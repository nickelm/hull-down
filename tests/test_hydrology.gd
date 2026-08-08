extends TestCase

## Stage 4.5. The acceptance check is "rivers run downhill without breaks and at least two fords
## exist per map". Both are asserted directly. The rest of these guard the invariants the later
## stages quietly assume — most importantly that the drainage graph is a forest with no cycles,
## because a cycle turns flow accumulation into an infinite loop and a river into a ring.

const N := 96
const CELL := 20.833333

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _terrain(master_seed: int) -> HeightField:
	var f: HeightField = BaseRelief.generate(cfg, master_seed, N, N, CELL)
	HydraulicErosion.run(f, cfg, master_seed, 3000)
	ThermalErosion.run(f, cfg)
	return f


func _run(master_seed: int) -> Array:
	var f: HeightField = _terrain(master_seed)
	var r: Hydrology.Result = Hydrology.run(f, cfg, master_seed)
	return [f, r]


# --- depression filling -------------------------------------------------------------------------

## The property the whole stage rests on: after filling, every interior cell has somewhere lower to
## send its water. If this fails, D8 produces a pit, accumulation finds a cycle, and the river has
## a hole in it.
func test_every_interior_cell_drains_after_filling() -> void:
	var f: HeightField = _terrain(12345)
	Hydrology.fill_depressions(f, cfg)

	var stuck: int = 0
	for y: int in range(1, N - 1):
		for x: int in range(1, N - 1):
			var i: int = y * N + x
			var hv: float = f.data[i]
			var has_lower: bool = false
			for d: int in 8:
				var nx: int = x + Grid.DX[d]
				var ny: int = y + Grid.DY[d]
				if f.data[ny * N + nx] < hv:
					has_lower = true
					break
			if not has_lower:
				stuck += 1
	assert_eq(stuck, 0, "%d interior cells have no downhill neighbour after depression filling" % stuck)


## Filling raises ground and never lowers it. A fill that cut into terrain would be quietly
## rewriting the relief the previous stages produced.
func test_filling_only_raises_ground() -> void:
	var f: HeightField = _terrain(777)
	var before: PackedFloat32Array = f.data.duplicate()
	Hydrology.fill_depressions(f, cfg)

	var lowered: int = 0
	for i: int in f.data.size():
		if f.data[i] < before[i] - 1e-6:
			lowered += 1
	assert_eq(lowered, 0, "depression filling lowered %d cells" % lowered)


## A second fill must not keep excavating the map upward.
##
## It is not an exact fixed point, and asserting one would be wrong. The epsilon that removes flats
## also changes heights, which changes the order cells are visited on the next run, so a cell can
## be reached from a marginally higher neighbour the second time and gain another epsilon. What
## matters is that the correction is on the order of the epsilon itself rather than the terrain —
## if a second pass moved metres, the first one did not actually resolve the depressions.
func test_a_second_fill_moves_nothing_material() -> void:
	var f: HeightField = _terrain(4242)
	Hydrology.fill_depressions(f, cfg)
	var settled: PackedFloat32Array = f.data.duplicate()

	Hydrology.fill_depressions(f, cfg)

	var eps: float = cfg.f("hydrology.fill_epsilon_m", 0.001)
	var worst: float = 0.0
	var total: float = 0.0
	for i: int in f.data.size():
		var d: float = absf(f.data[i] - settled[i])
		total += d
		worst = maxf(worst, d)

	assert_lt(worst, eps * 20.0,
		"a second fill raised one cell by %.5f m, far beyond the %.5f m epsilon" % [worst, eps])
	assert_lt(total / float(f.data.size()), eps,
		"a second fill moved %.5f m per cell on average" % (total / float(f.data.size())))


# --- flow graph ----------------------------------------------------------------------------------

## Kahn's algorithm only produces a complete ordering if the graph is acyclic, so a topological
## order covering every cell *is* the proof that no cycle exists.
func test_flow_graph_is_acyclic_and_complete() -> void:
	var out: Array = _run(31337)
	var r: Hydrology.Result = out[1]
	assert_eq(r.topo_order.size(), N * N,
		"topological order covers %d of %d cells — the flow graph has a cycle"
			% [r.topo_order.size(), N * N])

	# Every cell must appear exactly once.
	var seen := PackedByteArray()
	seen.resize(N * N)
	var dupes: int = 0
	for k: int in r.topo_order.size():
		var c: int = r.topo_order[k]
		if seen[c] != 0:
			dupes += 1
		seen[c] = 1
	assert_eq(dupes, 0, "%d cells appear more than once in the topological order" % dupes)


## Water must flow downhill. Every cell's receiver must be strictly below it.
##
## Checked against the surface the receivers were *derived from*, which is the filled field before
## anything is carved. Checking the finished map instead would be asserting something the pipeline
## never promised: carving lowers channel beds after the receivers were chosen, so ground beside a
## cut channel legitimately ends up level with the cell it drains into. The invariant that does
## have to survive carving is that channel beds descend, and that has its own test.
func test_receivers_point_downhill_on_the_surface_they_were_built_from() -> void:
	var f: HeightField = _terrain(555)
	Hydrology.fill_depressions(f, cfg)
	var receiver: PackedInt32Array = Hydrology.flow_directions(f)

	var uphill: int = 0
	var no_receiver: int = 0
	for i: int in receiver.size():
		var rc: int = receiver[i]
		if rc < 0:
			var x: int = i % N
			var y: int = i / N
			if x > 0 and x < N - 1 and y > 0 and y < N - 1:
				no_receiver += 1
			continue
		if f.data[rc] >= f.data[i]:
			uphill += 1

	assert_eq(uphill, 0, "%d receivers point uphill or level" % uphill)
	assert_eq(no_receiver, 0,
		"%d interior cells have no receiver, so their water goes nowhere" % no_receiver)


## Rain falls one unit per cell and nothing evaporates, so the accumulation arriving at the map
## edge must add up to the whole map.
func test_accumulation_conserves_rainfall() -> void:
	var out: Array = _run(2024)
	var r: Hydrology.Result = out[1]

	var outlet_total: float = 0.0
	for i: int in r.receiver.size():
		if r.receiver[i] < 0:
			outlet_total += r.accum[i]

	var n: float = float(N * N)
	assert_almost_eq(outlet_total, n, n * 0.001,
		"outlets carry %.0f units of the %.0f that fell" % [outlet_total, n])


func test_accumulation_increases_downstream() -> void:
	var out: Array = _run(90210)
	var r: Hydrology.Result = out[1]

	var wrong: int = 0
	for i: int in r.receiver.size():
		var rc: int = r.receiver[i]
		if rc < 0:
			continue
		if r.accum[rc] < r.accum[i]:
			wrong += 1
	assert_eq(wrong, 0, "%d cells carry more water than the cell they drain into" % wrong)


# --- channels and carving -------------------------------------------------------------------------

## The acceptance check: rivers run downhill without breaks.
func test_channel_beds_run_downhill_without_breaks() -> void:
	for master_seed: int in [12345, 4242]:
		var out: Array = _run(master_seed)
		var f: HeightField = out[0]
		var r: Hydrology.Result = out[1]

		var breaks: int = 0
		var worst: float = 0.0
		for i: int in r.channel.size():
			if r.channel[i] == Hydrology.Channel.NONE:
				continue
			var rc: int = r.receiver[i]
			if rc < 0:
				continue
			var rise: float = f.data[rc] - f.data[i]
			if rise > 0.0:
				breaks += 1
				worst = maxf(worst, rise)
		assert_eq(breaks, 0,
			"seed %d has %d channel cells whose bed rises downstream (worst %.3f m)"
				% [master_seed, breaks, worst])


func test_channels_form_and_rivers_are_rarer_than_streams() -> void:
	var out: Array = _run(12345)
	var r: Hydrology.Result = out[1]

	assert_gt(float(r.stream_cells), 0.0, "no streams were classified at all")
	assert_gt(float(r.river_cells), 0.0, "no rivers were classified at all")
	assert_lt(float(r.river_cells), float(r.stream_cells),
		"there are more river cells than stream cells; the thresholds are the wrong way round")

	var frac: float = float(r.stream_cells + r.river_cells) / float(N * N)
	assert_in_range(frac, 0.005, 0.25,
		"channels cover %.1f%% of the map, which is not a drainage network" % (frac * 100.0))


## Carving cuts a depth out of the existing surface rather than pulling everything down to an
## absolute bed elevation. Getting that backwards slices the valley walls off level with the
## channel and leaves a cliff at the edge of the carve radius — which showed up as the maximum
## step on the map jumping from 4 m to 23 m.
func test_carving_does_not_cut_cliffs_into_the_valley_walls() -> void:
	var f: HeightField = _terrain(12345)
	ThermalErosion.run(f, cfg)
	var before_step: float = f.max_gradient()
	var max_depth: float = cfg.f("hydrology.max_carve_depth_m", 5.0)

	Hydrology.run(f, cfg, 12345)

	# A channel may legitimately incise up to its full depth against an uncut neighbour; anything
	# beyond that is the carve damaging terrain it should not have touched.
	assert_le(f.max_gradient(), before_step + max_depth + 0.5,
		"steepest step went from %.2f m to %.2f m, more than the %.1f m carve depth explains"
			% [before_step, f.max_gradient(), max_depth])


func test_channels_are_wide_enough_to_survive_downsampling() -> void:
	# A one-cell channel averages away to nothing when the heightfield collapses into the gameplay
	# grid, leaving a river that exists in the data and not on the map.
	var out: Array = _run(12345)
	var r: Hydrology.Result = out[1]
	var ratio: int = int(round(cfg.f("world.tile_m", 10.0) / CELL))

	var half_width: float = cfg.f("hydrology.river_half_width_cells", 4.5)
	assert_ge(half_width * 2.0, float(maxi(ratio, 1)),
		"rivers are %.1f cells wide but %d cells collapse into one tile"
			% [half_width * 2.0, ratio])
	assert_gt(float(r.river_cells), 0.0, "no rivers to check")


# --- fords -----------------------------------------------------------------------------------------

## The acceptance check: at least two fords per map.
func test_at_least_the_required_number_of_fords() -> void:
	var required: int = cfg.i("hydrology.min_fords", 2)
	for master_seed: int in [12345, 4242, 777]:
		var out: Array = _run(master_seed)
		var r: Hydrology.Result = out[1]
		assert_ge(float(r.ford_count), float(required),
			"seed %d produced %d fords, needs %d" % [master_seed, r.ford_count, required])


## A ford that is still five metres deep is a marker, not a crossing.
func test_fords_are_actually_shallow() -> void:
	var out: Array = _run(12345)
	var r: Hydrology.Result = out[1]
	var max_depth: float = cfg.f("hydrology.ford_max_depth_m", 0.9)

	var checked: int = 0
	for i: int in r.ford.size():
		if r.ford[i] == 0:
			continue
		checked += 1
		assert_le(r.depth[i], max_depth + 0.01,
			"ford at cell %d is %.2f m deep, limit %.2f m" % [i, r.depth[i], max_depth])
	assert_gt(float(checked), 0.0, "no fords were marked")


func test_fords_are_on_rivers_and_spread_out() -> void:
	var out: Array = _run(12345)
	var r: Hydrology.Result = out[1]

	var positions := PackedInt32Array()
	for i: int in r.ford.size():
		if r.ford[i] == 0:
			continue
		assert_eq(int(r.channel[i]), Hydrology.Channel.RIVER,
			"the ford at cell %d is not on a river" % i)
		positions.append(i)

	var sep_tiles: float = cfg.f("hydrology.ford_separation_tiles", 22.0)
	var sep_cells: float = sep_tiles * (cfg.f("world.tile_m", 10.0) / CELL)
	for a: int in positions.size():
		for b: int in range(a + 1, positions.size()):
			var dx: float = float(positions[a] % N - positions[b] % N)
			var dy: float = float(positions[a] / N - positions[b] / N)
			var dist: float = sqrt(dx * dx + dy * dy)
			assert_ge(dist, sep_cells - 0.01,
				"two fords are only %.1f cells apart, minimum %.1f" % [dist, sep_cells])


# --- general ------------------------------------------------------------------------------------

func test_is_deterministic() -> void:
	var a: Array = _run(8888)
	var b: Array = _run(8888)
	var fa: HeightField = a[0]
	var fb: HeightField = b[0]
	var ra: Hydrology.Result = a[1]
	var rb: Hydrology.Result = b[1]

	var diffs: int = 0
	for i: int in fa.data.size():
		if fa.data[i] != fb.data[i]:
			diffs += 1
	assert_eq(diffs, 0, "the same seed produced %d differing heights" % diffs)
	assert_eq(ra.ford_count, rb.ford_count, "ford count differs between identical runs")

	var chan_diffs: int = 0
	for i: int in ra.channel.size():
		if ra.channel[i] != rb.channel[i]:
			chan_diffs += 1
	assert_eq(chan_diffs, 0, "%d channel classifications differ between identical runs" % chan_diffs)


func test_moisture_is_normalized() -> void:
	var out: Array = _run(555)
	var r: Hydrology.Result = out[1]
	var lo: float = 2.0
	var hi: float = -1.0
	for i: int in r.moisture.size():
		var m: float = r.moisture[i]
		assert_false(is_nan(m), "moisture at cell %d is NaN" % i)
		lo = minf(lo, m)
		hi = maxf(hi, m)
	assert_in_range(lo, 0.0, 1.0, "minimum moisture out of range")
	assert_in_range(hi, 0.0, 1.0, "maximum moisture out of range")
	assert_gt(hi - lo, 0.3, "moisture spans only %.2f — it carries almost no signal" % (hi - lo))


func test_water_surface_sits_above_the_bed_on_channels_only() -> void:
	var out: Array = _run(12345)
	var f: HeightField = out[0]
	var r: Hydrology.Result = out[1]

	for i: int in r.channel.size():
		if r.channel[i] == Hydrology.Channel.NONE:
			assert_eq(r.surface[i], 0.0, "cell %d is dry but has a water surface" % i)
		else:
			assert_ge(r.surface[i], f.data[i] - 0.001,
				"the water surface at cell %d is below its bed" % i)


func test_no_nan_or_infinite_heights() -> void:
	var out: Array = _run(90210)
	var f: HeightField = out[0]
	var bad: int = 0
	for i: int in f.data.size():
		if is_nan(f.data[i]) or is_inf(f.data[i]):
			bad += 1
	assert_eq(bad, 0, "%d cells are NaN or infinite after hydrology" % bad)
