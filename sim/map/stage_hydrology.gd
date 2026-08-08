class_name Hydrology
extends RefCounted

## Stage 4.5 — where the water goes.
##
## Five steps, in an order that is not negotiable:
##
##   1. **Fill depressions.** Every pit is raised until it drains to the map edge. Skipping this is
##      the single most common way to get a broken map: D8 lands in the pit, flow accumulation
##      finds a cycle, and rivers arrive with gaps in them — which is exactly what the acceptance
##      check looks for.
##   2. **D8 flow direction.** Each cell points at its steepest downhill neighbour.
##   3. **Flow accumulation** by topological order. Not recursion — the drainage tree is 640k deep
##      in the worst case and would blow the stack.
##   4. **Carve** the channels the accumulation found, and enforce that beds run downhill.
##   5. **Find fords**, and make some if the map did not offer any.
##
## The three data structures that make this affordable are all the same trick: an integer array
## indexed by cell, standing in for something that would otherwise allocate.

const TAG := "hydrology"

enum Channel { NONE = 0, STREAM = 1, RIVER = 2 }


class Result extends RefCounted:
	## Steepest-downhill neighbour of each cell, or -1 at a map-edge outlet.
	var receiver: PackedInt32Array
	## Cells ordered headwaters first, outlets last. Reused by carving and by the bed monotonicity
	## pass, both of which need to walk the drainage tree in a known direction.
	var topo_order: PackedInt32Array
	## Number of cells draining through each cell, including itself.
	var accum: PackedFloat32Array
	## Channel.NONE / STREAM / RIVER
	var channel: PackedByteArray
	## Metres cut below the pre-carve surface. Zero away from channels.
	var depth: PackedFloat32Array
	## Water surface elevation in metres, meaningful only where channel != NONE.
	var surface: PackedFloat32Array
	## 1 where a channel cell is shallow enough and its banks gentle enough to drive across.
	var ford: PackedByteArray
	## Normalized log accumulation, 0..1. What stage 4.7 reads as "moisture".
	var moisture: PackedFloat32Array

	var ford_count: int = 0
	var bed_fixups: int = 0
	var stream_cells: int = 0
	var river_cells: int = 0
	var filled_cells: int = 0
	var forced_fords: int = 0
	var elapsed_usec: int = 0


static func run(
	field: HeightField, cfg: Config, master_seed: int, progress: Callable = Callable()
) -> Result:
	var t0: int = Time.get_ticks_usec()
	var r := Result.new()

	if progress.is_valid():
		progress.call(TAG, 0.0)
	r.filled_cells = fill_depressions(field, cfg)

	if progress.is_valid():
		progress.call(TAG, 0.3)
	r.receiver = flow_directions(field)

	if progress.is_valid():
		progress.call(TAG, 0.45)
	_accumulate(field, r)

	if progress.is_valid():
		progress.call(TAG, 0.6)
	_classify_channels(field, cfg, r)

	if progress.is_valid():
		progress.call(TAG, 0.7)
	_carve(field, cfg, r)
	_enforce_bed_slope(field, cfg, r)

	if progress.is_valid():
		progress.call(TAG, 0.9)
	_detect_fords(field, cfg, master_seed, r)
	# Easing a ford raises the bed at the crossing, which leaves the water immediately upstream
	# sitting below it. Re-levelling backfills that reach — which is what a real gravel bar does.
	r.bed_fixups = _enforce_bed_slope(field, cfg, r)
	_compute_surface(field, cfg, r)

	if progress.is_valid():
		progress.call(TAG, 1.0)

	r.elapsed_usec = Time.get_ticks_usec() - t0
	return r


# --- 1. depression filling ---------------------------------------------------------------------

