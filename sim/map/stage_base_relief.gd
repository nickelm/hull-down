class_name BaseRelief
extends RefCounted

## Stage 4.2 — the tectonic layer plus a domain-warped ridged multifractal.
##
## Directionality is not a property of noise. Noise is isotropic by construction, and asking a
## fractal for "ridges running north-east" produces lumps that happen to have ridged cross-sections.
## Two mechanisms impose structure instead:
##
## 1. A per-map **strike angle**. Sample coordinates are rotated into a frame aligned with it and
##    then compressed along the strike axis. Compressing a coordinate slows variation along it, so
##    features stretch out in that direction — the noise does not know it is making ridges, but the
##    sampling does.
## 2. A **tectonic layer** of elongated uplift bands running along the same strike, contributing
##    most of the map's total relief. This is what makes the map have an upland side and a lowland
##    side rather than being uniformly rough.
##
## Domain warp is applied after the rotation, so it bends the ridge system rather than smearing an
## unaligned one.

const TAG := "relief"


static func generate(
	cfg: Config, master_seed: int, w: int, h: int, cell_m: float,
	progress: Callable = Callable()
) -> HeightField:
	var field := HeightField.create(w, h, cell_m)

	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.TERRAIN, TAG)

	var octaves: int = cfg.i("relief.octaves", 7)
	var base_freq: float = cfg.f("relief.base_freq", 0.0016)
	var lacunarity: float = cfg.f("relief.lacunarity", 2.03)
	var gain: float = cfg.f("relief.gain", 1.9)
	var offset: float = cfg.f("relief.offset", 1.0)
	var h_exp: float = cfg.f("relief.h_exp", 0.55)
	var warp_freq: float = cfg.f("relief.warp_freq", 0.0009)
	var warp_amp: float = cfg.f("relief.warp_amp_m", 140.0)
	var aniso: float = cfg.f("relief.strike_anisotropy", 0.34)
	var band_count: int = cfg.i("relief.tectonic_bands", 3)
	var tectonic_weight: float = cfg.f("relief.tectonic_weight", 0.42)
	var band_width: float = cfg.f("relief.tectonic_band_width_m", 260.0)

	var oct: Array[FastNoiseLite] = NoiseField.build_octaves(
		master_seed, TAG, octaves, base_freq, lacunarity
	)
	var warp: Array[FastNoiseLite] = NoiseField.build_warp(master_seed, TAG, warp_freq)
	# Modulates band amplitude along strike so the uplift is not a perfectly even wall.
	var band_mod: FastNoiseLite = NoiseField.build_single(
		master_seed, TAG + ".bandmod", base_freq * 0.6
	)

	# Strike is a line, not a vector, so half a turn covers every distinct orientation.
	var strike: float = rng.randf_range(0.0, PI)
	var cs: float = cos(strike)
	var sn: float = sin(strike)

	var span_x: float = float(w) * cell_m
	var span_y: float = float(h) * cell_m
	var half_x: float = span_x * 0.5
	var half_y: float = span_y * 0.5

	# Half-extent of the rotated map along the across-strike axis, so bands are spread over ground
	# that actually exists rather than bunching in the middle.
	var v_extent: float = (span_x * absf(sn) + span_y * absf(cs)) * 0.5

	var band_v := PackedFloat32Array()
	var band_amp := PackedFloat32Array()
	band_v.resize(band_count)
	band_amp.resize(band_count)
	for b: int in band_count:
		var t: float = (float(b) + 0.5) / float(band_count)
		var jitter: float = rng.randf_range(-0.5, 0.5) * (2.0 * v_extent / float(band_count)) * 0.45
		band_v[b] = v_extent * (-1.0 + 2.0 * t) + jitter
		band_amp[b] = rng.randf_range(0.55, 1.0)

	var inv_band_w: float = 1.0 / maxf(band_width, 1.0)

	# The two components live on different scales — the multifractal is unbounded above, the band
	# sum is roughly 0..1 — so they are accumulated separately and normalized before blending.
	var ridged := PackedFloat32Array()
	var tectonic := PackedFloat32Array()
	ridged.resize(w * h)
	tectonic.resize(w * h)

	var r_lo: float = INF
	var r_hi: float = -INF
	var t_lo: float = INF
	var t_hi: float = -INF
	var report_every: int = maxi(h / 10, 1)

	for y: int in h:
		var row: int = y * w
		var cy: float = float(y) * cell_m - half_y
		for x: int in w:
			var cx: float = float(x) * cell_m - half_x

			# Into the strike-aligned frame: u along strike, v across it.
			var u: float = cx * cs + cy * sn
			var v: float = -cx * sn + cy * cs

			var off: Vector2 = NoiseField.warp_offset(warp, u, v, warp_amp)
			var wu: float = u + off.x
			var wv: float = v + off.y

			var rv: float = NoiseField.ridged_multifractal(
				oct, wu * aniso, wv, gain, offset, h_exp
			)

			var tv: float = 0.0
			for b: int in band_count:
				var d: float = (wv - band_v[b]) * inv_band_w
				var modulation: float = 0.7 + 0.3 * band_mod.get_noise_2d(wu, band_v[b])
				tv += band_amp[b] * modulation * exp(-d * d)

			var i: int = row + x
			ridged[i] = rv
			tectonic[i] = tv
			if rv < r_lo:
				r_lo = rv
			if rv > r_hi:
				r_hi = rv
			if tv < t_lo:
				t_lo = tv
			if tv > t_hi:
				t_hi = tv

		if progress.is_valid() and (y % report_every) == 0:
			progress.call("relief", float(y) / float(h))

	var r_span: float = maxf(r_hi - r_lo, 1e-6)
	var t_span: float = maxf(t_hi - t_lo, 1e-6)
	var rw: float = 1.0 - tectonic_weight

	var out: PackedFloat32Array = field.data
	for i: int in out.size():
		out[i] = (
			rw * ((ridged[i] - r_lo) / r_span)
			+ tectonic_weight * ((tectonic[i] - t_lo) / t_span)
		)
	field.data = out

	# Relief is authored for the shipping map and scaled with the world, so what stays constant
	# across sizes is the **gradient** rather than the height range.
	#
	# `Params.small` shrinks the world to a quarter and keeps the cell and tile sizes, for the
	# reason its own docstring gives: tests must not run against terrain the game never produces.
	# Applying the full height range to a quarter-size world breaks that rule along the other axis
	# — the same 60 m spread over 500 m instead of 2 km is four times the slope, and the small
	# pipeline was measuring 37% impassable edges where the shipping map measures 12%. Roads then
	# failed their gradient limit on terrain no player would ever be given.
	var shipping_span: float = float(cfg.i("world.hf_size", 800)) * cfg.f("world.hf_cell_m", 2.5)
	var this_span: float = float(field.w) * cell_m
	var relief_scale: float = this_span / maxf(shipping_span, 0.001)

	field.normalize_to(
		cfg.f("world.target_relief_m", 220.0) * relief_scale,
		cfg.f("world.sea_floor_m", 0.0)
	)
	_apply_edge_falloff(field, cfg, relief_scale)

	if progress.is_valid():
		progress.call("relief", 1.0)
	return field


