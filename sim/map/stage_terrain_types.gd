class_name TerrainTyper
extends RefCounted

## Stage 4.7 — cover and concealment.
##
## Terrain type is derived from three things the pipeline already computed: moisture (log flow
## accumulation), slope, and where the tile sits in the map's elevation range. Woods want damp,
## gentle, low-to-middling ground; marsh wants wet flats in the bottoms; rock wants the steep and
## the high.
##
## The acceptance check is that woods **cluster**, and thresholding smooth inputs does not cluster —
## it draws a contour and speckles both sides of it. Two things fix that, and both are needed:
##
##   1. A low-frequency patchiness mask on the woods score, so forest is a patch of forest rather
##      than everything above a moisture line.
##   2. Majority smoothing afterwards, which eats the isolated single tiles that survive.
##
## This stage also sets `blocker_h`, which is what makes woods and villages block line of sight, and
## `move_cost`, which is what makes them slow. Everything downstream reads those two rather than the
## type itself.

const TAG := "terrain"

## Indices into terrain.json. The order is the file's order and is load-bearing.
enum Type { OPEN = 0, SCRUB = 1, WOODS = 2, MARSH = 3, ROCK = 4, WATER = 5, FORD = 6, ROAD = 7, FIELD = 8, VILLAGE = 9 }


static func assign(md: MapData, cfg: Config, master_seed: int) -> void:
	var size: int = md.size
	var n: int = md.n

	var rock_slope: float = cfg.f("terrain_typing.rock_slope", 0.62)
	var rock_elev: float = cfg.f("terrain_typing.rock_elev_pct", 0.86)
	var marsh_moist: float = cfg.f("terrain_typing.marsh_moisture", 0.62)
	var marsh_slope: float = cfg.f("terrain_typing.marsh_slope", 0.10)
	var marsh_elev: float = cfg.f("terrain_typing.marsh_elev_pct", 0.28)
	var woods_moist: float = cfg.f("terrain_typing.woods_moisture", 0.30)
	var woods_slope_max: float = cfg.f("terrain_typing.woods_slope_max", 0.55)
	var woods_elev_max: float = cfg.f("terrain_typing.woods_elev_pct_max", 0.78)
	var patch_freq: float = cfg.f("terrain_typing.woods_patch_freq", 0.0033)
	var patch_bias: float = cfg.f("terrain_typing.woods_patch_bias", 0.06)
	var scrub_moist: float = cfg.f("terrain_typing.scrub_moisture", 0.16)
	var smooth_passes: int = cfg.i("terrain_typing.smooth_passes", 3)

	var patch: FastNoiseLite = NoiseField.build_single(master_seed, TAG + ".patch", patch_freq)

	var slope: PackedFloat32Array = _slope_field(md)
	var elev_pct: PackedFloat32Array = _elevation_percentile(md)

	# Re-rank moisture across tiles.
	#
	# Hydrology computes the percentile per heightfield cell, but averaging sixteen cells into a
	# tile pulls every value toward the middle and squashes the distribution — how hard depends on
	# the downsample ratio, so "the wetter 38%" silently meant the wetter 2% at the shipping ratio
	# and something else again at the test one. Ranking again here makes the thresholds mean what
	# they say at whatever resolution the map was built.
	var moist: PackedFloat32Array = _percentile_of(md.moisture)

	var t: PackedByteArray = md.terrain
	for i: int in n:
		# Water first: a river tile is a river regardless of how dry the surrounding hillside is.
		# Streams are not their own type — a stream at ten-metre tile scale is wet ground, not an
		# obstacle, and making every tile a stream touches impassable would wall the map off.
		var wtr: int = int(md.water[i])
		if wtr == MapData.Water.RIVER:
			t[i] = Type.WATER
			continue
		if wtr == MapData.Water.FORD:
			t[i] = Type.FORD
			continue

		var s: float = slope[i]
		var e: float = elev_pct[i]
		var m: float = moist[i]

		if s >= rock_slope or e >= rock_elev:
			t[i] = Type.ROCK
		elif wtr == MapData.Water.STREAM or (m >= marsh_moist and s <= marsh_slope and e <= marsh_elev):
			t[i] = Type.MARSH
		else:
			# The patch mask shifts the moisture threshold up and down across the map, so woods
			# arrive in stands instead of tracing a contour line.
			var bias: float = patch.get_noise_2d(
				float(i % size) * md.tile_m, float(i / size) * md.tile_m
			) * patch_bias
			if m >= woods_moist - bias and s <= woods_slope_max and e <= woods_elev_max:
				t[i] = Type.WOODS
			elif m >= scrub_moist:
				t[i] = Type.SCRUB
			else:
				t[i] = Type.OPEN
	md.terrain = t

	smooth_majority(md, smooth_passes)
	apply_terrain_attributes(md, cfg)


## Types that a majority vote must never move. Water and fords come from hydrology and are ground
## truth; villages and fields are stamped later by 4.8b and would be smeared away. `ROAD` is listed
## for completeness only — since 0011 a road lives in the link mask and is never a terrain type, so
## no tile ever holds it.
static func _is_fixed(type_id: int) -> bool:
	return (
		type_id == Type.WATER or type_id == Type.FORD
		or type_id == Type.ROAD or type_id == Type.VILLAGE or type_id == Type.FIELD
	)


