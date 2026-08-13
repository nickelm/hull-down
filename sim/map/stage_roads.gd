class_name RoadBuilder
extends RefCounted

## Stage 4.8 — roads, bridges, and the earthworks that make them work.
##
## A road is an A* route across the map over a cost that hates slope and hates water, followed by
## **cut and fill**: the height profile along the route is relaxed until no step along it exceeds
## the road's maximum gradient, and that profile is blended back into the terrain.
##
## That last part is the whole point. The road is not painted onto the terrain — it *changes* the
## terrain, so it becomes the low-gradient route through country that has none. Where it crosses a
## ridge that would otherwise be an escarpment, the cutting it makes is the only way through, and
## nobody had to special-case "put a pass here". The tactical consequence follows for free: roads
## are where armor can move fast, and therefore where it can be ambushed.
##
## Representation is one segment per tile, an entry edge and an exit edge. Adjacent segments share
## their edge midpoints exactly, so the quadratic curve drawn through them is continuous by
## construction — see the mesh builder.

const TAG := "roads"


class Road extends RefCounted:
	var tiles: PackedInt32Array = PackedInt32Array()
	var is_bridge: PackedByteArray = PackedByteArray()

	func length() -> int:
		return tiles.size()


## Build the road network: a spanning tree over the villages and the map-edge portals, plus a
## redundant edge or two so the network has a loop in it rather than being a pure hierarchy.
##
## Two independent edge-to-edge paths was the old shape, and it produced two roads that crossed by
## luck. A tree over real destinations gives a network that goes somewhere — every village is on it,
## every edge of the map is reachable along it, and the junctions fall out where routes converge
## rather than being the thing villages were placed at. See docs/decisions/0019.
static func build(md: MapData, cfg: Config, master_seed: int, sites: PackedInt32Array) -> Array:
	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.TERRAIN, TAG)

	var nodes: PackedInt32Array = _pick_portals(md, cfg, rng)
	nodes.append_array(sites)
	# Sorted, so the node numbering the tree is built over does not depend on the order portals and
	# sites happened to be appended in.
	nodes.sort()
	if nodes.size() < 2:
		return []

	var edges: Array = _tree_edges(md, cfg, nodes)
	var roads: Array = []

	# Stamped in ascending cost order, and **re-routed** as each one is laid rather than reusing the
	# path that decided the tree's shape. The reuse discount only exists once there is a road to
	# reuse, so the cheap edges go down first and the later ones converge onto them. Routing once
	# and using the answer twice would give a tree of correct shape made of roads that ignore each
	# other.
	for k: int in edges.size():
		var pair: Vector3i = edges[k]
		# z marks a bypass: routed at full price so it cuts its own line instead of retracing the
		# tree it is supposed to short-circuit.
		var path: PackedInt32Array = route(md, cfg, pair.x, pair.y, 1.0 if pair.z == 1 else -1.0)
		if path.size() < 2:
			continue

		var road := Road.new()
		road.tiles = path
		# Bridges are marked *before* the earthworks, not after. A deck has to sit at whatever
		# height the smoothed road profile arrives at — setting it afterwards to the height of its
		# neighbors puts a step in the middle of the road, which is how this first shipped a road
		# with a 3 m pitch against a 1 m limit.
		road.is_bridge = _mark_bridges(md, path)
		cut_and_fill(md, cfg, path)
		_stamp(md, road)
		roads.append(road)

	# Roads set the going and clear the cover through the attribute pass rather than by writing
	# move_cost themselves, so it has to run here — settlements re-runs it later, but only when
	# there are villages to place.
	if not roads.is_empty():
		TerrainTyper.apply_terrain_attributes(md, cfg)

	return roads


