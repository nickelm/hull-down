extends TestCase

## Stage 4.3. The headline acceptance check is mass conservation; "dendritic valleys are visible"
## is answered by the hillshaded dump. What is asserted here is everything that would let the
## erosion look plausible while being physically wrong.

const N := 128
const CELL := 15.625
const DROPLETS := 8000

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _relief(master_seed: int) -> HeightField:
	return BaseRelief.generate(cfg, master_seed, N, N, CELL)


func _erode(f: HeightField, master_seed: int) -> Dictionary:
	return HydraulicErosion.run(f, cfg, master_seed, DROPLETS)


## The acceptance check. Erosion moves material; it must not invent or delete any.
func test_mass_is_conserved() -> void:
	var limit: float = cfg.f("erosion.hydraulic.mass_drift_max_pct", 3.0)
	for master_seed: int in [7, 12345, 99]:
		var f: HeightField = _relief(master_seed)
		var stats: Dictionary = _erode(f, master_seed)
		var drift: float = float(stats["drift_pct"])
		assert_lt(drift, limit,
			"seed %d drifted %.4f%% of total mass, limit %.1f%%" % [master_seed, drift, limit])


## Mass conservation is trivially satisfied by doing nothing at all, so prove work happened.
func test_erosion_actually_changes_the_terrain() -> void:
	var before: HeightField = _relief(12345)
	var after: HeightField = before.duplicate_field()
	_erode(after, 12345)

	var moved: float = 0.0
	for i: int in before.data.size():
		moved += absf(after.data[i] - before.data[i])
	var mean_move: float = moved / float(before.data.size())
	assert_gt(mean_move, 0.05,
		"mean height change was only %.4f m — erosion is effectively a no-op" % mean_move)


## The physical claim: water carries material downhill. High ground should lose on balance and low
## ground should gain. A model that merely jitters heights would pass mass conservation and fail
## this.
func test_material_moves_from_high_ground_to_low() -> void:
	var before: HeightField = _relief(2468)
	var after: HeightField = before.duplicate_field()
	_erode(after, 2468)

	var mm: Vector2 = before.min_max()
	var mid: float = (mm.x + mm.y) * 0.5

	var high_delta: float = 0.0
	var low_delta: float = 0.0
	for i: int in before.data.size():
		var d: float = after.data[i] - before.data[i]
		if before.data[i] > mid:
			high_delta += d
		else:
			low_delta += d

	assert_lt(high_delta, 0.0, "high ground gained %.1f m of material overall" % high_delta)
	assert_gt(low_delta, 0.0, "low ground lost %.1f m of material overall" % low_delta)


## Erosion must not cut below the step the droplet just took. Without that clamp a droplet digs a
## pit under itself, the next droplet falls in and digs deeper, and the field grows spikes — which
## is exactly what the first tuning of this stage did.
func test_no_runaway_pits() -> void:
	var before: HeightField = _relief(31337)
	var before_max: float = before.max_gradient()
	var after: HeightField = before.duplicate_field()
	_erode(after, 31337)

	assert_lt(after.max_gradient(), before_max * 2.5,
		"steepest step went from %.1f m to %.1f m — droplets are digging pits under themselves"
			% [before_max, after.max_gradient()])


func test_is_deterministic() -> void:
	var a: HeightField = _relief(555)
	var b: HeightField = _relief(555)
	_erode(a, 555)
	_erode(b, 555)
	var diffs: int = 0
	for i: int in a.data.size():
		if a.data[i] != b.data[i]:
			diffs += 1
	assert_eq(diffs, 0, "the same seed eroded differently in %d cells" % diffs)


## The droplet count must actually drive the work. A loop that silently capped itself, or a count
## read from the wrong config path, would still conserve mass and still look eroded.
func test_more_droplets_move_more_material() -> void:
	var base: HeightField = _relief(4242)

	var few: HeightField = base.duplicate_field()
	HydraulicErosion.run(few, cfg, 4242, 500)
	var many: HeightField = base.duplicate_field()
	HydraulicErosion.run(many, cfg, 4242, 8000)

	var moved_few: float = 0.0
	var moved_many: float = 0.0
	for i: int in base.data.size():
		moved_few += absf(few.data[i] - base.data[i])
		moved_many += absf(many.data[i] - base.data[i])

	assert_gt(moved_few, 0.0, "500 droplets moved nothing at all")
	assert_gt(moved_many, moved_few * 2.0,
		"16x the droplets moved only %.1fx the material (%.0f m vs %.0f m)"
			% [moved_many / maxf(moved_few, 1e-6), moved_many, moved_few])


## Erosion draws from its own tagged substream, so running it does not consume values that a later
## stage expects. If someone swaps it onto the shared TERRAIN stream, every stage after this one
## silently reshuffles and every pinned seed changes.
func test_erosion_does_not_consume_the_shared_terrain_stream() -> void:
	var before: HeightField = _relief(4242)
	var f: HeightField = _relief(4242)
	HydraulicErosion.run(f, cfg, 4242, 2000)
	var after: HeightField = _relief(4242)

	var diffs: int = 0
	for i: int in before.data.size():
		if before.data[i] != after.data[i]:
			diffs += 1
	assert_eq(diffs, 0,
		"generating relief after an erosion run produced %d differing cells" % diffs)


func test_no_nan_or_infinite_heights() -> void:
	var f: HeightField = _relief(8888)
	_erode(f, 8888)
	var bad: int = 0
	for i: int in f.data.size():
		var v: float = f.data[i]
		if is_nan(v) or is_inf(v):
			bad += 1
	assert_eq(bad, 0, "%d cells are NaN or infinite after erosion" % bad)


## Droplets are confined to a border strip wide enough that the erosion brush cannot reach off the
## edge. If that ever stops holding, the brush writes wrap around a row and material teleports
## across the map — which conserves mass and corrupts the terrain.
func test_outer_ring_is_untouched() -> void:
	var before: HeightField = _relief(1717)
	var after: HeightField = before.duplicate_field()
	_erode(after, 1717)

	var changed: int = 0
	for x: int in N:
		if after.data[x] != before.data[x]:
			changed += 1
		if after.data[(N - 1) * N + x] != before.data[(N - 1) * N + x]:
			changed += 1
	for y: int in N:
		if after.data[y * N] != before.data[y * N]:
			changed += 1
		if after.data[y * N + N - 1] != before.data[y * N + N - 1]:
			changed += 1

	assert_eq(changed, 0, "%d cells on the outer ring were modified — the brush reached the edge"
		% changed)
