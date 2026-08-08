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
## are where armour can move fast, and therefore where it can be ambushed.
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


static func build(md: MapData, cfg: Config, master_seed: int) -> Array:
	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.TERRAIN, TAG)
	var count: int = cfg.i("roads.count", 2)
	var roads: Array = []

	var endpoints: Array = _pick_endpoints(md, cfg, rng, count)
	for k: int in endpoints.size():
		var pair: Vector2i = endpoints[k]
		var path: PackedInt32Array = route(md, cfg, pair.x, pair.y)
		if path.size() < 2:
			continue

		var road := Road.new()
		road.tiles = path
		# Bridges are marked *before* the earthworks, not after. A deck has to sit at whatever
		# height the smoothed road profile arrives at — setting it afterwards to the height of its
		# neighbours puts a step in the middle of the road, which is how this first shipped a road
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


## Pick pairs of edge tiles on opposite sides of the map, far enough apart to make a road that
## actually crosses it rather than clipping a corner.
static func _pick_endpoints(
	md: MapData, cfg: Config, rng: RandomNumberGenerator, count: int
) -> Array:
	var size: int = md.size
	var min_sep: float = cfg.f("roads.min_endpoint_separation_frac", 0.3) * float(size)
	var out: Array = []

	for k: int in count:
		# Alternate the axis so two roads tend to cross rather than run parallel — a crossroads is
		# where villages go.
		var vertical: bool = (k % 2) == 0
		var best: Vector2i = Vector2i(-1, -1)
		var best_score: float = INF

		for _attempt: int in 24:
			var a: int
			var b: int
			if vertical:
				a = md.idx(rng.randi_range(2, size - 3), 0)
				b = md.idx(rng.randi_range(2, size - 3), size - 1)
			else:
				a = md.idx(0, rng.randi_range(2, size - 3))
				b = md.idx(size - 1, rng.randi_range(2, size - 3))
			if not md.is_passable(a) or not md.is_passable(b):
				continue
			var dx: float = float(md.tx(a) - md.tx(b))
			var dy: float = float(md.ty(a) - md.ty(b))
			if sqrt(dx * dx + dy * dy) < min_sep:
				continue
			# Prefer starting on low, flat ground — roads leave a map from its valleys.
			var score: float = float(md.level[a] + md.level[b])
			if score < best_score:
				best_score = score
				best = Vector2i(a, b)

		if best.x >= 0:
			out.append(best)

	return out


## Route a road, four-connected, over a cost that prices slope steeply and water almost
## prohibitively — except at fords, which is what makes a road seek out a crossing.
static func route(md: MapData, cfg: Config, from_tile: int, to_tile: int) -> PackedInt32Array:
	var base: float = cfg.f("roads.base_cost", 100.0)
	var slope_k: float = cfg.f("roads.slope_k", 55.0)
	var water_penalty: float = cfg.f("roads.water_penalty", 4000.0)
	var ford_discount: float = cfg.f("roads.ford_discount", 0.06)
	var terrain_k: float = cfg.f("roads.terrain_k", 30.0)

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
		return int(c)

	# Admissible only if the heuristic never exceeds the true cost, and the cheapest possible edge
	# is `base` on flat open ground.
	return GridAStar.route_4(md, from_tile, to_tile, cost, base)


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

	# Consecutive path tiles are neighbours, so each one's corridor covers the one before it.
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
	if md.neighbour(tile, out) >= 0:
		return
	md.road_links[tile] = int(md.road_links[tile]) | (1 << out)


## Steepest step anywhere along a road, in quanta. The acceptance check for 4.8.
static func max_gradient_dl(md: MapData, road: Road) -> int:
	var worst: int = 0
	for k: int in range(1, road.tiles.size()):
		worst = maxi(worst, absi(md.level[road.tiles[k]] - md.level[road.tiles[k - 1]]))
	return worst
