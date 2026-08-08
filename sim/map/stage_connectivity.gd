class_name ConnectivityRepair
extends RefCounted

## Stage 4.6, second half — deployment zones, objectives, and making sure they can reach each other.
##
## Procedural terrain does not owe anyone a connected map. Erosion can leave a plateau ringed by
## escarpment, and a seed where one deployment zone cannot reach an objective is not a hard map, it
## is a broken one.
##
## The shape here is the same one used for fords: generate, measure, repair, and only reject the
## seed if repair fails. Repair works by asking a relaxed version of the pathfinding question —
## "if you could cut through escarpments, how much cutting would the cheapest route need?" — and
## then doing exactly that cutting along the answer. The result is a pass through the high ground
## in the place the terrain already came closest to offering one, rather than a trench in an
## arbitrary straight line.

const TAG := "zones"


## Choose deployment zones on opposing map edges, on the flattest ground each edge offers.
static func place_zones(md: MapData, cfg: Config, master_seed: int) -> void:
	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.TERRAIN, TAG)

	# Zone dimensions are fractions of the map, so a smaller map gets a proportionally smaller zone
	# rather than one that swallows a third of the board.
	var size: int = md.size
	var width: int = maxi(int(cfg.f("zones.width_frac", 0.2) * float(size)), 2)
	var depth: int = maxi(int(cfg.f("zones.depth_frac", 0.1) * float(size)), 2)
	var margin: int = maxi(int(cfg.f("zones.edge_margin_frac", 0.02) * float(size)), 1)

	# Zones face each other across the map. Which axis is a coin flip from the terrain substream, so
	# a map is not always fought north to south.
	var vertical: bool = rng.randf() < 0.5

	var span: int = size - 2 * margin - width
	if span < 1:
		span = 1

	# Pick the two zones *together*, not one per edge independently.
	#
	# Choosing the flattest window on each edge separately optimises each side and balances neither,
	# and the two ended up on ground differing by up to seventy per cent in mean elevation and
	# hull-down cover. Scoring candidate pairs makes the balance metric a check on a guarantee
	# rather than a lottery.
	var shortlist: int = maxi(cfg.i("metrics.zone_balance_candidates", 12), 1)
	var balance_weight: float = cfg.f("metrics.zone_balance_weight", 40.0)

	var cand_a: Array = _shortlist(md, margin, span, width, depth, margin, true, vertical, shortlist)
	var cand_b: Array = _shortlist(md, margin, span, width, depth, margin, false, vertical, shortlist)
	if cand_a.is_empty() or cand_b.is_empty():
		return

	var best_a: Dictionary = cand_a[0]
	var best_b: Dictionary = cand_b[0]
	var best_total: float = INF
	for a: Dictionary in cand_a:
		for b: Dictionary in cand_b:
			# Rough ground is bad; ground that does not match the other side is worse.
			var mismatch: float = absf(float(a["mean_level"]) - float(b["mean_level"]))
			var total: float = float(a["score"]) + float(b["score"]) + mismatch * balance_weight
			if total < best_total:
				best_total = total
				best_a = a
				best_b = b

	_stamp_zone(md, int(best_a["offset"]), width, depth, margin, true, vertical, 1)
	_stamp_zone(md, int(best_b["offset"]), width, depth, margin, false, vertical, 2)


## The best few window positions along one edge, each with its roughness score and mean elevation.
static func _shortlist(
	md: MapData, first: int, span: int, width: int, depth: int, margin: int,
	near_edge: bool, vertical: bool, keep: int
) -> Array:
	var all: Array = []
	for offset: int in range(first, first + span):
		all.append({
			"offset": offset,
			"score": _window_score(md, offset, width, depth, margin, near_edge, vertical),
			"mean_level": _window_mean_level(md, offset, width, depth, margin, near_edge, vertical),
		})
	all.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return float(x["score"]) < float(y["score"])
	)
	return all.slice(0, mini(keep, all.size()))


static func _window_mean_level(
	md: MapData, offset: int, width: int, depth: int, margin: int,
	near_edge: bool, vertical: bool
) -> float:
	var size: int = md.size
	var total: float = 0.0
	var count: int = 0
	for a: int in range(offset, offset + width):
		for b: int in range(margin, margin + depth):
			var across: int = b if near_edge else size - 1 - b
			var i: int = (across * size + a) if vertical else (a * size + across)
			total += float(md.level[i])
			count += 1
	return total / float(maxi(count, 1))


