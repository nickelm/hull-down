class_name ThermalErosion
extends RefCounted

## Stage 4.4 — thermal erosion to the angle of repose.
##
## Loose material cannot stand steeper than its angle of repose; past that it collapses into a
## talus slope at the foot. Hydraulic erosion leaves plenty of ground steeper than that, so this
## stage walks the field shedding excess downhill until no slope exceeds the limit.
##
## Two implementation points matter:
##
## - **Deltas accumulate into a separate buffer and are applied at the end of each pass.** Writing
##   heights in place would make the result depend on the order cells happen to be visited, which
##   breaks determinism the moment anything about iteration changes. This costs one extra
##   PackedFloat32Array and buys order independence outright.
## - **Mass is conserved exactly.** Every cell subtracts an amount and distributes exactly that
##   amount to its downhill neighbours. Nothing is clamped away, so the sum over the field is
##   invariant and can be asserted rather than approximated.
##
## Border cells shed inward only. Material never leaves the map here — the edge falloff from 4.2
## already put the map's low ground at the rim, and losing mass off the edge would make the
## conservation check meaningless.

const TAG := "thermal"


## Relaxes `field` in place. Returns diagnostics including whether it converged.
static func run(field: HeightField, cfg: Config, progress: Callable = Callable()) -> Dictionary:
	var t0: int = Time.get_ticks_usec()

	var repose_deg: float = cfg.f("erosion.thermal.repose_deg", 40.0)
	var relax: float = cfg.f("erosion.thermal.relax", 0.55)
	var max_passes: int = cfg.i("erosion.thermal.max_passes", 60)
	var slack: float = cfg.f("erosion.thermal.converge_slack_m", 0.001)

	var w: int = field.w
	var h: int = field.h
	var n: int = w * h
	var tan_repose: float = tan(deg_to_rad(repose_deg))

	# The maximum height difference a step may hold, per direction. Diagonal neighbours are further
	# apart, so they are allowed a proportionally larger drop for the same slope.
	var cap_ortho: float = tan_repose * field.cell_m
	var cap_diag: float = tan_repose * field.cell_m * sqrt(2.0)

	var slope_before: float = field.max_slope()
	var mass_before: float = field.total_mass()

	var H: PackedFloat32Array = field.data
	var D := PackedFloat32Array()
	D.resize(n)

	# Neighbour offsets in the same order as Grid's direction tables, with the matching cap.
	var off := PackedInt32Array([-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1])
	var cap := PackedFloat32Array([
		cap_ortho, cap_diag, cap_ortho, cap_diag, cap_ortho, cap_diag, cap_ortho, cap_diag
	])

	var passes: int = 0
	var converged: bool = false

	# Reused per cell rather than allocated in the loop.
	var exc := PackedFloat32Array()
	exc.resize(8)

	# Active list. A full sweep costs O(n) whether or not anything is still out of repose, and most
	# of the field settles within a handful of passes — so after the first sweep only cells that
	# could have changed status are revisited. Enqueueing the 5x5 block around a cell that moved is
	# the conservative choice: the cell and its eight neighbours all changed height, so their
	# neighbours' slopes all changed too.
	var active := PackedInt32Array()
	active.resize(n)
	for i: int in n:
		active[i] = i
	var stamp := PackedInt32Array()
	stamp.resize(n)
	stamp.fill(-1)

	while passes < max_passes and active.size() > 0:
		var next_active := PackedInt32Array()

		for a: int in active.size():
			var i: int = active[a]
			var x: int = i % w
			var y: int = i / w
			var hv: float = H[i]
			var x_left: bool = x == 0
			var x_right: bool = x == w - 1
			var y_top: bool = y == 0
			var y_bottom: bool = y == h - 1

			var total: float = 0.0
			var worst: float = 0.0
			for d: int in 8:
				# Skip neighbours that would fall off the edge. Done with explicit edge flags
				# rather than an in_bounds() call: this is the innermost loop in the stage.
				exc[d] = 0.0
				if y_top and (d == 0 or d == 1 or d == 7):
					continue
				if y_bottom and (d == 3 or d == 4 or d == 5):
					continue
				if x_right and (d == 1 or d == 2 or d == 3):
					continue
				if x_left and (d == 5 or d == 6 or d == 7):
					continue

				var e: float = hv - H[i + off[d]] - cap[d]
				if e > 0.0:
					exc[d] = e
					total += e
					if e > worst:
						worst = e

			if total <= slack:
				continue

			# Shed a fraction of the single worst violation, split between the offending
			# neighbours in proportion to how far each is over. Moving the worst rather than the
			# total keeps a cell with eight mildly-steep neighbours from emptying itself in one
			# pass; halving it means an isolated pair lands exactly on the limit instead of
			# overshooting and oscillating.
			var amount: float = worst * 0.5 * relax
			var inv_total: float = amount / total
			for d: int in 8:
				var e2: float = exc[d]
				if e2 > 0.0:
					D[i + off[d]] += e2 * inv_total
			D[i] -= amount

			for oy: int in range(maxi(y - 2, 0), mini(y + 3, h)):
				var orow: int = oy * w
				for ox: int in range(maxi(x - 2, 0), mini(x + 3, w)):
					var j: int = orow + ox
					if stamp[j] != passes:
						stamp[j] = passes
						next_active.append(j)

		if next_active.is_empty():
			converged = true
			break

		# Every cell that received a delta lies inside the 5x5 block of some cell that moved, so
		# the enqueued set covers them all. Deltas are applied here rather than during the sweep so
		# the result does not depend on visit order.
		for k: int in next_active.size():
			var j2: int = next_active[k]
			var d2: float = D[j2]
			if d2 != 0.0:
				H[j2] += d2
				D[j2] = 0.0

		active = next_active
		passes += 1

		if progress.is_valid():
			progress.call(TAG, float(passes) / float(max_passes))

	field.data = H

	var mass_after: float = field.total_mass()
	var drift: float = 0.0
	if absf(mass_before) > 1e-6:
		drift = absf(mass_after - mass_before) / absf(mass_before) * 100.0

	if progress.is_valid():
		progress.call(TAG, 1.0)

	return {
		"passes": passes,
		"converged": converged,
		"repose_deg": repose_deg,
		"slope_limit": tan_repose,
		"slope_before": slope_before,
		"slope_after": field.max_slope(),
		"max_step_after_m": field.max_gradient(),
		"drift_pct": drift,
		"elapsed_usec": Time.get_ticks_usec() - t0,
	}