## Priority-flood with an epsilon (Barnes et al.). Water rises from the map edge inward; a cell is
## raised to just above whatever it was reached from, which guarantees a strictly descending path
## from every cell to the edge.
##
## The priority queue is a bucket queue over height quantized to a centimetre, because pops proceed
## in non-decreasing water level — a cursor that only ever moves forward is all the ordering this
## needs, and it turns an O(n log n) heap into O(n).
##
## The buckets themselves are an intrusive linked list (`bucket_head` + `next`), not an array of
## arrays. Reading a PackedInt32Array out of an Array, pushing to it and writing it back copies the
## whole bucket on every push — the copy-on-write trap from CLAUDE.md, and here it would be
## quadratic.
static func fill_depressions(field: HeightField, cfg: Config) -> int:
	var eps: float = cfg.f("hydrology.fill_epsilon_m", 0.001)
	var bucket_m: float = cfg.f("hydrology.fill_bucket_m", 0.01)

	var w: int = field.w
	var h: int = field.h
	var n: int = w * h
	var H: PackedFloat32Array = field.data

	var mm: Vector2 = field.min_max()
	var lo: float = mm.x
	var inv_bucket: float = 1.0 / bucket_m
	var n_buckets: int = int((mm.y - lo) * inv_bucket) + 4

	var bucket_head := PackedInt32Array()
	bucket_head.resize(n_buckets)
	bucket_head.fill(-1)
	var next := PackedInt32Array()
	next.resize(n)
	next.fill(-1)
	var visited := PackedByteArray()
	visited.resize(n)

	var cursor: int = 0

	# Seed with the whole border. These are the outlets: water that reaches them has left the map.
	for x: int in w:
		for c: int in [x, (h - 1) * w + x]:
			if visited[c] == 0:
				visited[c] = 1
				var b: int = clampi(int((H[c] - lo) * inv_bucket), 0, n_buckets - 1)
				next[c] = bucket_head[b]
				bucket_head[b] = c
	for y: int in range(1, h - 1):
		for c: int in [y * w, y * w + w - 1]:
			if visited[c] == 0:
				visited[c] = 1
				var b2: int = clampi(int((H[c] - lo) * inv_bucket), 0, n_buckets - 1)
				next[c] = bucket_head[b2]
				bucket_head[b2] = c

	var off := PackedInt32Array([-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1])
	var raised: int = 0

	while cursor < n_buckets:
		var c: int = bucket_head[cursor]
		if c == -1:
			cursor += 1
			continue
		bucket_head[cursor] = next[c]

		var hc: float = H[c]
		var x0: int = c % w
		var y0: int = c / w
		var x_left: bool = x0 == 0
		var x_right: bool = x0 == w - 1
		var y_top: bool = y0 == 0
		var y_bottom: bool = y0 == h - 1

		for d: int in 8:
			if y_top and (d == 0 or d == 1 or d == 7):
				continue
			if y_bottom and (d == 3 or d == 4 or d == 5):
				continue
			if x_right and (d == 1 or d == 2 or d == 3):
				continue
			if x_left and (d == 5 or d == 6 or d == 7):
				continue

			var nb: int = c + off[d]
			if visited[nb] != 0:
				continue
			visited[nb] = 1

			# The epsilon is what removes flats. Without it a filled basin is perfectly level, D8
			# has nothing to choose between, and the tie-breaking decides the river's course.
			var floor_h: float = hc + eps
			if H[nb] < floor_h:
				H[nb] = floor_h
				raised += 1

			# A cell can only be raised, never lowered, so its bucket is at or after the cursor.
			var b3: int = maxi(clampi(int((H[nb] - lo) * inv_bucket), 0, n_buckets - 1), cursor)
			next[nb] = bucket_head[b3]
			bucket_head[b3] = nb

	field.data = H
	return raised


# --- 2. D8 flow direction ----------------------------------------------------------------------

## Steepest descent among the eight neighbours, with diagonal drops divided by their longer
## distance so a gentle diagonal does not beat a steep orthogonal. Ties go to the lowest direction
## index, which makes the choice reproducible rather than dependent on float comparison order.
static func flow_directions(field: HeightField) -> PackedInt32Array:
	var w: int = field.w
	var h: int = field.h
	var H: PackedFloat32Array = field.data

	var receiver := PackedInt32Array()
	receiver.resize(w * h)
	receiver.fill(-1)

	var off := PackedInt32Array([-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1])
	var inv_d := PackedFloat32Array()
	inv_d.resize(8)
	var inv_ortho: float = 1.0 / field.cell_m
	var inv_diag: float = 1.0 / (field.cell_m * sqrt(2.0))
	for d: int in 8:
		inv_d[d] = inv_diag if (d & 1) == 1 else inv_ortho

	for y: int in range(1, h - 1):
		var row: int = y * w
		for x: int in range(1, w - 1):
			var i: int = row + x
			var hi: float = H[i]
			var best: int = -1
			var best_slope: float = 0.0
			for d: int in 8:
				var nb: int = i + off[d]
				var slope: float = (hi - H[nb]) * inv_d[d]
				if slope > best_slope:
					best_slope = slope
					best = nb
			receiver[i] = best

	return receiver