## The minimum spanning tree over the node set, plus the configured number of redundant edges.
##
## Kruskal over a flat union-find. The candidate edges are packed into a `PackedInt64Array` and
## sorted as integers rather than held in a Dictionary keyed by node pair: a Dictionary would put
## the iteration order of the whole road network at the mercy of hash ordering, which is precisely
## the determinism rule in CLAUDE.md and the one place in this batch where it could have been broken
## without anything failing.
static func _tree_edges(md: MapData, cfg: Config, nodes: PackedInt32Array) -> Array:
	var extra: int = cfg.i("roads.redundant_edges", 1)
	var n: int = nodes.size()

	# All pairs, costed on the clean map. This decides the tree's *shape* only.
	var candidates := PackedInt64Array()
	for a: int in n:
		for b: int in range(a + 1, n):
			var path: PackedInt32Array = route(md, cfg, nodes[a], nodes[b])
			if path.size() < 2:
				continue
			# Route length stands in for cost. Both are monotone in the same thing and the length is
			# already to hand, which keeps this one search per pair rather than two.
			var key: int = clampi(path.size(), 0, 0xFFFFF)
			candidates.append((key << 24) | (a << 12) | b)
	candidates.sort()

	var parent := PackedInt32Array()
	parent.resize(n)
	for k: int in n:
		parent[k] = k

	var tree: Array = []
	var rejected := PackedInt64Array()
	# Tree adjacency as a flat n*n matrix of hop counts, filled in as edges are accepted.
	var adj := PackedByteArray()
	adj.resize(n * n)

	for k2: int in candidates.size():
		var packed: int = candidates[k2]
		var a2: int = (packed >> 12) & 0xFFF
		var b2: int = packed & 0xFFF
		if _find(parent, a2) == _find(parent, b2):
			rejected.append(packed)
			continue
		parent[_find(parent, a2)] = _find(parent, b2)
		adj[a2 * n + b2] = 1
		adj[b2 * n + a2] = 1
		tree.append(Vector3i(nodes[a2], nodes[b2], 0))

	# The redundant edges are the pairs furthest apart **along the tree**, not the cheapest pairs
	# left over.
	#
	# Cheapest was the obvious choice and it is useless: the cheapest non-tree pair is almost always
	# one already adjacent on the tree, so its route runs straight down the road that is already
	# there — the reuse discount guarantees it — and the network gains a duplicate rather than a
	# loop. Joining two places that are a long way round from each other is what a bypass is, and it
	# is the only kind of extra edge that produces an alternative worth having.
	var hops: PackedInt32Array = _tree_hops(adj, n)
	var ranked := PackedInt64Array()
	for k3: int in rejected.size():
		var p2: int = rejected[k3]
		var a3: int = (p2 >> 12) & 0xFFF
		var b3: int = p2 & 0xFFF
		var detour: int = hops[a3 * n + b3]
		if detour < 2:
			continue
		# Descending by detour, then ascending by route length, in one integer sort.
		ranked.append(((1000 - detour) << 44) | ((p2 >> 24) << 24) | (a3 << 12) | b3)
	ranked.sort()

	for k4: int in mini(extra, ranked.size()):
		var p3: int = ranked[k4]
		tree.append(Vector3i(nodes[(p3 >> 12) & 0xFFF], nodes[p3 & 0xFFF], 1))

	return tree


## All-pairs hop distance over the tree, by breadth-first search from each node. At most a dozen
## nodes, so the quadratic shape costs nothing.
static func _tree_hops(adj: PackedByteArray, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n * n)
	out.fill(0)

	var queue := PackedInt32Array()
	queue.resize(n)
	for s: int in n:
		var dist := PackedInt32Array()
		dist.resize(n)
		dist.fill(-1)
		dist[s] = 0
		var head: int = 0
		var tail: int = 0
		queue[tail] = s
		tail += 1
		while head < tail:
			var c: int = queue[head]
			head += 1
			for v: int in n:
				if adj[c * n + v] == 0 or dist[v] >= 0:
					continue
				dist[v] = dist[c] + 1
				queue[tail] = v
				tail += 1
		for v2: int in n:
			out[s * n + v2] = maxi(dist[v2], 0)

	return out


static func _find(parent: PackedInt32Array, x: int) -> int:
	var r: int = x
	while parent[r] != r:
		r = parent[r]
	return r