## Lower is better: flat, dry, passable ground.
static func _window_score(
	md: MapData, offset: int, width: int, depth: int, margin: int,
	near_edge: bool, vertical: bool
) -> float:
	var size: int = md.size
	var rough: float = 0.0
	var penalty: float = 0.0
	var count: int = 0

	for a: int in range(offset, offset + width):
		for b: int in range(margin, margin + depth):
			var across: int = b if near_edge else size - 1 - b
			var i: int = (across * size + a) if vertical else (a * size + across)
			count += 1
			if md.water[i] != MapData.Water.NONE and md.water[i] != MapData.Water.FORD:
				penalty += 6.0
			for d: int in 4:
				if md.transition(i, Grid.CANON[d]) >= MapData.Trans.BLOCKED:
					penalty += 2.0
			# Roughness as the spread of levels against the window's own neighbours.
			var nb: int = md.neighbour(i, Grid.E)
			if nb >= 0:
				rough += float(absi(md.level[nb] - md.level[i]))

	if count == 0:
		return INF
	return (rough + penalty) / float(count)


static func _stamp_zone(
	md: MapData, offset: int, width: int, depth: int, margin: int,
	near_edge: bool, vertical: bool, zone: int
) -> void:
	var size: int = md.size
	for a: int in range(offset, offset + width):
		for b: int in range(margin, margin + depth):
			var across: int = b if near_edge else size - 1 - b
			var i: int = (across * size + a) if vertical else (a * size + across)
			md.deploy_zone[i] = zone


## Objectives are placed on high, passable ground away from the deployment zones and from each
## other. They have no mechanics in iteration 1 — they exist so connectivity has something to be
## measured against, and so 4.11's balance metric has anchors.
static func place_objectives(md: MapData, cfg: Config, master_seed: int) -> void:
	var count: int = cfg.i("zones.objective_count", 3)
	# Separation is a fraction of the map, not an absolute tile count. Forty tiles is a fifth of a
	# 200-tile map and four fifths of the quarter-scale one used by the tests, where it becomes
	# unsatisfiable — and the fallback then dropped the constraint entirely and stacked all three
	# objectives on adjacent tiles in the middle of the map.
	var min_sep: float = cfg.f("zones.objective_min_separation_frac", 0.2) * float(md.size)
	var size: int = md.size
	# Keep objectives clear of the map border by a little more than the zones are.
	var margin: int = maxi(int(cfg.f("zones.edge_margin_frac", 0.02) * float(size)), 1) + size / 20

	# Score by elevation, favouring high ground, packed for a single integer sort. Descending, so
	# negate.
	var scored := PackedInt64Array()
	for i: int in md.n:
		var x: int = i % size
		var y: int = i / size
		if x < margin or y < margin or x >= size - margin or y >= size - margin:
			continue
		if md.deploy_zone[i] != 0 or not md.is_passable(i):
			continue
		if md.water[i] != MapData.Water.NONE and md.water[i] != MapData.Water.FORD:
			continue
		var key: int = 100000 - clampi(md.level[i], 0, 99999)
		scored.append((key << 21) | i)
	scored.sort()

	# Take the highest ground that satisfies the separation. If the map cannot offer that much
	# spread, relax the requirement and try again rather than abandoning it — halving the distance
	# still gives three objectives spread across the map, whereas dropping the constraint gives
	# three objectives on adjacent tiles, which is one objective wearing a hat.
	var chosen := PackedInt32Array()
	var sep: float = min_sep
	while sep >= 1.0:
		chosen = _pick_spread(scored, size, count, sep)
		if chosen.size() >= count:
			break
		sep *= 0.5

	md.objectives = chosen


