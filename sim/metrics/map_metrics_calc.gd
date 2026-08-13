class_name MapMetrics
extends RefCounted

## Stage 4.11 — is this map worth playing on?
##
## Procedural generation produces maps; it does not produce *good* maps. These four measurements
## are the definition of good used by the generate-measure-reject loop, and each one is a claim
## about how a battle on the map would go:
##
##   sightlines    how far you can see, which sets engagement range and therefore which units matter
##   hull down     how much ground offers a firing position that does not expose the hull
##   chokepoints   how many places the map funnels through
##   balance       whether the two sides start with comparable ground
##
## Three of the four are not computed the way the spec describes them. The reasons are in decision
## record 0009 and repeated at each site — in every case the literal reading either measured
## something other than the terrain, or cost minutes per map.


static func evaluate(md: MapData, cfg: Config, master_seed: int) -> Dictionary:
	var t0: int = Time.get_ticks_usec()

	var graph: TraversalGraph = TraversalGraph.build(md, cfg)

	var sight: Dictionary = sightlines(md, cfg, master_seed)
	var hull: Dictionary = hull_down_fraction(md, cfg)
	var choke: int = chokepoints(md, cfg, graph)
	var balance: Dictionary = zone_balance(md, cfg)
	var escarpment: float = md.escarpment_fraction()
	var variety: Dictionary = relief_variety(md)
	var rivers: Dictionary = river_crossings(md, graph)

	var failures := PackedStringArray()

	# Only gated where the river genuinely divides the map. Where it does not, a crossing count is
	# not a fact about the terrain, it is a fact about where the channel happened to stop.
	if bool(rivers["spans_map"]):
		var cross_min: int = cfg.i("metrics.river_crossings_min", 2)
		var cross_max: int = cfg.i("metrics.river_crossings_max", 4)
		var crossings: int = int(rivers["crossings"])
		if crossings < cross_min or crossings > cross_max:
			failures.append("river crossings %d outside %d-%d" % [crossings, cross_min, cross_max])

	var sight_min: float = cfg.f("metrics.sightline_median_min_m", 300.0)
	var sight_max: float = cfg.f("metrics.sightline_median_max_m", 900.0)
	var median: float = float(sight["ray_median_m"])
	if median < sight_min or median > sight_max:
		failures.append("sightline median %.0f m outside %.0f-%.0f m"
			% [median, sight_min, sight_max])

	var hull_min: float = cfg.f("metrics.hull_down_min_frac", 0.05)
	if float(hull["fraction"]) < hull_min:
		failures.append("hull-down %.1f%% below %.1f%%"
			% [float(hull["fraction"]) * 100.0, hull_min * 100.0])

	# As a fraction of the map's width. An absolute count cannot be right at two different map
	# sizes, and the spec's 2-6 describes a canyon rather than the open country this generates.
	var choke_frac: float = float(choke) / float(md.size)
	var choke_min: float = cfg.f("metrics.chokepoint_frac_min", 0.05)
	var choke_max: float = cfg.f("metrics.chokepoint_frac_max", 0.22)
	if choke_frac < choke_min or choke_frac > choke_max:
		failures.append("chokepoint width %.1f%% outside %.1f-%.1f%%"
			% [choke_frac * 100.0, choke_min * 100.0, choke_max * 100.0])

	var balance_max: float = cfg.f("metrics.zone_balance_max_pct", 15.0)
	if float(balance["worst_pct"]) > balance_max:
		failures.append("zone imbalance %.1f%% above %.1f%%"
			% [float(balance["worst_pct"]), balance_max])

	var esc_min: float = cfg.f("metrics.escarpment_frac_min", 0.03)
	var esc_max: float = cfg.f("metrics.escarpment_frac_max", 0.15)
	if escarpment < esc_min or escarpment > esc_max:
		failures.append("escarpment edges %.1f%% outside %.1f-%.1f%%"
			% [escarpment * 100.0, esc_min * 100.0, esc_max * 100.0])

	return {
		"pass": failures.is_empty(),
		"failures": failures,
		"seed": master_seed,
		"sightline": sight,
		"hull_down": hull,
		"chokepoints": choke,
		"balance": balance,
		"chokepoint_frac": choke_frac,
		"rivers": rivers,
		"river_crossings": int(rivers["crossings"]),
		"river_spans_map": bool(rivers["spans_map"]),
		"escarpment_frac": escarpment,
		"passable_frac": md.passable_fraction(),
		"relief": variety,
		"mean_abs_dl": float(variety["mean_abs_dl"]),
		"flat_edge_frac": float(variety["flat_edge_frac"]),
		"level_span": int(variety["level_span"]),
		"elapsed_usec": Time.get_ticks_usec() - t0,
	}