## Where the network leaves the map: one portal per edge, on the lowest drivable ground that edge
## offers. Roads leave a map from its valleys, as they always did — but deterministically scanned
## rather than sampled, because a portal that moves between runs moves the whole network.
static func _pick_portals(md: MapData, cfg: Config, rng: RandomNumberGenerator) -> PackedInt32Array:
	var want: int = clampi(cfg.i("roads.portal_count", 4), 1, 4)
	var size: int = md.size
	var margin: int = maxi(size / 10, 2)
	var out := PackedInt32Array()

	for side: int in want:
		var best: int = -1
		var best_score: int = 1 << 30
		for k: int in range(margin, size - margin):
			var tile: int = -1
			match side:
				0: tile = md.idx(k, 0)
				1: tile = md.idx(size - 1, k)
				2: tile = md.idx(k, size - 1)
				_: tile = md.idx(0, k)
			if not md.is_passable(tile):
				continue
			# The nudge keeps two equally low points on one edge from always resolving the same way.
			var score: int = md.level[tile] * 4 + rng.randi_range(0, 3)
			if score < best_score:
				best_score = score
				best = tile
		if best >= 0:
			out.append(best)

	return out


## Restore every road's gradient after later stages have moved the ground under it.
##
## Villages flatten their footprint to a median height, and a road runs straight through the middle
## of a village. Re-running the earthworks is cheaper and more honest than trying to make every
## later stage road-aware.
## Repeat until every road is inside its gradient limit.
##
## A single road always converges — the relaxation is a clamping smoother and the profile is then
## written down exactly. Crossings are what need iterating: a shared tile belongs to both roads and
## whichever is smoothed second wins, so the first has to be given the chance to answer back. A
## fixed two passes happened to settle the full-size maps and left a 2 m step on a smaller one.
static func resmooth(md: MapData, cfg: Config, roads: Array) -> int:
	var limit: int = cfg.i("roads.max_road_dl", 2)
	var max_passes: int = cfg.i("roads.resmooth_max_passes", 8)

	for p: int in max_passes:
		for k: int in roads.size():
			var road: RoadBuilder.Road = roads[k]
			cut_and_fill(md, cfg, road.tiles)

		var worst: int = 0
		for k2: int in roads.size():
			worst = maxi(worst, max_gradient_dl(md, roads[k2]))
		if worst <= limit:
			return p + 1

	return max_passes


## Route a road, four-connected, over a cost that prices slope steeply and water almost
## prohibitively — except at fords, which is what makes a road seek out a crossing.
## `reuse_override` replaces `roads.reuse_discount` for this one route. A redundant edge passes 1.0,
## meaning no discount at all: the discount exists to make tree edges converge onto shared trunks,
## and for a bypass it is actively wrong. At 0.25 a road along existing tarmac costs a quarter of
## open ground, so retracing the tree beats any direct line unless the detour is more than fourfold
## — which on a spanning tree it essentially never is. The "redundant" edge then lays itself down on
## top of the road that is already there and the network gains nothing. A bypass is built precisely
## because the existing way round is long; it has to be allowed to cut its own line.
static func route(
	md: MapData, cfg: Config, from_tile: int, to_tile: int, reuse_override: float = -1.0
) -> PackedInt32Array:
	var base: float = cfg.f("roads.base_cost", 100.0)
	var slope_k: float = cfg.f("roads.slope_k", 55.0)
	var water_penalty: float = cfg.f("roads.water_penalty", 4000.0)
	var ford_discount: float = cfg.f("roads.ford_discount", 0.06)
	var terrain_k: float = cfg.f("roads.terrain_k", 30.0)

	var reuse: float = clampf(
		reuse_override if reuse_override > 0.0 else cfg.f("roads.reuse_discount", 0.25), 0.01, 1.0
	)

	var cost := func(_from: int, to: int, _d: int) -> int:
		var dl: float = float(absi(md.level[to] - md.level[_from]))
		# Quadratic in the height difference: a road will happily take a long shallow detour rather
		# than one steep pitch, which is what roads do.
		var c: float = base + slope_k * dl * dl

		match int(md.water[to]):
			MapData.Water.RIVER:
				c += water_penalty
			MapData.Water.STREAM:
				c += water_penalty * 0.12
			MapData.Water.FORD:
				c += water_penalty * ford_discount

		# Mildly prefer open ground over woods and marsh.
		var mc: int = md.move_cost[to]
		if mc > 0:
			c += terrain_k * (float(mc) * 0.1 - 1.0)

		# Running along a road that is already there is much cheaper than making a new one, which is
		# what turns a spanning tree into a network with trunks instead of a star of separate lanes.
		#
		# Note this discount did *not* exist before — it looked as though it did, because road tiles
		# were baked cheap in `move_cost`, but `apply_terrain_attributes` runs once after the whole
		# build loop, so no road ever saw another road's discount.
		if md.has_road(to):
			c *= reuse

		# Floored at 1. IntHeap packs the key by shifting it left twenty bits, so a zero or negative
		# edge cost corrupts the packing rather than merely being wrong.
		return maxi(int(c), 1)

	# The scale must be a true lower bound on any edge, and the reuse discount makes the cheapest
	# possible edge `base * reuse` rather than `base`. Passing `base` here was correct until the
	# discount existed and would silently overestimate afterwards, which returns routes that look
	# optimal and are not.
	return GridAStar.route_4(md, from_tile, to_tile, cost, base * reuse)