# --- 3. flow accumulation ----------------------------------------------------------------------

## Kahn topological order over the drainage tree.
##
## Every cell contributes one unit of rain and passes its total to its receiver. Processing cells in
## an order where a cell is only handled once everything upstream of it has been makes this a single
## linear pass with no recursion and no revisiting.
##
## `tail == n` at the end is a free cycle detector: a cycle means some cell never reached indegree
## zero, which means depression filling left a pit. That is worth catching loudly here rather than
## discovering it as a river with a hole in it three stages later.
static func _accumulate(field: HeightField, r: Result) -> void:
	var n: int = field.w * field.h
	var receiver: PackedInt32Array = r.receiver

	var indeg := PackedInt32Array()
	indeg.resize(n)
	for i: int in n:
		var rc: int = receiver[i]
		if rc >= 0:
			indeg[rc] += 1

	var order := PackedInt32Array()
	order.resize(n)
	var head: int = 0
	var tail: int = 0
	for i: int in n:
		if indeg[i] == 0:
			order[tail] = i
			tail += 1

	var acc := PackedFloat32Array()
	acc.resize(n)
	acc.fill(1.0)

	while head < tail:
		var c: int = order[head]
		head += 1
		var rc2: int = receiver[c]
		if rc2 < 0:
			continue
		acc[rc2] += acc[c]
		indeg[rc2] -= 1
		if indeg[rc2] == 0:
			order[tail] = rc2
			tail += 1

	assert(tail == n, "flow accumulation found a cycle — depression filling left a pit")

	r.topo_order = order
	r.accum = acc

	# Moisture is the *percentile* of log accumulation, not the raw value scaled somehow.
	#
	# Accumulation spans five orders of magnitude between a hilltop and a river mouth, and its
	# distribution is brutally skewed — the great majority of cells drain only themselves and a
	# neighbour or two. Dividing log(accum) by log(n) puts almost the whole map below 0.1, so any
	# threshold expressed as "damp ground" either catches nothing or catches everything. That is
	# how terrain typing first shipped 0.2% woods.
	#
	# As a percentile, a threshold means what it reads as: 0.45 is "the wetter 55% of the map", and
	# it means the same thing on every seed and at every resolution.
	var moisture := PackedFloat32Array()
	moisture.resize(n)

	const BINS := 2048
	var log_acc := PackedFloat32Array()
	log_acc.resize(n)
	var lo: float = INF
	var hi: float = -INF
	for i: int in n:
		var v: float = log(acc[i])
		log_acc[i] = v
		if v < lo:
			lo = v
		if v > hi:
			hi = v

	var span: float = maxf(hi - lo, 1e-6)
	var scale: float = float(BINS - 1) / span
	var hist := PackedInt32Array()
	hist.resize(BINS)
	for i2: int in n:
		hist[int((log_acc[i2] - lo) * scale)] += 1

	var cumulative := PackedFloat32Array()
	cumulative.resize(BINS)
	var running: int = 0
	var inv_n: float = 1.0 / float(n)
	for b: int in BINS:
		running += hist[b]
		cumulative[b] = float(running) * inv_n

	for i3: int in n:
		moisture[i3] = cumulative[int((log_acc[i3] - lo) * scale)]
	r.moisture = moisture


# --- 4. channels and carving -------------------------------------------------------------------

