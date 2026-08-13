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
	# Choosing the flattest window on each edge separately optimizes each side and balances neither,
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
			# Ground nothing can stand on. Scored separately from water because water is no longer
			# the only source of it — a stand of heavy timber is impassable too, and a zone stamped
			# across one is quietly shrunk later by _prune_stranded_zone_tiles rather than being
			# avoided here, which is a smaller deployment zone nobody asked for.
			elif not md.is_passable(i):
				penalty += 6.0
			for d: int in 4:
				if md.transition(i, Grid.CANON[d]) >= MapData.Trans.BLOCKED:
					penalty += 2.0
			# Roughness as the spread of levels against the window's own neighbors.
			var nb: int = md.neighbor(i, Grid.E)
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


## Objectives sit on the generator's own features — villages, bridges, crests — and carry victory
## points scaled to how contested that ground is (2e-iii). Called late in the pipeline, after roads
## and settlements exist; iteration 1 placed them on bare high ground because high ground was all
## the map had by that stage.
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

	# And clear of the deployment zones themselves. An objective the defense can ring while
	# standing inside the attacker's spotting range at deployment is a degenerate mission on any
	# map — the flag has to be contested ground, not somebody's doorstep. Halved rather than
	# dropped when a cramped map cannot honor it, mirroring the separation fallback below.
	var clearance: int = int(cfg.f("zones.objective_zone_clearance_frac", 0.15) * float(size))
	var pools: Array[PackedInt64Array] = _feature_pools(md, margin, clearance)
	while _pool_total(pools) < count and clearance > 0:
		clearance /= 2
		pools = _feature_pools(md, margin, clearance)
	var worth := PackedInt32Array([
		cfg.i("victory.value_village", 3),
		cfg.i("victory.value_bridge", 2),
		cfg.i("victory.value_crest", 1),
	])

	# Round-robin over the pools — best village, best bridge, best crest, then round again — so a
	# map with all three features fields all three kinds, and a map without villages degrades to
	# bridges and crests rather than to nothing. If the map cannot offer the required spread,
	# relax the separation and try again rather than abandoning it — halving the distance still
	# gives three objectives spread across the map, whereas dropping the constraint gives three
	# objectives on adjacent tiles, which is one objective wearing a hat.
	var chosen := PackedInt32Array()
	var values := PackedInt32Array()
	var sep: float = min_sep
	while sep >= 1.0:
		chosen.clear()
		values.clear()
		_pick_featured(pools, worth, size, count, sep, chosen, values)
		if chosen.size() >= count:
			break
		sep *= 0.5

	md.objectives = chosen
	md.objective_value = values


## Three pools, one per feature, each packed for a single integer sort. Villages prefer their
## road hub (degree, then elevation); bridges prefer the middle of the span; crests are the old
## rule, bare high ground. Descending, so negated. `clearance` is the keep-out band around the
## deployment zones, in tiles.
static func _feature_pools(md: MapData, margin: int, clearance: int) -> Array[PackedInt64Array]:
	var size: int = md.size
	var near_zone: PackedByteArray = _near_zone_mask(md, clearance)
	var villages := PackedInt64Array()
	var bridges := PackedInt64Array()
	var crests := PackedInt64Array()
	for i: int in md.n:
		var x: int = i % size
		var y: int = i / size
		if x < margin or y < margin or x >= size - margin or y >= size - margin:
			continue
		if near_zone[i] != 0 or not md.is_passable(i):
			continue

		if md.terrain[i] == TerrainTyper.Type.VILLAGE:
			var vkey: int = 100 - clampi(md.road_degree(i) * 10 + md.level[i] / 20, 0, 99)
			villages.append((vkey << 21) | i)
			continue
		if md.water[i] == MapData.Water.BRIDGE:
			var span: int = 0
			for d: int in [Grid.N, Grid.E, Grid.S, Grid.W]:
				var nb: int = md.neighbor(i, d)
				if nb >= 0 and md.water[nb] == MapData.Water.BRIDGE:
					span += 1
			bridges.append(((10 - span) << 21) | i)
			continue
		if md.water[i] != MapData.Water.NONE and md.water[i] != MapData.Water.FORD:
			continue
		var key: int = 100000 - clampi(md.level[i], 0, 99999)
		crests.append((key << 21) | i)
	villages.sort()
	bridges.sort()
	crests.sort()
	return [villages, bridges, crests]