## Relax the height profile along the route until no step exceeds the road's gradient limit, then
## blend the result back into the terrain over a corridor.
##
## The relaxation is a one-dimensional clamping smoother: wherever two consecutive tiles are too far
## apart in height, both are pulled toward their mean by half the excess. It converges in tens of
## passes over a few hundred elements — microseconds — and unlike a global fit it only moves the
## ground where the road actually needs it moved.
static func cut_and_fill(md: MapData, cfg: Config, path: PackedInt32Array) -> void:
	var max_dl: int = cfg.i("roads.max_road_dl", 2)
	var passes: int = cfg.i("roads.cut_fill_passes", 400)
	var radius: int = cfg.i("roads.corridor_radius", 2)

	var n: int = path.size()
	if n < 2:
		return

	var profile := PackedFloat32Array()
	profile.resize(n)
	for k: int in n:
		profile[k] = float(md.level[path[k]])

	var limit: float = float(max_dl)
	for _p: int in passes:
		var moved: bool = false
		for k2: int in range(n - 1):
			var d: float = profile[k2 + 1] - profile[k2]
			var excess: float = absf(d) - limit
			if excess <= 0.001:
				continue
			var shift: float = excess * 0.5 * signf(d)
			profile[k2] += shift
			profile[k2 + 1] -= shift
			moved = true
		if not moved:
			break

	# Blend into the terrain. Full effect on the road tile itself, fading out across the corridor
	# so the cutting has banks rather than vertical walls.
	var size: int = md.size
	var touched := PackedInt32Array()

	# Consecutive path tiles are neighbors, so each one's corridor covers the one before it.
	# Blending the banks without excluding the road itself means every tile is overwritten by its
	# successor's blend and the smoothed profile is never actually laid down — the road came out
	# with 1.5 m steps against a 1.0 m limit. Mark the path, blend only the banks, then write the
	# profile exactly.
	var on_path := PackedByteArray()
	on_path.resize(md.n)
	for k3: int in n:
		on_path[path[k3]] = 1

	for k4: int in n:
		var c: int = path[k4]
		var target: int = int(round(profile[k4]))
		var cx: int = c % size
		var cy: int = c / size

		for oy: int in range(maxi(cy - radius, 0), mini(cy + radius + 1, size)):
			for ox: int in range(maxi(cx - radius, 0), mini(cx + radius + 1, size)):
				var j: int = oy * size + ox
				# Leave this road's own route alone, and any road already built — a second road
				# running alongside the first would otherwise blend its banks straight over the
				# first road's profile and put a step back into it.
				if on_path[j] != 0 or md.has_road(j):
					continue
				var dx: float = float(ox - cx)
				var dy: float = float(oy - cy)
				var dist: float = sqrt(dx * dx + dy * dy)
				if dist > float(radius):
					continue
				# Never fill a watercourse the road merely passes beside. A cutting whose banks
				# spill into the river dams it, and the drainage network stops draining.
				var w: int = int(md.water[j])
				if w == MapData.Water.RIVER or w == MapData.Water.STREAM:
					continue
				var t: float = 1.0 - dist / float(radius + 1)
				md.level[j] = int(round(lerpf(float(md.level[j]), float(target), t)))
				touched.append(j)

	for k5: int in n:
		md.level[path[k5]] = int(round(profile[k5]))
		touched.append(path[k5])

	# Integer clamp, walking forward from the first tile.
	#
	# The relaxation works in floats and stops when consecutive values are within the limit plus a
	# convergence slack; rounding either side of a boundary can then turn a legal 2.001 into an
	# illegal 3. Doing the final enforcement in the same integers the rule is expressed in makes
	# the guarantee exact instead of nearly exact. Forward, so each tile is fixed against a
	# predecessor that is already final.
	var limit_i: int = max_dl
	for k7: int in range(1, n):
		var d2: int = md.level[path[k7]] - md.level[path[k7 - 1]]
		if absi(d2) > limit_i:
			md.level[path[k7]] = md.level[path[k7 - 1]] + (limit_i if d2 > 0 else -limit_i)

	for k6: int in touched.size():
		Quantizer.reclassify_around(md, touched[k6], cfg)