## Replace each tile with the most common type among its eight neighbours, where that type is a
## clear majority. Removes the salt-and-pepper left by thresholding without eroding real edges.
static func smooth_majority(md: MapData, passes: int) -> void:
	var size: int = md.size
	var counts := PackedInt32Array()
	counts.resize(10)

	for _p: int in passes:
		var src: PackedByteArray = md.terrain.duplicate()
		var dst: PackedByteArray = md.terrain

		for i: int in md.n:
			if _is_fixed(int(src[i])):
				continue
			counts.fill(0)
			var x: int = i % size
			var y: int = i / size
			var total: int = 0
			for d: int in 8:
				var nx: int = x + Grid.DX[d]
				var ny: int = y + Grid.DY[d]
				if nx < 0 or nx >= size or ny < 0 or ny >= size:
					continue
				var nt: int = int(src[ny * size + nx])
				if _is_fixed(nt):
					continue
				counts[nt] += 1
				total += 1

			if total == 0:
				continue
			var best: int = -1
			var best_count: int = 0
			for k: int in 10:
				if counts[k] > best_count:
					best_count = counts[k]
					best = k
			# Strictly more than half the neighbours, so genuine boundaries survive and only
			# isolated specks get absorbed.
			if best >= 0 and best_count * 2 > total:
				dst[i] = best

		md.terrain = dst


## Copy the per-type numbers out of terrain.json into the flat arrays the hot paths read. Nothing
## downstream looks up a terrain type in a dictionary.
##
## The `road` row is a **modifier**, not a tile type. Where a road runs, it sets the going and
## clears the cover while the tile keeps whatever terrain is underneath — which is how a bridge over
## a river is drivable while the tile is still water, and how a road through woods is still a road
## on a woods tile. See docs/decisions/0011.
static func apply_terrain_attributes(md: MapData, cfg: Config) -> void:
	var road_cost: float = cfg.terrain_move_cost[Type.ROAD]
	for i: int in md.n:
		var t: int = int(md.terrain[i])
		var cost: float = cfg.terrain_move_cost[t]
		var blocker: float = cfg.terrain_blocker_h[t]
		if md.road_links[i] != 0:
			cost = road_cost
			blocker = 0.0
		md.move_cost[i] = -10 if cost < 0.0 else int(round(cost * 10.0))
		md.blocker_h[i] = blocker


## Rank every value against the others, 0 for the lowest and 1 for the highest. Two linear passes
## over a histogram rather than a sort.
static func _percentile_of(values: PackedFloat32Array) -> PackedFloat32Array:
	const BINS := 1024
	var n: int = values.size()
	var out := PackedFloat32Array()
	out.resize(n)
	if n == 0:
		return out

	var lo: float = values[0]
	var hi: float = values[0]
	for i: int in n:
		var v: float = values[i]
		if v < lo:
			lo = v
		elif v > hi:
			hi = v
	if hi - lo < 1e-9:
		return out

	var scale: float = float(BINS - 1) / (hi - lo)
	var hist := PackedInt32Array()
	hist.resize(BINS)
	for i2: int in n:
		hist[int((values[i2] - lo) * scale)] += 1

	var cumulative := PackedFloat32Array()
	cumulative.resize(BINS)
	var running: int = 0
	var inv_n: float = 1.0 / float(n)
	for b: int in BINS:
		running += hist[b]
		cumulative[b] = float(running) * inv_n

	for i3: int in n:
		out[i3] = cumulative[int((values[i3] - lo) * scale)]
	return out


## Steepest neighbouring step, as a slope. Uses the quantized levels rather than the original
## heightfield so it agrees with what the transition classes say and with what the mesh will draw.
static func _slope_field(md: MapData) -> PackedFloat32Array:
	var size: int = md.size
	var out := PackedFloat32Array()
	out.resize(md.n)
	var inv_ortho: float = md.quant / md.tile_m
	var inv_diag: float = md.quant / (md.tile_m * sqrt(2.0))

	for i: int in md.n:
		var x: int = i % size
		var y: int = i / size
		var lv: int = md.level[i]
		var worst: float = 0.0
		for d: int in 8:
			var nx: int = x + Grid.DX[d]
			var ny: int = y + Grid.DY[d]
			if nx < 0 or nx >= size or ny < 0 or ny >= size:
				continue
			var dl: float = float(absi(md.level[ny * size + nx] - lv))
			var sl: float = dl * (inv_diag if Grid.IS_DIAG[d] == 1 else inv_ortho)
			if sl > worst:
				worst = sl
		out[i] = worst

	return out


## Where each tile sits in the map's own elevation range, 0 at the lowest tile and 1 at the highest.
##
## A percentile rather than a normalized height: "the top 14% of the ground" holds its meaning from
## seed to seed, whereas "above 180 m" means alpine on one map and a low ridge on another.
static func _elevation_percentile(md: MapData) -> PackedFloat32Array:
	var n: int = md.n
	var lo: int = md.level[0]
	var hi: int = md.level[0]
	for i: int in n:
		var v: int = md.level[i]
		if v < lo:
			lo = v
		elif v > hi:
			hi = v

	var span: int = hi - lo
	var out := PackedFloat32Array()
	out.resize(n)
	if span <= 0:
		return out

	# Histogram over levels, then a running total, so this is two linear passes rather than a sort.
	var hist := PackedInt32Array()
	hist.resize(span + 1)
	for i2: int in n:
		hist[md.level[i2] - lo] += 1

	var cumulative := PackedFloat32Array()
	cumulative.resize(span + 1)
	var running: int = 0
	var inv_n: float = 1.0 / float(n)
	for k: int in span + 1:
		running += hist[k]
		cumulative[k] = float(running) * inv_n

	for i3: int in n:
		out[i3] = cumulative[md.level[i3] - lo]
	return out