static func _pool_total(pools: Array[PackedInt64Array]) -> int:
	var n: int = 0
	for p: PackedInt64Array in pools:
		n += p.size()
	return n


## Tiles within `clearance` steps of any deployment-zone tile, zone tiles included — one
## multi-source BFS over the 8-neighborhood, so the cost is a single pass however wide the band.
static func _near_zone_mask(md: MapData, clearance: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(md.n)
	var dist := PackedInt32Array()
	dist.resize(md.n)
	dist.fill(-1)

	var queue := PackedInt32Array()
	queue.resize(md.n)
	var head: int = 0
	var tail: int = 0
	for i: int in md.n:
		if md.deploy_zone[i] != 0:
			mask[i] = 1
			dist[i] = 0
			queue[tail] = i
			tail += 1

	while head < tail:
		var at: int = queue[head]
		head += 1
		if dist[at] >= clearance:
			continue
		for d: int in 8:
			var nb: int = md.neighbor(at, d)
			if nb < 0 or dist[nb] >= 0:
				continue
			dist[nb] = dist[at] + 1
			mask[nb] = 1
			queue[tail] = nb
			tail += 1
	return mask


## Greedy round-robin pick across the feature pools, best-first within each, spread-enforced
## across all. Fills `out_chosen` and `out_values` in step.
static func _pick_featured(
	pools: Array[PackedInt64Array], worth: PackedInt32Array, size: int, count: int,
	min_sep: float, out_chosen: PackedInt32Array, out_values: PackedInt32Array
) -> void:
	var min_sep2: float = min_sep * min_sep
	var cursors := PackedInt32Array()
	cursors.resize(pools.size())

	var exhausted: int = 0
	while out_chosen.size() < count and exhausted < pools.size():
		exhausted = 0
		for p: int in pools.size():
			if out_chosen.size() >= count:
				break
			var pool: PackedInt64Array = pools[p]
			var took: bool = false
			while cursors[p] < pool.size():
				var i: int = int(pool[cursors[p]] & 0x1FFFFF)
				cursors[p] += 1
				var ok: bool = true
				for c: int in out_chosen.size():
					var dx: float = float(i % size - out_chosen[c] % size)
					var dy: float = float(i / size - out_chosen[c] / size)
					if dx * dx + dy * dy < min_sep2:
						ok = false
						break
				if ok:
					out_chosen.append(i)
					out_values.append(worth[p])
					took = true
					break
			if not took:
				exhausted += 1


## Flood fill over legal moves. Returns a byte per tile, 1 where reachable.
##
## Reads the traversal graph rather than re-deriving each edge through `can_move`, so the fill, the
## repair pass and the chokepoint min-cut all answer from the same table. The graph is a required
## argument rather than something this builds on demand: "which graph did you mean" is exactly the
## question that must not have a silent default answer.
static func reachable_from(
	md: MapData, start_tiles: PackedInt32Array, g: TraversalGraph
) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(md.n)

	var queue := PackedInt32Array()
	queue.resize(md.n)
	var head: int = 0
	var tail: int = 0

	for k: int in start_tiles.size():
		var s: int = start_tiles[k]
		if g.passable(s) and seen[s] == 0:
			seen[s] = 1
			queue[tail] = s
			tail += 1

	var targets: PackedInt32Array = g.edge_target
	while head < tail:
		var c: int = queue[head]
		head += 1
		var base: int = c * 8
		for d: int in 8:
			var nb: int = targets[base + d]
			if nb < 0 or seen[nb] != 0:
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
	# Map-wide, not per pass. A ford is the dearest thing this stage can do and the one most likely
	# to run away with itself, so the budget is spent across the whole repair.
	var fords_left: int = cfg.i("traversal.max_repair_fords", 6)

	# Rebuilt at the top of every pass rather than patched. Each pass moves the ground, fells forest
	# or lays a ford, and an incremental invalidation path through this function is exactly the kind
	# of cleverness the rest of this file is a monument to getting wrong. A fifth of a second
	# against forty seconds of erosion buys the guarantee that the fill and the search agree.
	var graph: TraversalGraph = TraversalGraph.build(md, cfg)

	while passes < max_passes:
		var gap: Array = _first_gap(md, graph)
		if gap.is_empty():
			_prune_stranded_zone_tiles(md, graph)
			return {
				"connected": true, "passes": passes, "edits": edits,
				"fords": cfg.i("traversal.max_repair_fords", 6) - fords_left, "reason": "",
			}

		passes += 1
		# Open from everything the zone can already reach, not from the zone tiles themselves. The
		# cheapest crossing is usually far from the zone, at whatever saddle the terrain offers.
		var opened: Dictionary = _open_route(md, cfg, graph, gap[0], gap[1], fords_left)
		if int(opened["edits"]) == 0:
			return {
				"connected": false, "passes": passes, "edits": edits, "fords": 0,
				"reason": "no way to open a route to tile %d" % int(gap[1]),
			}
		edits += int(opened["edits"])
		fords_left -= int(opened["fords"])
		graph.rebuild()

	if _first_gap(md, graph).is_empty():
		_prune_stranded_zone_tiles(md, graph)
		return {
			"connected": true, "passes": passes, "edits": edits,
			"fords": cfg.i("traversal.max_repair_fords", 6) - fords_left, "reason": "",
		}
	return {
		"connected": false, "passes": passes, "edits": edits, "fords": 0,
		"reason": "hit the %d-pass repair cap" % max_passes,
	}


## First unmet requirement, as [sources_reachable_from_the_zone, unreached_target], or [] if the
## map already satisfies everything.
static func _first_gap(md: MapData, graph: TraversalGraph) -> Array:
	for zone: int in [1, 2]:
		var tiles: PackedInt32Array = md.zone_tiles(zone)
		var seen: PackedByteArray = reachable_from(md, tiles, graph)

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
static func _prune_stranded_zone_tiles(md: MapData, graph: TraversalGraph) -> void:
	if md.objectives.is_empty():
		return
	var main: PackedByteArray = reachable_from(md, md.objectives, graph)
	for i: int in md.n:
		if md.deploy_zone[i] != 0 and main[i] == 0:
			md.deploy_zone[i] = 0


## Dijkstra over a relaxed graph, then perform whatever the winning route needs.
##
## There are three ways to open ground and the search prices all of them at once, so it can trade
## them off rather than being told in advance which to use:
##
##   **cut** an escarpment down — the quanta it must come down, times `earthwork_penalty`
##   **clear** a stand of heavy forest — a flat `clear_penalty` per tile felled
##   **ford** a river — a flat `ford_penalty` per tile, an order dearer again, and capped besides
##
## An edge that is already legal costs nothing, so the search prefers going the long way round to
## any intervention, and the cheapest intervention when it must make one. Earthwork is routine,
## felling a forest is a decision, and putting a crossing where the hydrology did not is a last
## resort — the penalties say so in that order.
##
## `fords_allowed` is what is left of the map-wide ford budget. At zero the ford op is simply not
## offered, and the search routes around the water or reports failure, which is the right answer for
## a map whose halves genuinely are separated by a river nobody bridged.
static func _open_route(
	md: MapData, cfg: Config, graph: TraversalGraph, sources: PackedInt32Array, target: int,
	fords_allowed: int
) -> Dictionary:
	var rough_max: int = cfg.i("traversal.rough_max_dl", 4)
	var penalty: int = cfg.i("traversal.earthwork_penalty", 40)
	var clear_penalty: int = cfg.i("traversal.clear_penalty", 120)
	var ford_penalty: int = cfg.i("traversal.ford_penalty", 600)

	var dist := PackedInt32Array()
	dist.resize(md.n)
	dist.fill(-1)
	var came := PackedInt32Array()
	came.resize(md.n)
	came.fill(-1)

	var heap := IntHeap.new()
	for k: int in sources.size():
		var s: int = sources[k]
		if graph.passable(s) and dist[s] != 0:
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
			var nb: int = md.neighbor(c, d)
			if nb < 0:
				continue

			# Diagonals are only taken where they are *already* legal.
			#
			# Asking `graph.can_move` about the rest would be wrong, because `c` may itself be a
			# tile this route has decided to open — and every edge of an impassable tile reads as
			# illegal, so the search would clear one tile of the barrier and then refuse to walk
			# through the hole it had just made. Orthogonal steps are therefore judged on the edge
			# itself, below, and diagonals are simply left alone: opening one means opening its two
			# corners as well, and there is always an orthogonal way round on a grid.
			if Grid.IS_DIAG[d] == 1 and not graph.can_move(c, d):
				continue

			var step: int = 0
			if not graph.passable(nb):
				if _is_clearable(md, nb):
					step += clear_penalty
				elif fords_allowed > 0 and md.water[nb] == MapData.Water.RIVER:
					step += ford_penalty
				else:
					# Impassable ground that is neither forest to fell nor river to ford: rock a
					# tank cannot climb whatever is done to it.
					continue

			# And the height, independently — a tile can want both felling and cutting.
			var dl: int = absi(md.level[nb] - md.level[c])
			if dl > rough_max:
				step += (dl - rough_max) * penalty

			var nd: int = cost + step
			if dist[nb] == -1 or nd < dist[nb]:
				dist[nb] = nd
				came[nb] = c
				heap.push(nd, nb)

	if dist[target] == -1:
		return {"edits": 0, "fords": 0}

	# Collect the route, then level it walking *forward* from the source.
	#
	# Direction matters. Leveling backwards from the target means each tile is adjusted against a
	# neighbor that has not been finalized yet — and when that neighbor is adjusted on the next
	# step, the edge just fixed goes back out of tolerance. The result is a route that is cut in
	# eight places and passable in none of them, which is how this first presented: sixty-five
	# edges cut across eight passes and the map still disconnected.
	#
	# Going forward, every tile is leveled against a predecessor that is already final, so an edge
	# is fixed once and stays fixed.
	var route := PackedInt32Array()
	var cur: int = target
	while cur != -1:
		route.append(cur)
		cur = came[cur]
	route.reverse()

	var edits: int = 0
	var fords: int = 0
	var terrain_changed: bool = false

	# Terrain first, heights second. Fording a tile *moves* it — a river bed sits meters below its
	# banks, so a ford that only changed the water marker would leave both bank transitions blocked
	# and the crossing would still be impassable. Once the ford has been raised the leveling pass
	# below sees the new height and has less to do, or nothing.
	for k1: int in range(1, route.size()):
		var t: int = route[k1]
		if _is_clearable(md, t):
			# A track felled through the stand, not a clear-fell: it becomes ordinary woods, which
			# is slow going and still blocks line of sight.
			md.terrain[t] = TerrainTyper.Type.WOODS
			terrain_changed = true
			edits += 1
		elif md.water[t] == MapData.Water.RIVER and fords < fords_allowed:
			_make_ford(md, cfg, t, route[k1 - 1], route[k1 + 1] if k1 + 1 < route.size() else -1)
			terrain_changed = true
			fords += 1
			edits += 1

	if terrain_changed:
		TerrainTyper.apply_terrain_attributes(md, cfg)

	# Then level the route, walking *forward* from the source.
	#
	# Direction matters. Leveling backwards from the target means each tile is adjusted against a
	# neighbor that has not been finalized yet — and when that neighbor is adjusted on the next
	# step, the edge just fixed goes back out of tolerance. The result is a route that is cut in
	# eight places and passable in none of them, which is how this first presented: sixty-five
	# edges cut across eight passes and the map still disconnected.
	#
	# Going forward, every tile is leveled against a predecessor that is already final, so an edge
	# is fixed once and stays fixed.
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

	return {"edits": edits, "fords": fords}


## Forest dense enough to stop a tank, and therefore forest a repair is allowed to fell.
##
## Asks the terrain type rather than the cost, deliberately: "impassable for the reference class"
## and "is a stand of heavy timber" are different questions, and only the second one can be answered
## with a chainsaw.
static func _is_clearable(md: MapData, tile: int) -> bool:
	return int(md.terrain[tile]) == TerrainTyper.Type.WOODS_HEAVY


## Turn a river tile into a ford.
##
## Compound, because a ford is not a marker — it is a place where the bed comes up far enough to
## drive across. The tile is raised to sit between its neighbors along the route, so both banks are
## within a normal step, and only then does it become drivable ground.
static func _make_ford(md: MapData, cfg: Config, tile: int, before: int, after: int) -> void:
	var sum: int = md.level[before]
	var count: int = 1
	if after >= 0:
		sum += md.level[after]
		count += 1
	md.level[tile] = sum / count
	md.water[tile] = MapData.Water.FORD
	md.water_level[tile] = md.level[tile]
	md.terrain[tile] = TerrainTyper.Type.FORD
	md.invalidate_max_level()
	# The tile has moved, so its transitions are stale. Everything else that edits `level` in this
	# file reclassifies; forgetting it here would leave a ford that is drivable ground with blocked
	# edges on both sides, which is a crossing to nowhere.
	Quantizer.reclassify_around(md, tile, cfg)
