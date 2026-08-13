extends TestCase

## Stage 4.2. The acceptance check is visual — "directional ridge structure rather than isotropic
## lumps" — and a hillshaded dump answers it far better than any assertion. These tests exist so
## the property survives later parameter changes without anyone reopening the PNG.

const N := 128
const CELL := 15.625  # keeps the test field the same 2 km across as the real one

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _field(master_seed: int) -> HeightField:
	return BaseRelief.generate(cfg, master_seed, N, N, CELL)


## Gradient structure tensor. For an isotropic field the two eigenvalues are equal and the
## anisotropy is ~0; for a field with a dominant strike one eigenvalue dominates. Working from
## eigenvalues rather than from the x and y axes directly means the test does not care which way
## the strike happens to point on a given seed.
func _anisotropy(f: HeightField) -> float:
	var jxx: float = 0.0
	var jyy: float = 0.0
	var jxy: float = 0.0
	for y: int in range(1, f.h - 1):
		var row: int = y * f.w
		for x: int in range(1, f.w - 1):
			var gx: float = f.data[row + x + 1] - f.data[row + x - 1]
			var gy: float = f.data[row + f.w + x] - f.data[row - f.w + x]
			jxx += gx * gx
			jyy += gy * gy
			jxy += gx * gy

	# Eigenvalues of the symmetric 2x2 [[jxx, jxy], [jxy, jyy]].
	var tr: float = jxx + jyy
	var diff: float = jxx - jyy
	var root: float = sqrt(diff * diff + 4.0 * jxy * jxy)
	if tr < 1e-9:
		return 0.0
	return root / tr  # (l1 - l2) / (l1 + l2)


func test_relief_is_directional_not_isotropic() -> void:
	# Several seeds, because a single one could be directional by luck.
	for master_seed: int in [1, 12345, 777, 90210]:
		var a: float = _anisotropy(_field(master_seed))
		assert_gt(a, 0.12,
			"seed %d produced near-isotropic relief (anisotropy %.3f); the strike rotation or "
			% [master_seed, a] + "relief.strike_anisotropy is not doing its job")


## The control: the same measurement on an unrotated, unweighted noise field should come out low.
## Without this, the threshold above is an unanchored number and a bug that made every field
## "directional" would pass.
func test_plain_noise_scores_lower_than_relief() -> void:
	var flat := HeightField.create(N, N, CELL)
	var n: FastNoiseLite = NoiseField.build_single(4242, "control", 0.004)
	var d: PackedFloat32Array = flat.data
	for y: int in N:
		for x: int in N:
			d[y * N + x] = n.get_noise_2d(float(x) * CELL, float(y) * CELL) * 100.0
	flat.data = d

	var control: float = _anisotropy(flat)
	var relief: float = _anisotropy(_field(12345))
	assert_lt(control, 0.08, "plain isotropic noise should score low, got %.3f" % control)
	assert_gt(relief, control * 2.0,
		"relief (%.3f) is not meaningfully more directional than plain noise (%.3f)"
			% [relief, control])


func test_generation_is_deterministic() -> void:
	var a: HeightField = _field(2024)
	var b: HeightField = _field(2024)
	assert_eq(a.data.size(), b.data.size(), "field sizes differ")
	var diffs: int = 0
	for i: int in a.data.size():
		if a.data[i] != b.data[i]:
			diffs += 1
	assert_eq(diffs, 0, "the same seed produced %d differing cells" % diffs)


func test_different_seeds_give_different_terrain() -> void:
	var a: HeightField = _field(1)
	var b: HeightField = _field(2)
	var same: int = 0
	for i: int in a.data.size():
		if absf(a.data[i] - b.data[i]) < 0.01:
			same += 1
	assert_lt(float(same), float(a.data.size()) * 0.05,
		"two seeds produced near-identical terrain")