## Thresholds are stored as fractions of the total cell count, not as absolute accumulation values.
## An absolute threshold silently means something different at every heightfield resolution, which
## would make the quarter-scale test pipeline generate a completely different drainage network from
## the shipping one.
static func _classify_channels(field: HeightField, cfg: Config, r: Result) -> void:
	var n: int = field.w * field.h
	var stream_at: float = cfg.f("hydrology.stream_threshold_frac", 0.0008) * float(n)
	var river_at: float = cfg.f("hydrology.river_threshold_frac", 0.006) * float(n)

	var channel := PackedByteArray()
	channel.resize(n)
	var streams: int = 0
	var rivers: int = 0
	for i: int in n:
		var a: float = r.accum[i]
		if a >= river_at:
			channel[i] = Channel.RIVER
			rivers += 1
		elif a >= stream_at:
			channel[i] = Channel.STREAM
			streams += 1
	r.channel = channel
	r.stream_cells = streams
	r.river_cells = rivers


## Cut the channel network into the terrain.
##
## The cross-section is a parabola several cells wide, not a single-cell slot. At the shipping
## resolution four heightfield cells collapse into one gameplay tile, and a one-cell channel simply
## averages away to nothing — the river would exist in the data and be invisible on the map.
##
## Afterwards the bed is forced to descend. Carving depth is a function of accumulation, and
## accumulation is not perfectly monotonic along a channel, so without this pass a river can run
## uphill for a cell or two. That is the failure the acceptance check names.
static func _carve(field: HeightField, cfg: Config, r: Result) -> void:
	var w: int = field.w
	var h: int = field.h
	var n: int = w * h
	var H: PackedFloat32Array = field.data

	var carve_k: float = cfg.f("hydrology.carve_k", 9.0)
	var carve_exp: float = cfg.f("hydrology.carve_exp", 0.42)
	var max_depth: float = cfg.f("hydrology.max_carve_depth_m", 5.0)
	var stream_hw: float = cfg.f("hydrology.channel_half_width_cells", 2.5)
	var river_hw: float = cfg.f("hydrology.river_half_width_cells", 4.5)
	var min_slope: float = cfg.f("hydrology.min_bed_slope", 0.0012)

	var depth := PackedFloat32Array()
	depth.resize(n)
	var inv_n: float = 1.0 / float(n)

	# Target surface, lowered by whichever channel cell cuts deepest here.
	var target: PackedFloat32Array = H.duplicate()

	for i: int in n:
		var ch: int = channel_at(r, i)
		if ch == Channel.NONE:
			continue

		var d: float = minf(carve_k * pow(r.accum[i] * inv_n, carve_exp), max_depth)
		depth[i] = d
		var hw: float = river_hw if ch == Channel.RIVER else stream_hw

		var x0: int = i % w
		var y0: int = i / w
		var ri: int = int(ceil(hw))
		var inv_hw2: float = 1.0 / (hw * hw)

		for oy: int in range(maxi(y0 - ri, 0), mini(y0 + ri + 1, h)):
			var dy: float = float(oy - y0)
			var orow: int = oy * w
			for ox: int in range(maxi(x0 - ri, 0), mini(x0 + ri + 1, w)):
				var dx: float = float(ox - x0)
				var d2: float = dx * dx + dy * dy
				if d2 > hw * hw:
					continue
				# The cut is a depth removed from whatever is already there, full at the
				# centreline and tapering to nothing at the rim.
				#
				# Expressing it as an absolute target elevation instead — bed plus a parabola —
				# looks equivalent and is not: on a steep valley wall the rim of the parabola sits
				# far below the hillside, so the carve slices the wall down to the channel's own
				# height and leaves a cliff at the edge of its radius. Cutting relative to the
				# local surface leaves the valley walls alone.
				var cut: float = d * (1.0 - d2 * inv_hw2)
				var j: int = orow + ox
				var t: float = H[j] - cut
				if t < target[j]:
					target[j] = t

	field.data = target
	r.depth = depth


