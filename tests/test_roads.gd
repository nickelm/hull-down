extends TestCase

## Stage 4.8. The headless half of the acceptance check: a road crosses the map end to end and its
## gradient stays under the configured maximum. Whether it *renders* as a smooth curve is 4.9's
## problem and needs eyes.

var cfg: Config
var _cached_seed: int = -1
var _cached_map: MapData = null
var _cached_stats: Dictionary = {}


func setup() -> void:
	cfg = Config.load_default()


## Generation is the expensive part of these tests, so each seed is built once and shared.
func _generate(master_seed: int) -> MapData:
	if _cached_seed != master_seed:
		_cached_stats = {}
		_cached_map = MapGenerator.generate(
			cfg, master_seed, MapGenerator.Params.small(cfg), Callable(), _cached_stats
		)
		_cached_seed = master_seed
	return _cached_map


func _roads(master_seed: int) -> Array:
	_generate(master_seed)
	return _cached_stats.get("roads", [])


# --- the acceptance check --------------------------------------------------------------------

func test_a_road_crosses_the_map_end_to_end() -> void:
	var md: MapData = _generate(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return
	var roads: Array = _roads(12345)
	assert_gt(float(roads.size()), 0.0, "no roads were built")

	var crossed: bool = false
	for k: int in roads.size():
		var road: RoadBuilder.Road = roads[k]
		if road.length() < 2:
			continue
		var a: int = road.tiles[0]
		var b: int = road.tiles[road.length() - 1]
		# End to end means touching opposite borders, not merely being long.
		var touches_low: bool = md.tx(a) == 0 or md.ty(a) == 0
		var touches_high: bool = md.tx(b) == md.size - 1 or md.ty(b) == md.size - 1
		if touches_low and touches_high:
			crossed = true
			assert_ge(float(road.length()), float(md.size),
				"a road spanning the map should be at least %d tiles, got %d"
					% [md.size, road.length()])
	assert_true(crossed, "no road runs from one edge of the map to the other")


func test_road_gradient_stays_under_the_limit() -> void:
	var limit: int = cfg.i("roads.max_road_dl", 2)
	for master_seed: int in [12345, 777]:
		var md: MapData = _generate(master_seed)
		assert_not_null(md, "seed %d was rejected" % master_seed)
		if md == null:
			continue
		var roads: Array = _roads(master_seed)
		assert_gt(float(roads.size()), 0.0, "seed %d built no roads" % master_seed)

		for k: int in roads.size():
			var road: RoadBuilder.Road = roads[k]
			var worst: int = RoadBuilder.max_gradient_dl(md, road)
			assert_le(float(worst), float(limit),
				"seed %d road %d has a %.1f m step, limit %.1f m"
					% [master_seed, k, float(worst) * md.quant, float(limit) * md.quant])


# --- the road as a route ----------------------------------------------------------------------

## A road you cannot drive along is decoration. Every consecutive pair must be a legal move.
func test_a_road_is_drivable_along_its_whole_length() -> void:
	var md: MapData = _generate(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	for k: int in _roads(12345).size():
		var road: RoadBuilder.Road = _roads(12345)[k]
		for t: int in range(1, road.length()):
			var a: int = road.tiles[t - 1]
			var b: int = road.tiles[t]
			var d: int = Grid.dir_between(md.tx(a), md.ty(a), md.tx(b), md.ty(b))
			assert_true(md.can_move(a, d),
				"road %d is impassable between tiles %d and %d" % [k, t - 1, t])


## Four-connected only. A diagonal step would enter a tile through a corner, and the segment curve
## is defined between edge midpoints — there would be nothing for it to attach to.
func test_roads_never_step_diagonally() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return
	for k: int in _roads(12345).size():
		var road: RoadBuilder.Road = _roads(12345)[k]
		for t: int in range(1, road.length()):
			var a: int = road.tiles[t - 1]
			var b: int = road.tiles[t]
			var step: int = absi(md.tx(a) - md.tx(b)) + absi(md.ty(a) - md.ty(b))
			assert_eq(step, 1, "road %d takes a diagonal or a jump at tile %d" % [k, t])


## Every road tile must carry both an entry and an exit edge, and they must be orthogonal
## directions — the mesh builder draws a curve between those two edge midpoints and has nothing to
## draw without them.
func test_every_road_tile_is_connected() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return

	var road_tiles: int = 0
	for i: int in md.n:
		if not md.has_road(i):
			continue
		road_tiles += 1
		assert_gt(float(md.road_degree(i)), 0.0, "road tile %d links to nothing" % i)
		for d: int in 8:
			if md.has_road_link(i, d):
				assert_eq(int(Grid.IS_DIAG[d]), 0,
					"road tile %d links on a diagonal, but routing is 4-connected" % i)
	assert_gt(float(road_tiles), 0.0, "no road surface on the map")


## The invariant the mesh builder leans on: both tiles sharing an edge agree that the road crosses
## it. Without it a seam is computed from two different sets of facts and the ribbon splits.
func test_road_links_are_symmetric() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return
	for i: int in md.n:
		for d: int in 8:
			if not md.has_road_link(i, d):
				continue
			var nb: int = md.neighbour(i, d)
			if nb < 0:
				continue  # An endpoint running off the map has nothing to link back.
			assert_true(md.has_road_link(nb, Grid.opposite(d)),
				"tile %d links %d but tile %d does not link back" % [i, d, nb])


## The bug that made two roads erase each other. Stamping used to assign an entry and an exit byte,
## so the second road through a tile overwrote the first and both lost their arms there.
func test_a_crossing_keeps_both_roads() -> void:
	var md := MapData.create(9)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)

	var east_west := RoadBuilder.Road.new()
	var north_south := RoadBuilder.Road.new()
	for k: int in 9:
		east_west.tiles.append(md.idx(k, 4))
		north_south.tiles.append(md.idx(4, k))
	east_west.is_bridge.resize(9)
	north_south.is_bridge.resize(9)

	RoadBuilder._stamp(md, east_west)
	RoadBuilder._stamp(md, north_south)

	var cross: int = md.idx(4, 4)
	assert_eq(md.road_degree(cross), 4, "the crossing lost an arm")
	for d: int in [Grid.N, Grid.E, Grid.S, Grid.W]:
		assert_true(md.has_road_link(cross, d), "the crossing has no link in direction %d" % d)

	# And neither road has a hole anywhere along it.
	for k2: int in 9:
		assert_true(md.has_road(md.idx(k2, 4)), "the east-west road is broken at x=%d" % k2)
		assert_true(md.has_road(md.idx(4, k2)), "the north-south road is broken at y=%d" % k2)


## A road is a surface laid on ground, not a kind of ground — docs/decisions/0011. The tile keeps
## whatever it was, so the renderer can draw the landscape under the ribbon.
func test_a_road_keeps_the_terrain_underneath() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return
	for i: int in md.n:
		assert_ne(int(md.terrain[i]), TerrainTyper.Type.ROAD,
			"tile %d was typed ROAD; roads live in road_links now" % i)


func test_roads_are_faster_than_the_ground_around_them() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return
	var road_cost: int = int(round(cfg.terrain_move_cost[TerrainTyper.Type.ROAD] * 10.0))
	var open_cost: int = int(round(cfg.terrain_move_cost[TerrainTyper.Type.OPEN] * 10.0))
	assert_lt(float(road_cost), float(open_cost), "road surface is not cheaper than open ground")

	for i: int in md.n:
		if md.has_road(i):
			assert_eq(md.move_cost[i], road_cost, "road tile %d did not take the road cost" % i)


# --- bridges and water -------------------------------------------------------------------------

## A bridge is what makes an impassable river crossable. If it does not do that, it is scenery.
func test_bridges_make_rivers_crossable() -> void:
	var found: int = 0
	for master_seed: int in [12345, 777, 4242]:
		var md: MapData = _generate(master_seed)
		if md == null:
			continue
		for i: int in md.n:
			if md.water[i] != MapData.Water.BRIDGE:
				continue
			found += 1
			assert_true(md.is_passable(i), "the bridge at tile %d is impassable" % i)
			assert_true(md.has_road(i), "the bridge at tile %d has no road surface" % i)
	assert_gt(float(found), 0.0, "no bridges were built on any seed")


## Cut and fill blends the road's profile into a corridor either side. If that corridor is allowed
## to fill a watercourse the road passes beside, the road dams the river and the drainage network
## the previous stage built stops draining.
func test_earthworks_do_not_dam_the_rivers() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return

	var river_tiles: int = 0
	for i: int in md.n:
		if md.water[i] == MapData.Water.RIVER:
			river_tiles += 1
	assert_gt(float(river_tiles), 0.0,
		"no river tiles survived the roads — the earthworks filled them in")


# --- settlements -------------------------------------------------------------------------------

func test_villages_appear_on_the_road_network() -> void:
	# Across seeds rather than on one. A village footprint is a radius-2 disc dropped on a road
	# junction, so on any given seed it can come out entirely road and water — which is a placement
	# that provides no cover, but not a broken rule. What must hold is that villages exist, that
	# they bring fields, and that somewhere across the seeds they are actually built up.
	var villages: int = 0
	var built_up: int = 0
	var fields: int = 0

	for master_seed: int in [12345, 777]:
		var md: MapData = _generate(master_seed)
		if md == null:
			continue
		for i: int in md.n:
			match int(md.terrain[i]):
				TerrainTyper.Type.VILLAGE:
					villages += 1
					assert_true(md.is_passable(i),
						"seed %d village tile %d is impassable" % [master_seed, i])
					# A village tile with a road through it is a street, and a street is not cover
					# — the road clears the blocker exactly as it clears the trees in a wood.
					if md.has_road(i):
						assert_almost_eq(md.blocker_h[i], 0.0, 0.001,
							"seed %d street tile %d still carries the village's cover"
								% [master_seed, i])
					else:
						built_up += 1
						assert_gt(md.blocker_h[i], 0.0,
							"seed %d village tile %d does not block line of sight"
								% [master_seed, i])
				TerrainTyper.Type.FIELD:
					fields += 1

	assert_gt(float(villages), 0.0, "no villages were placed on any seed")
	assert_gt(float(built_up), 0.0, "no village anywhere had a tile that was not road")
	# Fields ring the villages, so if there are villages there should be fields.
	assert_gt(float(fields), 0.0, "villages were placed with no fields around them")


## A village flattens its footprint, and a road runs through the middle of it. That is why the
## earthworks are re-run afterwards — without it the road picks up a step exactly where the
## fighting will be.
func test_a_village_does_not_put_a_step_in_the_road() -> void:
	var md: MapData = _generate(12345)
	if md == null:
		return
	var limit: int = cfg.i("roads.max_road_dl", 2)

	for k: int in _roads(12345).size():
		var road: RoadBuilder.Road = _roads(12345)[k]
		for t: int in range(1, road.length()):
			var a: int = road.tiles[t - 1]
			var b: int = road.tiles[t]
			var near_village: bool = false
			for d: int in 8:
				var nb: int = md.neighbour(b, d)
				if nb >= 0 and md.terrain[nb] == TerrainTyper.Type.VILLAGE:
					near_village = true
					break
			if not near_village:
				continue
			assert_le(float(absi(md.level[a] - md.level[b])), float(limit),
				"the road has a %.1f m step beside a village"
					% (float(absi(md.level[a] - md.level[b])) * md.quant))


# --- routing -----------------------------------------------------------------------------------

## A road takes a long shallow detour over one steep pitch. Verified directly on a fixture: a wall
## with a notch in it must be crossed at the notch.
func test_routing_prefers_the_easy_crossing() -> void:
	var md := MapData.create(21)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	# A ridge across the middle, with one low saddle at y == 15.
	for x: int in md.size:
		for y: int in range(9, 12):
			md.level[md.idx(x, y)] = 24
	for y2: int in range(9, 12):
		md.level[md.idx(15, y2)] = 4
	Quantizer.classify_transitions(md, cfg)

	var path: PackedInt32Array = RoadBuilder.route(md, cfg, md.idx(3, 0), md.idx(3, 20))
	assert_gt(float(path.size()), 0.0, "no route found across the ridge")

	var crossed_at: int = -1
	for k: int in path.size():
		if md.ty(path[k]) == 10:
			crossed_at = md.tx(path[k])
			break
	assert_eq(crossed_at, 15,
		"the road crossed the ridge at x=%d instead of using the saddle at x=15" % crossed_at)


func test_cut_and_fill_levels_a_profile() -> void:
	var md := MapData.create(12)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	# A staircase far steeper than a road may climb.
	var path := PackedInt32Array()
	for x: int in 12:
		md.level[md.idx(x, 6)] = x * 8
		path.append(md.idx(x, 6))
	Quantizer.classify_transitions(md, cfg)

	RoadBuilder.cut_and_fill(md, cfg, path)

	var limit: int = cfg.i("roads.max_road_dl", 2)
	for k: int in range(1, path.size()):
		var step: int = absi(md.level[path[k]] - md.level[path[k - 1]])
		assert_le(float(step), float(limit),
			"cut and fill left a %d quantum step at tile %d" % [step, k])

	# It must smooth, not bulldoze: the ends should stay roughly where they were, so the road still
	# meets the ground it came from.
	assert_gt(float(md.level[path[11]]), float(md.level[path[0]]),
		"cut and fill flattened the whole route instead of easing it")