# --- relief variety ----------------------------------------------------------------------------

## How folded the ground is, as opposed to how much of it is a wall.
##
## `escarpment_fraction` counts only the edges a tank cannot cross, so a map with no walls and no
## folds scores exactly the same as a map with no walls and plenty of them. The generator was tuned
## to a comfortable 7% escarpment and produced a single flat terrace, and nothing measured that —
## which is the gap this closes. See docs/decisions/0013.
##
## `mean_abs_dl` is the average absolute level difference across a tile edge, in quanta: literally
## "how many terrace steps does a tank cross per tile of travel". `flat_edge_frac` is the share of
## edges with no step at all, which is the flatness complaint stated directly.
##
## Measured over the four canonical slots, so it is the same edge set `escarpment_fraction` uses and
## the two numbers are directly comparable.
static func relief_variety(md: MapData) -> Dictionary:
	var total: int = 0
	var sum_dl: int = 0
	var flat: int = 0
	var lo: int = 0
	var hi: int = 0
	var seen: bool = false

	for i: int in md.n:
		var x: int = i % md.size
		var y: int = i / md.size
		var lv: int = md.level[i]
		if not seen:
			lo = lv
			hi = lv
			seen = true
		else:
			lo = mini(lo, lv)
			hi = maxi(hi, lv)

		for slot: int in 4:
			var d: int = Grid.CANON[slot]
			var nx: int = x + Grid.DX[d]
			var ny: int = y + Grid.DY[d]
			if nx < 0 or nx >= md.size or ny < 0 or ny >= md.size:
				continue
			var dl: int = absi(md.level[ny * md.size + nx] - lv)
			total += 1
			sum_dl += dl
			if dl == 0:
				flat += 1

	var n: float = float(maxi(total, 1))
	return {
		"mean_abs_dl": float(sum_dl) / n,
		"flat_edge_frac": float(flat) / n,
		"level_span": hi - lo,
	}


# --- sightlines --------------------------------------------------------------------------------

## Two numbers, because the spec's version and the useful version are different measurements.
##
## The spec says to sample random tile *pairs* and report the median distance of those with line of
## sight. On a 2 km square the median separation of two random tiles is about 1030 m regardless of
## what the terrain looks like, so that statistic mostly reports the shape of the map — it would
## sit outside the 300-900 m target band on almost any seed, including good ones.
##
## The ray-march version samples a tile and a direction and asks how far the view runs before
## something blocks it. That is what "sightline" means when someone is deciding where to put a
## tank, it responds to erosion and woods density the way you would expect, and it is what the
## target band gates on. Both are reported so the discrepancy stays visible rather than being
## quietly dropped.
static func sightlines(md: MapData, cfg: Config, master_seed: int) -> Dictionary:
	var samples: int = cfg.i("metrics.sightline_samples", 5000)
	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.AI, "metrics.sight")
	var max_tiles: int = cfg.i("visibility.max_range_tiles", 90)

	var passable := PackedInt32Array()
	for i: int in md.n:
		if md.is_passable(i):
			passable.append(i)
	if passable.size() < 2:
		return {"ray_median_m": 0.0, "ray_q1_m": 0.0, "ray_q3_m": 0.0, "pair_median_m": 0.0}

	var ray_lengths := PackedFloat32Array()
	ray_lengths.resize(samples)
	for k: int in samples:
		var t: int = passable[rng.randi_range(0, passable.size() - 1)]
		ray_lengths[k] = Los.clear_range(md, cfg, t, rng.randi_range(0, 7), max_tiles)
	ray_lengths.sort()

	# The spec's metric, computed as written, for comparison.
	var pair_hits := PackedFloat32Array()
	var pair_samples: int = samples / 5
	for k2: int in pair_samples:
		var a: int = passable[rng.randi_range(0, passable.size() - 1)]
		var b: int = passable[rng.randi_range(0, passable.size() - 1)]
		if a == b:
			continue
		if Los.has_los(md, cfg, a, b):
			pair_hits.append(Grid.dist_m(a, b))
	pair_hits.sort()

	return {
		"ray_median_m": _quantile(ray_lengths, 0.5),
		"ray_q1_m": _quantile(ray_lengths, 0.25),
		"ray_q3_m": _quantile(ray_lengths, 0.75),
		"pair_median_m": _quantile(pair_hits, 0.5),
		"pair_los_frac": float(pair_hits.size()) / float(maxi(pair_samples, 1)),
	}


static func _quantile(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(float(sorted.size() - 1) * q), 0, sorted.size() - 1)]


# --- hull down ---------------------------------------------------------------------------------