## Pull the map's border down.
##
## Not cosmetic. Hydrology treats border cells as outlets, and depression filling only terminates
## sensibly if water can actually leave. A map whose edge is a rim drains nowhere, fills to the brim,
## and produces a lake where a river should be.
## `relief_scale` is the same world-size factor `generate` applies to the total relief. Both the
## reach and the depth of the ramp are sized against the map, so on a quarter-size test world a
## full-size ramp would eat most of the height range and most of the ground.
static func _apply_edge_falloff(field: HeightField, cfg: Config, relief_scale: float = 1.0) -> void:
	var reach: float = cfg.f("relief.edge_falloff_m", 120.0) * relief_scale
	var depth: float = cfg.f("relief.edge_falloff_depth_m", 25.0) * relief_scale
	if reach <= 0.0 or depth <= 0.0:
		return

	var w: int = field.w
	var h: int = field.h
	var cell: float = field.cell_m
	var data: PackedFloat32Array = field.data

	for y: int in h:
		var row: int = y * w
		var dy: float = float(mini(y, h - 1 - y)) * cell
		for x: int in w:
			var dx: float = float(mini(x, w - 1 - x)) * cell
			var d: float = minf(dx, dy)
			if d >= reach:
				continue
			var t: float = 1.0 - d / reach
			data[row + x] -= depth * t * t

	field.data = data