## Force every channel bed to sit above the bed it drains into.
##
## Carving depth is a function of flow accumulation, and accumulation is not perfectly monotonic
## along a channel, so the raw cut can leave a cell or two running uphill. Ford easing then raises
## beds deliberately, which breaks the ordering again — so this runs twice, once after carving and
## once after fords, rather than being folded into either.
##
## Walking the topological order backwards visits outlets first, which means a cell's receiver
## already has its final height by the time the cell is checked.
static func _enforce_bed_slope(field: HeightField, cfg: Config, r: Result) -> int:
	var w: int = field.w
	var H: PackedFloat32Array = field.data
	var min_slope: float = cfg.f("hydrology.min_bed_slope", 0.0012)
	var cell_m: float = field.cell_m
	var diag_m: float = cell_m * sqrt(2.0)
	var order: PackedInt32Array = r.topo_order
	var fixed: int = 0

	for k: int in range(order.size() - 1, -1, -1):
		var c: int = order[k]
		if channel_at(r, c) == Channel.NONE:
			continue
		var rc: int = r.receiver[c]
		if rc < 0:
			continue
		var step: int = rc - c
		var dist: float = diag_m if (step != -1 and step != 1 and step != w and step != -w) else cell_m
		var floor_h: float = H[rc] + min_slope * dist
		if H[c] < floor_h:
			H[c] = floor_h
			fixed += 1

	field.data = H
	return fixed


## Water surface elevation: a fraction of the cut depth above the bed, so a deep river reads as
## deep and a headwater stream is a damp line rather than a canal. Computed last, once the bed has
## stopped moving.
static func _compute_surface(field: HeightField, cfg: Config, r: Result) -> void:
	var n: int = field.w * field.h
	var fill_frac: float = cfg.f("hydrology.water_fill_fraction", 0.45)
	var surface := PackedFloat32Array()
	surface.resize(n)
	for i: int in n:
		if channel_at(r, i) != Channel.NONE:
			surface[i] = field.data[i] + r.depth[i] * fill_frac
	r.surface = surface


static func channel_at(r: Result, i: int) -> int:
	return int(r.channel[i])


# --- 5. fords ----------------------------------------------------------------------------------

## A ford is somewhere a tank can cross without a bridge: shallow water, and banks gentle enough to
## drive down and back up.
##
## Searching for naturally occurring ones is not enough. The spec requires at least two per map, and
## a seed with one deeply incised river simply will not offer them. So this is the same
## generate-measure-repair shape used for connectivity in 4.6: find what the terrain gives, and if
## that is not enough, pick the least-bad candidates and make them work.
static func _detect_fords(field: HeightField, cfg: Config, master_seed: int, r: Result) -> void:
	var w: int = field.w
	var h: int = field.h
	var n: int = w * h

	var max_depth: float = cfg.f("hydrology.ford_max_depth_m", 0.9)
	var max_bank: float = cfg.f("hydrology.ford_max_bank", 0.16)
	var min_fords: int = cfg.i("hydrology.min_fords", 2)
	var sep_tiles: float = cfg.f("hydrology.ford_separation_tiles", 22.0)
	var flatten_r: int = cfg.i("hydrology.ford_flatten_radius_cells", 4)

	# Separation is specified in gameplay tiles; convert once into heightfield cells.
	var cells_per_tile: float = cfg.f("world.tile_m", 10.0) / field.cell_m
	var sep_cells: float = sep_tiles * cells_per_tile
	var sep_cells2: float = sep_cells * sep_cells

	var ford := PackedByteArray()
	ford.resize(n)

	# Score every channel cell: shallow and flat-banked is good. Packed into a sortable integer so
	# the sort is a single PackedInt64Array.sort() rather than a Callable per comparison.
	var scored := PackedInt64Array()
	for i: int in n:
		# Rivers only. A ford is a crossing of something that would otherwise stop a tank, and a
		# headwater stream a metre wide stops nothing — treating every trickle as a ford produced
		# fifty of them per map and made the marker meaningless.
		if channel_at(r, i) != Channel.RIVER:
			continue
		var x: int = i % w
		var y: int = i / w
		if x < 2 or y < 2 or x >= w - 2 or y >= h - 2:
			continue
		var bank: float = _bank_gradient(field, i)
		var score: float = r.depth[i] + bank * 4.0
		# Sort key in the high bits, cell index in the low 21 (enough for 2M cells). Bounded well
		# below 2^42 so the shifted value never runs into the sign bit.
		var key: int = clampi(int(score * 1000.0), 0, (1 << 40) - 1)
		scored.append((key << 21) | i)
	scored.sort()

	# Take the best-scoring crossings that are far enough apart, then make each one drivable if it
	# is not already.
	#
	# There is deliberately no "only accept naturally shallow cells" gate. Rivers are carved metres
	# deep by construction, so no river cell can ever pass a sub-metre depth threshold and such a
	# gate accepts nothing on every seed — the repair path would be the only path that ever ran,
	# while looking like a fallback. Choosing the least-bad crossings and easing them is what
	# actually happens, so that is what the code says.
	var target_count: int = maxi(cfg.i("hydrology.ford_target", 3), min_fords)
	var accepted := PackedInt32Array()
	var flattened: int = 0

	for k: int in scored.size():
		if accepted.size() >= target_count:
			break
		var idx: int = int(scored[k] & 0x1FFFFF)
		if not _far_enough(accepted, idx, w, sep_cells2):
			continue
		if r.depth[idx] > max_depth or _bank_gradient(field, idx) > max_bank:
			_flatten_ford(field, r, idx, flatten_r, max_depth)
			flattened += 1
		accepted.append(idx)

	for k3: int in accepted.size():
		ford[accepted[k3]] = 1

	r.ford = ford
	r.ford_count = accepted.size()
	r.forced_fords = flattened