## What fraction of the map offers a hull-down firing position.
##
## Taken literally — place a virtual observer on every tile in every direction and ray-cast — this
## is six hundred thousand rays and takes minutes. But the definition is local: a hull-down
## position is a tile just behind a crest, where the crest is tall enough to mask the hull and short
## enough to leave the turret clear, with ground falling away beyond it. Walking a dozen tiles out
## in each direction answers that directly.
static func hull_down_fraction(md: MapData, cfg: Config) -> Dictionary:
	var reach: int = cfg.i("metrics.hull_down_crest_reach_tiles", 12)
	var stride: int = maxi(cfg.i("metrics.hull_down_stride", 2), 1)
	var hull_h: float = cfg.f("visibility.hull_h_m", 1.4)
	var turret_h: float = cfg.f("visibility.turret_h_m", 2.6)

	var found: int = 0
	var tested: int = 0
	var flags := PackedByteArray()
	flags.resize(md.n)

	for y: int in range(0, md.size, stride):
		for x: int in range(0, md.size, stride):
			var i: int = y * md.size + x
			if not md.is_passable(i):
				continue
			tested += 1
			var here: float = md.height_m(i)
			var is_hull_down: bool = false

			for d: int in 8:
				var cx: int = x
				var cy: int = y
				var crest: float = -INF
				var crest_step: int = -1

				for s: int in range(1, reach + 1):
					cx += Grid.DX[d]
					cy += Grid.DY[d]
					if cx < 0 or cx >= md.size or cy < 0 or cy >= md.size:
						break
					var h: float = md.height_m(cy * md.size + cx)
					if h > crest:
						crest = h
						crest_step = s

				if crest_step < 0:
					continue
				# The crest must hide the hull and not the turret. Too low and the tank is simply
				# exposed; too high and it cannot shoot over.
				var rise: float = crest - here
				if rise < hull_h or rise >= turret_h:
					continue

				# And the ground beyond the crest must fall away, or there is nothing to shoot at.
				var bx: int = x + Grid.DX[d] * mini(crest_step + 3, reach)
				var by: int = y + Grid.DY[d] * mini(crest_step + 3, reach)
				if bx < 0 or bx >= md.size or by < 0 or by >= md.size:
					continue
				if md.height_m(by * md.size + bx) < crest - 0.25:
					is_hull_down = true
					break

			if is_hull_down:
				found += 1
				flags[i] = 1

	return {
		"fraction": float(found) / float(maxi(tested, 1)),
		"count": found,
		"tested": tested,
		"flags": flags,
	}


# --- rivers ---------------------------------------------------------------------------------------

## Whether the rivers actually divide the map, and how many ways there are across.
##
## A river is required to be **diagonally impermeable** — that is the property, and the two-tile
## width most channels happen to have is only the usual way of achieving it. The property itself is
## enforced by the corner-tile rule in `MapData.can_move` and asserted directly, tile by tile, in
## `tests/test_rivers`. What is measured here is the tactical consequence: does the water separate
## the ground, and if so how many crossings are there.
##
## Separation is measured with the crossings taken away — every ford and bridge forced impassable
## through the same per-query blocker overlay the pathfinder uses for occupancy — and then counting
## components. Note that a river fades upstream into `STREAM`, which becomes drivable marsh, so a
## river commonly runs from mid-map to one edge and divides nothing. `spans_map` says which case
## this seed is, and the crossing count is only meaningful when it holds.
static func river_crossings(md: MapData, graph: TraversalGraph) -> Dictionary:
	var river_tiles: int = 0
	for i: int in md.n:
		if md.water[i] == MapData.Water.RIVER:
			river_tiles += 1

	# Crossings out: the components that remain are the banks.
	var closed := PackedByteArray()
	closed.resize(md.n)
	var crossing_tiles := PackedInt32Array()
	for i2: int in md.n:
		var w: int = int(md.water[i2])
		if w == MapData.Water.FORD or w == MapData.Water.BRIDGE:
			closed[i2] = 1
			crossing_tiles.append(i2)

	var component: PackedInt32Array = _components(md, graph, closed)
	var sizes := {}
	var count: int = 0
	for i3: int in md.n:
		var c: int = component[i3]
		if c < 0:
			continue
		sizes[c] = int(sizes.get(c, 0)) + 1
		count = maxi(count, c + 1)

	# How many crossings actually join two different banks, grouped so a two-tile ford counts once.
	var joins: int = 0
	var seen := PackedByteArray()
	seen.resize(md.n)
	for k: int in crossing_tiles.size():
		var t: int = crossing_tiles[k]
		if seen[t] != 0:
			continue
		var touched := {}
		var stack := PackedInt32Array([t])
		seen[t] = 1
		while not stack.is_empty():
			var c2: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			for d: int in 8:
				var nb: int = md.neighbor(c2, d)
				if nb < 0:
					continue
				if closed[nb] != 0:
					if seen[nb] == 0:
						seen[nb] = 1
						stack.append(nb)
				elif component[nb] >= 0:
					touched[component[nb]] = true
		if touched.size() >= 2:
			joins += 1

	# The biggest two components, as a share of the drivable ground. A river that leaves a
	# three-tile pocket on one side has not divided anything.
	var ordered := PackedInt32Array()
	for key: int in sizes:
		ordered.append(int(sizes[key]))
	ordered.sort()
	ordered.reverse()
	var passable_total: int = 0
	for v: int in ordered:
		passable_total += v
	var second: float = 0.0
	if ordered.size() >= 2 and passable_total > 0:
		second = float(ordered[1]) / float(passable_total)

	return {
		"river_tiles": river_tiles,
		"components": count,
		"second_bank_frac": second,
		"crossings": joins,
		"spans_map": second >= 0.05,
	}


