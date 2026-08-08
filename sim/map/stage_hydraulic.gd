class_name HydraulicErosion
extends RefCounted

## Stage 4.3 — droplet hydraulic erosion.
##
## Rain a few hundred thousand particles on the field. Each rolls downhill, picking up material
## where it accelerates on steep ground and dropping it where it slows on flats. Run enough of them
## and the dendritic valley networks that make terrain read as *eroded* rather than *generated*
## emerge on their own — nobody draws a river.
##
## Three details are the difference between that and a mess:
##
## - **Gradients come from bilinear interpolation of the four surrounding cells**, not from a
##   nearest-cell difference. A nearest-cell gradient can only point in eight directions, so every
##   droplet snaps to the lattice and the result is a grid of axis-aligned scratches.
## - **Sediment capacity has a floor.** Without `min_capacity`, a droplet reaching flat ground has
##   zero capacity and dumps its entire load in one cell, which severs valleys exactly where they
##   should run out onto the plain.
## - **Erosion spreads over a brush; deposition is bilinear into four cells.** That asymmetry is
##   what makes valleys carve wider than the ridges of spoil beside them. Symmetric erosion and
##   deposition produce narrow slots.
##
## The whole droplet lifetime is one function body: no helper calls, no Vector2, raw floats. At
## 500k droplets over 640k cells this loop runs some hundreds of millions of array operations, and
## GDScript charges for every function call.

const TAG := "hydraulic"


