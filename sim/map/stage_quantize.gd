class_name Quantizer
extends RefCounted

## Stage 4.6, first half — collapse the continuous heightfield into the gameplay grid.
##
## The heightfield is 800 square at 2.5 m; the grid is 200 square at 10 m. Sixteen cells become one
## tile by **exact area averaging**, not by point or bilinear sampling. Area averaging is what
## preserves mean elevation, and the zone-balance metric in 4.11 compares mean elevation between
## deployment zones — sampling instead of averaging would make that metric measure the sampling
## pattern.
##
## Then heights quantize to 0.5 m integer levels, and every edge is classified once.


static func downsample(field: HeightField, out_size: int) -> PackedFloat32Array:
	var ratio: int = field.w / out_size
	var out := PackedFloat32Array()
	out.resize(out_size * out_size)
	var inv_area: float = 1.0 / float(ratio * ratio)

	for ty: int in out_size:
		var y0: int = ty * ratio
		for tx: int in out_size:
			var x0: int = tx * ratio
			var sum: float = 0.0
			for oy: int in ratio:
				var row: int = (y0 + oy) * field.w + x0
				for ox: int in ratio:
					sum += field.data[row + ox]
			out[ty * out_size + tx] = sum * inv_area

	return out


## Average an arbitrary per-cell layer down to the grid. Used for moisture.
static func downsample_layer(
	src: PackedFloat32Array, src_size: int, out_size: int
) -> PackedFloat32Array:
	var ratio: int = src_size / out_size
	var out := PackedFloat32Array()
	out.resize(out_size * out_size)
	var inv_area: float = 1.0 / float(ratio * ratio)

	for ty: int in out_size:
		var y0: int = ty * ratio
		for tx: int in out_size:
			var x0: int = tx * ratio
			var sum: float = 0.0
			for oy: int in ratio:
				var row: int = (y0 + oy) * src_size + x0
				for ox: int in ratio:
					sum += src[row + ox]
			out[ty * out_size + tx] = sum * inv_area

	return out


## Reduce the per-cell water layer to the grid.
##
## Rivers and fords collapse by presence: a river four cells wide inside a sixteen-cell block is a
## minority everywhere, so a majority vote would erase the map's water entirely, and the whole point
## of a river is that it is an obstacle even when it is narrower than a tile.
##
## Streams need the opposite treatment. The drainage network is dendritic and reaches almost
## everywhere, so "any cell in this block has a stream" marks a third of the map as wet — which put
## a water quad over most of the terrain and hid the ground under it. A stream tile has to be mostly
## stream, so `stream_min_frac` of the block.
static func downsample_water(
	src: PackedByteArray, src_size: int, out_size: int, stream_min_frac: float
) -> PackedByteArray:
	var ratio: int = src_size / out_size
	var cells: int = ratio * ratio
	var stream_min: int = maxi(int(ceil(float(cells) * stream_min_frac)), 1)
	var out := PackedByteArray()
	out.resize(out_size * out_size)

	for ty: int in out_size:
		var y0: int = ty * ratio
		for tx: int in out_size:
			var x0: int = tx * ratio
			var has_ford: bool = false
			var has_river: bool = false
			var streams: int = 0
			for oy: int in ratio:
				var row: int = (y0 + oy) * src_size + x0
				for ox: int in ratio:
					match int(src[row + ox]):
						MapData.Water.FORD:
							has_ford = true
						MapData.Water.RIVER:
							has_river = true
						MapData.Water.STREAM:
							streams += 1

			var v: int = MapData.Water.NONE
			if has_ford:
				v = MapData.Water.FORD
			elif has_river:
				v = MapData.Water.RIVER
			elif streams >= stream_min:
				v = MapData.Water.STREAM
			out[ty * out_size + tx] = v

	return out


## Mean of a float layer over only the cells where `mask` is set, per block. Used for the water
## surface, where averaging the dry cells in with the wet ones would drag the level into the ground.
static func downsample_masked_mean(
	src: PackedFloat32Array, mask: PackedByteArray, src_size: int, out_size: int
) -> PackedFloat32Array:
	var ratio: int = src_size / out_size
	var out := PackedFloat32Array()
	out.resize(out_size * out_size)

	for ty: int in out_size:
		var y0: int = ty * ratio
		for tx: int in out_size:
			var x0: int = tx * ratio
			var sum: float = 0.0
			var count: int = 0
			for oy: int in ratio:
				var row: int = (y0 + oy) * src_size + x0
				for ox: int in ratio:
					if mask[row + ox] != 0:
						sum += src[row + ox]
						count += 1
			out[ty * out_size + tx] = sum / float(count) if count > 0 else 0.0

	return out