static func _pick_spread(
	scored: PackedInt64Array, size: int, count: int, min_sep: float
) -> PackedInt32Array:
	var chosen := PackedInt32Array()
	var min_sep2: float = min_sep * min_sep
	for k: int in scored.size():
		if chosen.size() >= count:
			break
		var i: int = int(scored[k] & 0x1FFFFF)
		var ok: bool = true
		for c: int in chosen.size():
			var dx: float = float(i % size - chosen[c] % size)
			var dy: float = float(i / size - chosen[c] / size)
			if dx * dx + dy * dy < min_sep2:
				ok = false
				break
		if ok:
			chosen.append(i)
	return chosen


## Flood fill over legal moves. Returns a byte per tile, 1 where reachable.
static func reachable_from(md: MapData, start_tiles: PackedInt32Array) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(md.n)

	var queue := PackedInt32Array()
	queue.resize(md.n)
	var head: int = 0
	var tail: int = 0

	for k: int in start_tiles.size():
		var s: int = start_tiles[k]
		if md.is_passable(s) and seen[s] == 0:
			seen[s] = 1
			queue[tail] = s
			tail += 1

	while head < tail:
		var c: int = queue[head]
		head += 1
		for d: int in 8:
			if not md.can_move(c, d):
				continue
			var nb: int = md.neighbour(c, d)
			if seen[nb] != 0:
				continue
			seen[nb] = 1
			queue[tail] = nb
			tail += 1

	return seen


## Bring the map up to "every deployment zone reaches every objective", or report that it could not
## be done.
##
## A zone is checked as a whole rather than through a representative tile. A zone is forty tiles by
## twenty of real terrain with rivers and escarpments running through it, so it is routinely split
## across several components — picking one tile from the middle and calling it the zone reported
## success on maps where two thirds of the zone could not reach anything, which is precisely the
## failure this stage exists to prevent.
##
## Whatever the repair cannot join, it disowns: zone tiles left stranded outside the main component
## stop being deployment tiles. Deploying onto ground you cannot drive off is worse than having a
## slightly smaller zone.
static func repair(md: MapData, cfg: Config) -> Dictionary:
	var max_passes: int = cfg.i("traversal.repair_max_passes", 8)
	if md.zone_tiles(1).is_empty() or md.zone_tiles(2).is_empty():
		return {"connected": false, "passes": 0, "edits": 0, "reason": "a deployment zone is empty"}

	var edits: int = 0
	var passes: int = 0

	while passes < max_passes:
		var gap: Array = _first_gap(md)
		if gap.is_empty():
			_prune_stranded_zone_tiles(md)
			return {"connected": true, "passes": passes, "edits": edits, "reason": ""}

		passes += 1
		# Cut from everything the zone can already reach, not from the zone tiles themselves. The
		# cheapest crossing is usually far from the zone, at whatever saddle the terrain offers.
		var carved: int = _carve_route(md, cfg, gap[0], gap[1])
		if carved == 0:
			return {
				"connected": false, "passes": passes, "edits": edits,
				"reason": "no cuttable route to tile %d" % int(gap[1]),
			}
		edits += carved

	if _first_gap(md).is_empty():
		_prune_stranded_zone_tiles(md)
		return {"connected": true, "passes": passes, "edits": edits, "reason": ""}
	return {
		"connected": false, "passes": passes, "edits": edits,
		"reason": "hit the %d-pass repair cap" % max_passes,
	}


## First unmet requirement, as [sources_reachable_from_the_zone, unreached_target], or [] if the
## map already satisfies everything.
static func _first_gap(md: MapData) -> Array:
	for zone: int in [1, 2]:
		var tiles: PackedInt32Array = md.zone_tiles(zone)
		var seen: PackedByteArray = reachable_from(md, tiles)

		var region := PackedInt32Array()
		for i: int in md.n:
			if seen[i] != 0:
				region.append(i)
		if region.is_empty():
			# Every tile in the zone is impassable. Nothing to cut from, so nothing to do.
			continue

		for k: int in md.objectives.size():
			if seen[md.objectives[k]] == 0:
				return [region, md.objectives[k]]

		# The zones must also reach each other, or one side has nothing to attack into.
		var other: PackedInt32Array = md.zone_tiles(3 - zone)
		var target: int = -1
		var any: bool = false
		for k2: int in other.size():
			if not md.is_passable(other[k2]):
				continue
			if seen[other[k2]] != 0:
				any = true
				break
			if target == -1:
				target = other[k2]
		if not any and target != -1:
			return [region, target]

	return []