## Erodes `field` in place. Returns {mass_before, mass_after, drift_pct, droplets, elapsed_usec}.
static func run(
	field: HeightField, cfg: Config, master_seed: int, droplet_count: int,
	progress: Callable = Callable()
) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var mass_before: float = field.total_mass()

	var w: int = field.w
	var h: int = field.h
	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.TERRAIN, TAG)

	var max_lifetime: int = cfg.i("erosion.hydraulic.max_lifetime", 34)
	var inertia: float = cfg.f("erosion.hydraulic.inertia", 0.045)
	var capacity_k: float = cfg.f("erosion.hydraulic.capacity_k", 4.0)
	var min_capacity: float = cfg.f("erosion.hydraulic.min_capacity", 0.012)
	var erode_speed: float = cfg.f("erosion.hydraulic.erode_speed", 0.32)
	var deposit_speed: float = cfg.f("erosion.hydraulic.deposit_speed", 0.28)
	var evaporate: float = cfg.f("erosion.hydraulic.evaporate", 0.018)
	var gravity: float = cfg.f("erosion.hydraulic.gravity", 9.0)
	var initial_water: float = cfg.f("erosion.hydraulic.initial_water", 1.0)
	var initial_speed: float = cfg.f("erosion.hydraulic.initial_speed", 1.0)
	var brush_radius: int = cfg.i("erosion.hydraulic.brush_radius", 2)
	var progress_every: int = maxi(cfg.i("erosion.hydraulic.progress_every", 25000), 1)

	# Precomputed erosion brush: flat index offsets and normalized weights, so the inner loop does
	# no distance arithmetic.
	var brush_offset := PackedInt32Array()
	var brush_weight := PackedFloat32Array()
	_build_brush(brush_radius, w, brush_offset, brush_weight)
	var brush_n: int = brush_offset.size()

	var inertia_inv: float = 1.0 - inertia
	var evaporate_keep: float = 1.0 - evaporate
	var wf: float = float(w)
	var hf: float = float(h)
	var border: float = float(brush_radius + 1)

	# Local alias. PackedFloat32Array is copy-on-write, so the first write unshares it into a
	# private buffer and every write after that is direct — but it must be assigned back at the end
	# or the entire run is discarded.
	var H: PackedFloat32Array = field.data

	for n: int in droplet_count:
		var px: float = rng.randf_range(border, wf - border - 1.0)
		var py: float = rng.randf_range(border, hf - border - 1.0)
		var dirx: float = 0.0
		var diry: float = 0.0
		var speed: float = initial_speed
		var water: float = initial_water
		var sediment: float = 0.0

		for life: int in max_lifetime:
			var x0: int = int(px)
			var y0: int = int(py)
			var u: float = px - float(x0)
			var v: float = py - float(y0)
			var i: int = y0 * w + x0

			var h00: float = H[i]
			var h10: float = H[i + 1]
			var h01: float = H[i + w]
			var h11: float = H[i + w + 1]

			var height: float = (
				h00 * (1.0 - u) * (1.0 - v)
				+ h10 * u * (1.0 - v)
				+ h01 * (1.0 - u) * v
				+ h11 * u * v
			)
			var gx: float = (h10 - h00) * (1.0 - v) + (h11 - h01) * v
			var gy: float = (h01 - h00) * (1.0 - u) + (h11 - h10) * u

			# Blend the previous heading with the downhill direction. Pure gradient descent makes
			# droplets stall in every dimple; a little inertia carries them across.
			dirx = dirx * inertia - gx * inertia_inv
			diry = diry * inertia - gy * inertia_inv
			var len2: float = dirx * dirx + diry * diry
			if len2 < 1e-12:
				break
			var inv_len: float = 1.0 / sqrt(len2)
			dirx *= inv_len
			diry *= inv_len

			px += dirx
			py += diry

			# Off the map, or into the border strip the brush cannot reach: drop the load where the
			# droplet last was, so nothing is created or destroyed.
			if px < border or px >= wf - border or py < border or py >= hf - border:
				if sediment > 0.0:
					H[i] += sediment * (1.0 - u) * (1.0 - v)
					H[i + 1] += sediment * u * (1.0 - v)
					H[i + w] += sediment * (1.0 - u) * v
					H[i + w + 1] += sediment * u * v
				break

			var nx0: int = int(px)
			var ny0: int = int(py)
			var nu: float = px - float(nx0)
			var nv: float = py - float(ny0)
			var ni: int = ny0 * w + nx0
			var new_height: float = (
				H[ni] * (1.0 - nu) * (1.0 - nv)
				+ H[ni + 1] * nu * (1.0 - nv)
				+ H[ni + w] * (1.0 - nu) * nv
				+ H[ni + w + 1] * nu * nv
			)
			var dh: float = new_height - height

			if dh >= 0.0:
				# Ran uphill into a dip. Fill it, but never above the far lip — overfilling makes
				# the droplet climb its own spoil heap.
				var fill: float = minf(sediment, dh)
				sediment -= fill
				H[i] += fill * (1.0 - u) * (1.0 - v)
				H[i + 1] += fill * u * (1.0 - v)
				H[i + w] += fill * (1.0 - u) * v
				H[i + w + 1] += fill * u * v
			else:
				var capacity: float = maxf(-dh * speed * water * capacity_k, min_capacity)
				if sediment > capacity:
					var drop: float = (sediment - capacity) * deposit_speed
					sediment -= drop
					H[i] += drop * (1.0 - u) * (1.0 - v)
					H[i + 1] += drop * u * (1.0 - v)
					H[i + w] += drop * (1.0 - u) * v
					H[i + w + 1] += drop * u * v
				else:
					# Never cut deeper than the step the droplet just took, or it digs a pit
					# underneath itself and traps the next droplet in it.
					var take: float = minf((capacity - sediment) * erode_speed, -dh)
					sediment += take
					for b: int in brush_n:
						H[i + brush_offset[b]] -= take * brush_weight[b]

			# Falling converts height into speed. maxf guards the uphill case.
			speed = sqrt(maxf(speed * speed - dh * gravity, 0.0))
			water *= evaporate_keep

			if life == max_lifetime - 1 and sediment > 0.0:
				# Out of lifetime still loaded. Put it down rather than deleting it.
				H[ni] += sediment * (1.0 - nu) * (1.0 - nv)
				H[ni + 1] += sediment * nu * (1.0 - nv)
				H[ni + w] += sediment * (1.0 - nu) * nv
				H[ni + w + 1] += sediment * nu * nv
				sediment = 0.0

		if progress.is_valid() and (n % progress_every) == 0:
			progress.call(TAG, float(n) / float(droplet_count))

	field.data = H

	var mass_after: float = field.total_mass()
	var drift: float = 0.0
	if absf(mass_before) > 1e-6:
		drift = absf(mass_after - mass_before) / absf(mass_before) * 100.0

	if progress.is_valid():
		progress.call(TAG, 1.0)

	return {
		"mass_before": mass_before,
		"mass_after": mass_after,
		"drift_pct": drift,
		"droplets": droplet_count,
		"elapsed_usec": Time.get_ticks_usec() - t0,
	}


## Radius-weighted brush, expressed as flat index offsets so the hot loop adds a single integer.
## Weights fall off linearly with distance and sum to 1, which is what keeps erosion mass-neutral
## against the bilinear deposition on the other side of the ledger.
static func _build_brush(
	radius: int, w: int, out_offset: PackedInt32Array, out_weight: PackedFloat32Array
) -> void:
	var total: float = 0.0
	var r: float = float(radius)
	for oy: int in range(-radius, radius + 1):
		for ox: int in range(-radius, radius + 1):
			var d: float = sqrt(float(ox * ox + oy * oy))
			if d > r:
				continue
			var weight: float = 1.0 - d / (r + 1.0)
			out_offset.append(oy * w + ox)
			out_weight.append(weight)
			total += weight

	var inv: float = 1.0 / maxf(total, 1e-9)
	for k: int in out_weight.size():
		out_weight[k] = out_weight[k] * inv