## Steepness of the banks across the channel, taken as the worse of the two axes. A ford needs a
## way in and a way out, so the constraint is on the maximum, not the average.
static func _bank_gradient(field: HeightField, i: int) -> float:
	var w: int = field.w
	var H: PackedFloat32Array = field.data
	var hc: float = H[i]
	var inv: float = 1.0 / (2.0 * field.cell_m)
	var gx: float = absf(H[i + 1] - hc) + absf(H[i - 1] - hc)
	var gy: float = absf(H[i + w] - hc) + absf(H[i - w] - hc)
	return maxf(gx, gy) * inv


static func _far_enough(accepted: PackedInt32Array, idx: int, w: int, sep2: float) -> bool:
	var x: int = idx % w
	var y: int = idx / w
	for k: int in accepted.size():
		var o: int = accepted[k]
		var dx: float = float(x - (o % w))
		var dy: float = float(y - (o / w))
		if dx * dx + dy * dy < sep2:
			return false
	return true


## Raise the bed and ease the banks until the crossing is drivable. Mass is not conserved here and
## should not be — this is the map being made playable, not sediment moving.
static func _flatten_ford(
	field: HeightField, r: Result, centre: int, radius: int, max_depth: float
) -> void:
	var w: int = field.w
	var h: int = field.h
	var H: PackedFloat32Array = field.data

	var cx: int = centre % w
	var cy: int = centre / w

	# Bank level around the crossing, sampled just outside the channel.
	var bank_sum: float = 0.0
	var bank_n: int = 0
	for oy: int in range(maxi(cy - radius, 0), mini(cy + radius + 1, h)):
		for ox: int in range(maxi(cx - radius, 0), mini(cx + radius + 1, w)):
			var j: int = oy * w + ox
			if channel_at(r, j) == Channel.NONE:
				bank_sum += H[j]
				bank_n += 1
	if bank_n == 0:
		return
	var bank: float = bank_sum / float(bank_n)
	var target_bed: float = bank - max_depth * 0.6

	var rf: float = float(radius)
	for oy2: int in range(maxi(cy - radius, 0), mini(cy + radius + 1, h)):
		var dy: float = float(oy2 - cy)
		for ox2: int in range(maxi(cx - radius, 0), mini(cx + radius + 1, w)):
			var dx: float = float(ox2 - cx)
			var dist: float = sqrt(dx * dx + dy * dy)
			if dist > rf:
				continue
			var j2: int = oy2 * w + ox2
			# Full effect at the crossing, fading out so the ramp blends into the existing banks.
			var t: float = 1.0 - dist / rf
			var want: float = target_bed if channel_at(r, j2) != Channel.NONE else bank
			H[j2] = lerpf(H[j2], want, t * t)
			# The water surface is not touched here; it is derived from the final bed once the
			# levelling pass after fords has run.
			if channel_at(r, j2) != Channel.NONE:
				r.depth[j2] = minf(r.depth[j2], max_depth)

	field.data = H