## Drop zone tiles that cannot reach the objectives, so a deployment zone only ever offers ground a
## tank can actually leave.
static func _prune_stranded_zone_tiles(md: MapData) -> void:
	if md.objectives.is_empty():
		return
	var main: PackedByteArray = reachable_from(md, md.objectives)
	for i: int in md.n:
		if md.deploy_zone[i] != 0 and main[i] == 0:
			md.deploy_zone[i] = 0


## Dijkstra over a relaxed graph, then cut what the winning route needs.
##
## A passable edge costs nothing. A blocked edge costs the number of quanta it would have to come
## down, times a penalty — so the search naturally prefers going the long way round over cutting,
## and prefers cutting a small step over a big one when it must cut. The path it returns is the
## least earthwork the map allows.
static func _carve_route(
	md: MapData, cfg: Config, sources: PackedInt32Array, target: int
) -> int:
	var rough_max: int = cfg.i("traversal.rough_max_dl", 4)
	var penalty: int = cfg.i("traversal.earthwork_penalty", 40)

	var dist := PackedInt32Array()
	dist.resize(md.n)
	dist.fill(-1)
	var came := PackedInt32Array()
	came.resize(md.n)
	came.fill(-1)

	var heap := IntHeap.new()
	for k: int in sources.size():
		var s: int = sources[k]
		if md.is_passable(s) and dist[s] != 0:
			dist[s] = 0
			heap.push(0, s)

	while not heap.is_empty():
		var packed: int = heap.pop()
		var cost: int = IntHeap.key_of(packed)
		var c: int = IntHeap.value_of(packed)
		if cost > dist[c]:
			continue
		if c == target:
			break

		for d: int in 8:
			var nb: int = md.neighbour(c, d)
			if nb < 0 or not md.is_passable(nb):
				continue

			var step: int = 0
			if not md.can_move(c, d):
				var dl: int = absi(md.level[nb] - md.level[c])
				if dl <= rough_max:
					# Blocked for a reason cutting cannot fix — a diagonal whose corners are
					# sealed, or impassable terrain. Leave it alone.
					continue
				step = (dl - rough_max) * penalty

			var nd: int = cost + step
			if dist[nb] == -1 or nd < dist[nb]:
				dist[nb] = nd
				came[nb] = c
				heap.push(nd, nb)

	if dist[target] == -1:
		return 0

	# Collect the route, then level it walking *forward* from the source.
	#
	# Direction matters. Levelling backwards from the target means each tile is adjusted against a
	# neighbour that has not been finalized yet — and when that neighbour is adjusted on the next
	# step, the edge just fixed goes back out of tolerance. The result is a route that is cut in
	# eight places and passable in none of them, which is how this first presented: sixty-five
	# edges cut across eight passes and the map still disconnected.
	#
	# Going forward, every tile is levelled against a predecessor that is already final, so an edge
	# is fixed once and stays fixed.
	var route := PackedInt32Array()
	var cur: int = target
	while cur != -1:
		route.append(cur)
		cur = came[cur]
	route.reverse()

	var edits: int = 0
	for k2: int in range(1, route.size()):
		var prev: int = route[k2 - 1]
		var here: int = route[k2]
		var dl2: int = md.level[here] - md.level[prev]
		if absi(dl2) <= rough_max:
			continue

		# Never move a road. Its height profile was smoothed to a gradient a vehicle can climb, and
		# putting a cutting through it undoes that — which is how a road that measured 1.0 m per
		# tile ended up with a 2.0 m step after repair ran. Adjust the ground beside it instead.
		if md.has_road(here):
			if md.has_road(prev):
				continue
			md.level[prev] = md.level[here] - (rough_max if dl2 > 0 else -rough_max)
			Quantizer.reclassify_around(md, prev, cfg)
		else:
			# Cut a rise down, fill a drop up — either way the step lands exactly on the rough
			# limit, which is passable but visibly hard going.
			md.level[here] = md.level[prev] + (rough_max if dl2 > 0 else -rough_max)
			Quantizer.reclassify_around(md, here, cfg)
			Quantizer.reclassify_around(md, prev, cfg)
		edits += 1

	return edits