func test_relief_span_matches_the_configured_target() -> void:
	var f: HeightField = _field(555)
	var target: float = cfg.f("world.target_relief_m", 220.0)
	var mm: Vector2 = f.min_max()
	# The edge falloff runs after normalization and only ever lowers ground, so the field spans at
	# least the target and at most the target plus the falloff depth.
	var depth: float = cfg.f("relief.edge_falloff_depth_m", 25.0)
	assert_in_range(mm.y - mm.x, target - 0.01, target + depth + 0.01,
		"relief span %.1f m is outside the configured target %.1f m" % [mm.y - mm.x, target])


## Hydrology treats border cells as outlets. If the border is not the low ground, water cannot
## leave the map, depression filling floods the lowlands, and 4.5's rivers become a lake.
func test_border_is_lower_than_the_interior() -> void:
	var f: HeightField = _field(31337)

	var border_sum: float = 0.0
	var border_n: int = 0
	for x: int in f.w:
		border_sum += f.data[x] + f.data[(f.h - 1) * f.w + x]
		border_n += 2
	for y: int in range(1, f.h - 1):
		border_sum += f.data[y * f.w] + f.data[y * f.w + f.w - 1]
		border_n += 2

	var interior_sum: float = 0.0
	var interior_n: int = 0
	var lo: int = f.h / 4
	var hi: int = f.h - lo
	for y: int in range(lo, hi):
		for x: int in range(lo, hi):
			interior_sum += f.data[y * f.w + x]
			interior_n += 1

	var border_mean: float = border_sum / float(border_n)
	var interior_mean: float = interior_sum / float(interior_n)
	assert_lt(border_mean, interior_mean,
		"the map border (mean %.1f m) must sit below the interior (mean %.1f m) so water can drain"
			% [border_mean, interior_mean])


func test_no_nan_or_infinite_heights() -> void:
	var f: HeightField = _field(8888)
	var bad: int = 0
	for i: int in f.data.size():
		var v: float = f.data[i]
		if is_nan(v) or is_inf(v):
			bad += 1
	assert_eq(bad, 0, "%d cells are NaN or infinite" % bad)


func test_height_field_helpers() -> void:
	var f := HeightField.create(4, 3, 2.0)
	assert_eq(f.count(), 12, "cell count")
	assert_eq(f.idx(2, 1), 6, "flat index is row-major")

	f.set_at(2, 1, 5.0)
	assert_eq(f.at(2, 1), 5.0, "set_at/at round trip")
	assert_almost_eq(f.total_mass(), 5.0, 0.0001, "total mass")

	assert_true(f.in_bounds(3, 2), "top-right corner is in bounds")
	assert_false(f.in_bounds(4, 2), "x == w is out of bounds")
	assert_false(f.in_bounds(-1, 0), "negative x is out of bounds")

	# Bilinear sample must interpolate, not snap. Between (2,1)=5 and its zero neighbors the
	# midpoint is a quarter of the way up.
	assert_almost_eq(f.sample(2.0, 1.0), 5.0, 0.0001, "sample on the cell center")
	assert_almost_eq(f.sample(2.5, 1.0), 2.5, 0.0001, "sample halfway to the next cell")

	assert_eq(f.max_gradient(), 5.0, "max gradient is the biggest neighbor difference")


func test_normalize_to_is_exact() -> void:
	var f := HeightField.create(8, 8, 1.0)
	var d: PackedFloat32Array = f.data
	for i: int in d.size():
		d[i] = float(i) * 0.37
	f.data = d

	f.normalize_to(100.0, 12.0)
	var mm: Vector2 = f.min_max()
	assert_almost_eq(mm.x, 12.0, 0.001, "floor after normalize")
	assert_almost_eq(mm.y, 112.0, 0.001, "ceiling after normalize")


## A field with no relief at all must not divide by zero.
func test_normalize_tolerates_a_flat_field() -> void:
	var f := HeightField.create(4, 4, 1.0)
	f.normalize_to(100.0, 0.0)
	var mm: Vector2 = f.min_max()
	assert_eq(mm.x, mm.y, "a flat field must stay flat")
	assert_false(is_nan(mm.x), "normalizing a flat field produced NaN")