## Connected components of the drivable ground, with `closed` tiles treated as impassable. -1 where
## nothing can stand.
static func _components(
	md: MapData, graph: TraversalGraph, closed: PackedByteArray
) -> PackedInt32Array:
	var component := PackedInt32Array()
	component.resize(md.n)
	component.fill(-1)

	var queue := PackedInt32Array()
	queue.resize(md.n)
	var next_id: int = 0

	for start: int in md.n:
		if component[start] >= 0 or not graph.passable(start) or closed[start] != 0:
			continue
		var head: int = 0
		var tail: int = 0
		queue[tail] = start
		tail += 1
		component[start] = next_id

		while head < tail:
			var c: int = queue[head]
			head += 1
			var base: int = c * 8
			for d: int in 8:
				var nb: int = graph.edge_target[base + d]
				if nb < 0 or closed[nb] != 0 or component[nb] >= 0:
					continue
				component[nb] = next_id
				queue[tail] = nb
				tail += 1
		next_id += 1

	return component


# --- chokepoints -------------------------------------------------------------------------------

static func chokepoints(md: MapData, cfg: Config, graph: TraversalGraph = null) -> int:
	var cap: int = cfg.i("metrics.chokepoint_cap", 8)
	var g: TraversalGraph = graph if graph != null else TraversalGraph.build(md, cfg)
	return VertexMinCut.min_cut(md, md.zone_tiles(1), md.zone_tiles(2), cap, g)


# --- balance -----------------------------------------------------------------------------------

## The two sides should start on comparable ground. Compared on mean elevation and on how much
## hull-down ground each zone's half of the map offers — a side that starts overlooked, or with
## nowhere to fight from, has lost before the first turn.
static func zone_balance(md: MapData, cfg: Config) -> Dictionary:
	var hull: Dictionary = hull_down_fraction(md, cfg)
	var flags: PackedByteArray = hull["flags"]

	var elev := PackedFloat64Array([0.0, 0.0])
	var counts := PackedInt32Array([0, 0])
	var hull_counts := PackedInt32Array([0, 0])

	for i: int in md.n:
		var z: int = int(md.deploy_zone[i])
		if z != 1 and z != 2:
			continue
		elev[z - 1] += md.height_m(i)
		counts[z - 1] += 1
		if flags[i] != 0:
			hull_counts[z - 1] += 1

	# Measured over each zone's own footprint, which is what the spec asks for: "hull-down count and
	# mean elevation per deployment zone". An earlier version compared each side's *half of the
	# map* instead, and that is a different and much noisier question — a hull-down count summed
	# over ten thousand tiles of ground neither side has reached yet swings by tens of percent
	# between seeds without saying anything about how fair the start is.
	var mean_a: float = elev[0] / float(maxi(counts[0], 1))
	var mean_b: float = elev[1] / float(maxi(counts[1], 1))
	var elev_pct: float = _pct_difference(mean_a, mean_b)

	var hull_a: float = float(hull_counts[0]) / float(maxi(counts[0], 1))
	var hull_b: float = float(hull_counts[1]) / float(maxi(counts[1], 1))
	var hull_pct: float = _pct_difference(hull_a, hull_b)

	return {
		"mean_elev_a_m": mean_a,
		"mean_elev_b_m": mean_b,
		"elev_diff_pct": elev_pct,
		"hull_down_a": hull_a,
		"hull_down_b": hull_b,
		"hull_diff_pct": hull_pct,
		"worst_pct": maxf(elev_pct, hull_pct),
	}


## Difference as a percentage of the larger value, so it is symmetric and bounded.
static func _pct_difference(a: float, b: float) -> float:
	var big: float = maxf(absf(a), absf(b))
	if big < 1e-6:
		return 0.0
	return absf(a - b) / big * 100.0