static func quantize(avg: PackedFloat32Array, quant: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(avg.size())
	var inv: float = 1.0 / quant
	for i: int in avg.size():
		out[i] = int(round(avg[i] * inv))
	return out


## Classify every edge on the map.
##
## Only the four canonical directions are written; the other four are the same edges read from the
## other side. Thresholds are integer quantum counts, so a transition is never "almost" passable.
static func classify_transitions(md: MapData, cfg: Config) -> void:
	var normal_max: int = cfg.i("traversal.normal_max_dl", 2)
	var rough_max: int = cfg.i("traversal.rough_max_dl", 4)
	var size: int = md.size

	for i: int in md.n:
		var x: int = i % size
		var y: int = i / size
		var lv: int = md.level[i]
		for slot: int in 4:
			var d: int = Grid.CANON[slot]
			var nx: int = x + Grid.DX[d]
			var ny: int = y + Grid.DY[d]
			if nx < 0 or nx >= size or ny < 0 or ny >= size:
				# Off-map edges are blocked. The map boundary is a wall, not a cliff you can drive
				# off, and treating it as anything else means pathfinding has to special-case it.
				md.trans[i * 4 + slot] = MapData.Trans.BLOCKED
				continue
			md.trans[i * 4 + slot] = classify_edge(
				lv, md.level[ny * size + nx], normal_max, rough_max
			)


static func classify_edge(a: int, b: int, normal_max: int, rough_max: int) -> int:
	var dl: int = absi(a - b)
	if dl <= normal_max:
		return MapData.Trans.NORMAL
	if dl <= rough_max:
		return MapData.Trans.ROUGH
	return MapData.Trans.BLOCKED


## Re-classify only the edges touching a tile, after something moved its height. Used by
## connectivity repair and by road cut-and-fill, both of which edit a handful of tiles and would
## otherwise have to re-sweep the whole map.
static func reclassify_around(md: MapData, i: int, cfg: Config) -> void:
	var normal_max: int = cfg.i("traversal.normal_max_dl", 2)
	var rough_max: int = cfg.i("traversal.rough_max_dl", 4)
	var size: int = md.size

	for d: int in 8:
		var x: int = i % size + Grid.DX[d]
		var y: int = i / size + Grid.DY[d]
		if x < 0 or x >= size or y < 0 or y >= size:
			continue
		var nb: int = y * size + x
		var cls: int = classify_edge(md.level[i], md.level[nb], normal_max, rough_max)
		md.set_transition(i, d, cls)


## Build the gameplay map from the finished heightfield and its hydrology.
static func build(
	field: HeightField, hydro: Hydrology.Result, cfg: Config, master_seed: int, out_size: int
) -> MapData:
	var md := MapData.create(out_size)
	md.master_seed = master_seed
	md.tile_m = cfg.f("world.tile_m", 10.0)
	md.quant = cfg.f("world.quant_m", 0.5)

	var avg: PackedFloat32Array = downsample(field, out_size)
	md.level = quantize(avg, md.quant)
	md.moisture = downsample_layer(hydro.moisture, field.w, out_size)

	# Channels and fords collapse by significance, not by majority — see downsample_max.
	var wet := PackedByteArray()
	wet.resize(field.w * field.h)
	for i: int in wet.size():
		if hydro.ford[i] != 0:
			wet[i] = MapData.Water.FORD
		elif hydro.channel[i] == Hydrology.Channel.RIVER:
			wet[i] = MapData.Water.RIVER
		elif hydro.channel[i] == Hydrology.Channel.STREAM:
			wet[i] = MapData.Water.STREAM
	md.water = downsample_water(
		wet, field.w, out_size, cfg.f("hydrology.stream_tile_min_frac", 0.25)
	)

	var channel_mask := PackedByteArray()
	channel_mask.resize(field.w * field.h)
	for i2: int in channel_mask.size():
		channel_mask[i2] = 1 if hydro.channel[i2] != Hydrology.Channel.NONE else 0
	var surface: PackedFloat32Array = downsample_masked_mean(
		hydro.surface, channel_mask, field.w, out_size
	)
	var inv_q: float = 1.0 / md.quant
	for i3: int in md.n:
		md.water_level[i3] = (
			int(round(surface[i3] * inv_q)) if md.water[i3] != MapData.Water.NONE else 0
		)

	classify_transitions(md, cfg)
	return md