## A road tile sitting on a river becomes a bridge, which is exactly the thing that makes an
## impassable river crossable. The deck height is left to the earthworks that follow.
static func _mark_bridges(md: MapData, path: PackedInt32Array) -> PackedByteArray:
	var flags := PackedByteArray()
	flags.resize(path.size())
	for k: int in path.size():
		var c: int = path[k]
		if md.water[c] == MapData.Water.RIVER:
			flags[k] = 1
			md.water[c] = MapData.Water.BRIDGE
	return flags


## Write the road onto the map: connectivity, cover, and the passability that follows from a made-up
## surface.
##
## The tile keeps its natural terrain type — a road is a surface on ground, not a kind of ground, so
## the map still knows there is field or woods underneath (docs/decisions/0011). Links are OR-ed in,
## never assigned, so a tile crossed by a second road keeps the first road's connections.
static func _stamp(md: MapData, road: Road) -> void:
	var n: int = road.tiles.size()
	for k: int in n:
		var c: int = road.tiles[k]

		# A bridge keeps its water marker so the renderer draws a deck over a river. A stream is
		# small enough that the road simply covers it.
		if md.water[c] == MapData.Water.STREAM:
			md.water[c] = MapData.Water.NONE

		md.blocker_h[c] = 0.0

		# Link to the previous and next tile along the road. `link_road` sets the bit on both sides
		# of the edge, so a road stamped from either end agrees with itself.
		if k > 0:
			var back: int = Grid.dir_between(
				md.tx(c), md.ty(c), md.tx(road.tiles[k - 1]), md.ty(road.tiles[k - 1])
			)
			if back >= 0:
				md.link_road(c, back)
		if k < n - 1:
			var fwd: int = Grid.dir_between(
				md.tx(c), md.ty(c), md.tx(road.tiles[k + 1]), md.ty(road.tiles[k + 1])
			)
			if fwd >= 0:
				md.link_road(c, fwd)

	# The two ends of the road run off the map, so each points its free edge at the boundary and the
	# drawn ribbon reaches the edge instead of stopping a half tile short. Done after the main pass
	# so a terminus that another road already crossed is measured against its final degree.
	if n > 0:
		_run_off_map(md, road.tiles[0], road.tiles[1] if n > 1 else -1)
		_run_off_map(md, road.tiles[n - 1], road.tiles[n - 2] if n > 1 else -1)


## Give a road terminus an outward link toward the nearest map edge, unless it is already a junction
## (in which case it is not really a terminus and needs no stub).
static func _run_off_map(md: MapData, tile: int, inward_from: int) -> void:
	if md.road_degree(tile) != 1 or inward_from < 0:
		return
	var inward: int = Grid.dir_between(
		md.tx(tile), md.ty(tile), md.tx(inward_from), md.ty(inward_from)
	)
	if inward < 0:
		return

	# Straight on, away from where the road came from — but only when that actually leaves the map.
	# An endpoint that stopped short of the edge would otherwise get a link to a tile with no road
	# on it, which breaks the symmetry invariant the mesh builder relies on and draws a stub into
	# open ground. A terminus in the middle of the map is a dead end, and a dead end is drawable.
	var out: int = Grid.opposite(inward)
	if md.neighbor(tile, out) >= 0:
		return
	md.road_links[tile] = int(md.road_links[tile]) | (1 << out)


## Steepest step anywhere along a road, in quanta. The acceptance check for 4.8.
static func max_gradient_dl(md: MapData, road: Road) -> int:
	var worst: int = 0
	for k: int in range(1, road.tiles.size()):
		worst = maxi(worst, absi(md.level[road.tiles[k]] - md.level[road.tiles[k - 1]]))
	return worst
