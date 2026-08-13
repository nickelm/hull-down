extends TestCase

## Stage 4.6, second half. The acceptance check is "every deployment zone reaches every objective,
## verified by a test" — that is `test_generated_maps_are_connected`, run against real generated
## terrain rather than a fixture, because the repair only earns its keep on terrain that actually
## needed repairing.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


## The flood fill reads the traversal graph, so a test that asks about reachability has to say which
## graph it means. Rebuilt per call because these fixtures are mutated between assertions.
func _graph(md: MapData) -> TraversalGraph:
	return TraversalGraph.build(md, cfg)


# --- reachability on fixtures ------------------------------------------------------------------

## A map cut clean in half by an escarpment: the flood fill must stop at the wall.
func _walled_map(wall_x: int = 6) -> MapData:
	var md := MapData.create(14)
	md.move_cost.fill(10)
	for y: int in md.size:
		for x: int in range(wall_x, md.size):
			md.level[md.idx(x, y)] = 40  # a twenty-meter step: impassable from every direction
	Quantizer.classify_transitions(md, cfg)
	return md


func test_flood_fill_stops_at_an_escarpment() -> void:
	var md: MapData = _walled_map()
	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, PackedInt32Array([md.idx(0, 0)]), _graph(md)
	)
	assert_eq(int(seen[md.idx(5, 5)]), 1, "the near side should be reachable")
	assert_eq(int(seen[md.idx(6, 5)]), 0, "the far side must not be")


func test_flood_fill_does_not_start_on_impassable_ground() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	Quantizer.classify_transitions(md, cfg)
	md.move_cost[md.idx(0, 0)] = -10

	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, PackedInt32Array([md.idx(0, 0)]), _graph(md)
	)
	assert_eq(int(seen[md.idx(0, 0)]), 0, "a river tile is not a valid starting point")
	assert_eq(int(seen[md.idx(3, 3)]), 0, "and nothing should have been reached from it")


func test_flood_fill_reaches_everything_on_open_ground() -> void:
	var md := MapData.create(10)
	md.move_cost.fill(10)
	Quantizer.classify_transitions(md, cfg)

	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, PackedInt32Array([md.idx(0, 0)]), _graph(md)
	)
	var missed: int = 0
	for i: int in md.n:
		if seen[i] == 0:
			missed += 1
	assert_eq(missed, 0, "%d tiles unreachable on a completely flat map" % missed)


# --- repair -------------------------------------------------------------------------------------

## The repair must cut a way through a deliberate wall, and the cut must be a route rather than a
## demolition — a handful of edges, not the whole ridge.
func test_repair_cuts_through_a_wall() -> void:
	var md: MapData = _walled_map()
	# Zones either side of the wall, objective on the far side.
	for y: int in range(4, 10):
		md.deploy_zone[md.idx(1, y)] = 1
		md.deploy_zone[md.idx(12, y)] = 2
	md.objectives = PackedInt32Array([md.idx(11, 7)])

	var before: PackedByteArray = ConnectivityRepair.reachable_from(
		md, md.zone_tiles(1), _graph(md)
	)
	assert_eq(int(before[md.objectives[0]]), 0, "the fixture is not actually disconnected")

	var result: Dictionary = ConnectivityRepair.repair(md, cfg)
	assert_true(bool(result["connected"]),
		"repair failed: %s" % str(result["reason"]))

	var after: PackedByteArray = ConnectivityRepair.reachable_from(
		md, md.zone_tiles(1), _graph(md)
	)
	assert_eq(int(after[md.objectives[0]]), 1, "the objective is still unreachable after repair")
	assert_eq(int(after[md.idx(12, 7)]), 1, "the far zone is still unreachable after repair")

	assert_gt(float(int(result["edits"])), 0.0, "repair claimed success without cutting anything")
	assert_lt(float(int(result["edits"])), 40.0,
		"repair cut %d edges to make one crossing — that is a demolition, not a pass"
			% int(result["edits"]))


## Leveling a route walking backwards from the target adjusts each tile against a neighbor that
## has not been finalized yet, so the next step undoes the edge just fixed. That produced a map
## with sixty-five cut edges and no passable route. Every edge along the repaired route must end up
## traversable.
func test_every_edge_on_a_repaired_route_is_passable() -> void:
	var md: MapData = _walled_map()
	for y: int in range(4, 10):
		md.deploy_zone[md.idx(1, y)] = 1
		md.deploy_zone[md.idx(12, y)] = 2
	md.objectives = PackedInt32Array([md.idx(11, 7)])
	ConnectivityRepair.repair(md, cfg)

	# There must be at least one column-crossing edge that is passable in both directions.
	var crossings: int = 0
	for y: int in md.size:
		var a: int = md.idx(5, y)
		for d: int in 8:
			var nb: int = md.neighbor(a, d)
			if nb >= 0 and md.tx(nb) == 6 and md.can_move(a, d):
				assert_true(md.can_move(nb, Grid.opposite(d)),
					"the crossing at row %d is passable one way and not the other" % y)
				crossings += 1
	assert_gt(float(crossings), 0.0, "no passable crossing was cut through the wall")


func test_repair_is_a_no_op_on_an_already_connected_map() -> void:
	var md := MapData.create(12)
	md.move_cost.fill(10)
	Quantizer.classify_transitions(md, cfg)
	for y: int in range(4, 8):
		md.deploy_zone[md.idx(1, y)] = 1
		md.deploy_zone[md.idx(10, y)] = 2
	md.objectives = PackedInt32Array([md.idx(6, 6)])

	var before: PackedInt32Array = md.level.duplicate()
	var result: Dictionary = ConnectivityRepair.repair(md, cfg)

	assert_true(bool(result["connected"]), "a flat map reported as disconnected")
	assert_eq(int(result["edits"]), 0, "repair edited a map that needed nothing")
	for i: int in md.n:
		assert_eq(md.level[i], before[i], "repair changed the height of tile %d" % i)


## An objective sealed inside impassable terrain cannot be reached by cutting, because cutting only
## lowers escarpments — it does not drain rivers. The repair must say so rather than spin.
func test_repair_reports_failure_instead_of_looping() -> void:
	var md := MapData.create(10)
	md.move_cost.fill(10)
	Quantizer.classify_transitions(md, cfg)
	for y: int in range(2, 6):
		md.deploy_zone[md.idx(1, y)] = 1

	# Ring the objective with water.
	var obj: int = md.idx(7, 7)
	for dy: int in range(-1, 2):
		for dx: int in range(-1, 2):
			if dx != 0 or dy != 0:
				md.move_cost[md.idx(7 + dx, 7 + dy)] = -10
	md.objectives = PackedInt32Array([obj])

	var result: Dictionary = ConnectivityRepair.repair(md, cfg)
	assert_false(bool(result["connected"]), "an island behind water was reported as connected")
	assert_ne(str(result["reason"]), "", "failure was reported without saying why")
	assert_lt(float(int(result["passes"])), float(cfg.i("traversal.repair_max_passes", 8) + 1),
		"repair ran past its pass cap")


# --- placement ------------------------------------------------------------------------------------

func test_zones_land_on_opposing_edges_and_do_not_overlap() -> void:
	var md: MapData = MapGenerator.generate_small(cfg, 12345)
	assert_not_null(md, "generation rejected the seed")

	var a: PackedInt32Array = md.zone_tiles(1)
	var b: PackedInt32Array = md.zone_tiles(2)
	assert_gt(float(a.size()), 0.0, "zone A is empty")
	assert_gt(float(b.size()), 0.0, "zone B is empty")

	# The two zones start the same size but repair prunes any tiles it could not connect, so they
	# can end up different. Neither may exceed the configured footprint.
	var expected: int = int(
		cfg.f("zones.width_frac", 0.2) * float(md.size)
	) * int(cfg.f("zones.depth_frac", 0.1) * float(md.size))
	assert_le(float(a.size()), float(expected), "zone A is larger than configured")
	assert_le(float(b.size()), float(expected), "zone B is larger than configured")

	# Centroids must be far apart — they are supposed to be facing each other across the map.
	var ca: Vector2 = _centroid(md, a)
	var cb: Vector2 = _centroid(md, b)
	assert_gt(ca.distance_to(cb), float(md.size) * 0.4,
		"the zones are only %.0f tiles apart on a %d tile map" % [ca.distance_to(cb), md.size])

	for i: int in md.n:
		assert_false(md.deploy_zone[i] > 2, "tile %d has an unknown zone id" % i)


func test_objectives_are_placed_and_separated() -> void:
	var md: MapData = MapGenerator.generate_small(cfg, 12345)
	assert_not_null(md, "generation rejected the seed")
	assert_eq(md.objectives.size(), cfg.i("zones.objective_count", 3), "objective count")

	for k: int in md.objectives.size():
		var o: int = md.objectives[k]
		assert_true(md.is_passable(o), "objective %d is on impassable ground" % k)
		assert_eq(int(md.deploy_zone[o]), 0, "objective %d sits inside a deployment zone" % k)

	for a: int in md.objectives.size():
		for b: int in range(a + 1, md.objectives.size()):
			assert_ne(md.objectives[a], md.objectives[b], "two objectives share a tile")


# --- the other two ways of opening ground ---------------------------------------------------------

## A map divided by a band of the given terrain, with zones and an objective either side.
func _barrier_map(barrier_type: int, water: int = MapData.Water.NONE) -> MapData:
	var md := MapData.create(16)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for y: int in md.size:
		var t: int = md.idx(8, y)
		md.terrain[t] = barrier_type
		if water != MapData.Water.NONE:
			md.water[t] = water
			md.water_level[t] = md.level[t]
	Quantizer.classify_transitions(md, cfg)
	TerrainTyper.apply_terrain_attributes(md, cfg)

	for y2: int in range(4, 12):
		md.deploy_zone[md.idx(1, y2)] = 1
		md.deploy_zone[md.idx(14, y2)] = 2
	md.objectives = PackedInt32Array([md.idx(13, 8)])
	return md


## Heavy forest is impassable, so it is a second source of disconnection — and the repair pass has to
## be able to answer it. Before the three-op version this returned "no route" and the seed was
## thrown away.
func test_repair_clears_a_wall_of_heavy_forest() -> void:
	var md: MapData = _barrier_map(TerrainTyper.Type.WOODS_HEAVY)
	var before: PackedByteArray = ConnectivityRepair.reachable_from(
		md, md.zone_tiles(1), _graph(md)
	)
	assert_eq(int(before[md.objectives[0]]), 0, "the fixture is not actually disconnected")

	var result: Dictionary = ConnectivityRepair.repair(md, cfg)
	assert_true(bool(result["connected"]), "repair failed: %s" % str(result["reason"]))

	var after: PackedByteArray = ConnectivityRepair.reachable_from(
		md, md.zone_tiles(1), _graph(md)
	)
	assert_eq(int(after[md.objectives[0]]), 1, "the objective is still unreachable")

	# Felled, not flattened: the track through the stand is ordinary woods, still slow and still
	# cover. And it is a track — a handful of tiles, not the whole belt.
	var cleared: int = 0
	for y: int in md.size:
		if int(md.terrain[md.idx(8, y)]) != TerrainTyper.Type.WOODS_HEAVY:
			cleared += 1
	assert_gt(float(cleared), 0.0, "nothing was cleared")
	assert_lt(float(cleared), 5.0, "%d tiles felled to make one track" % cleared)
	assert_eq(int(result["fords"]), 0, "a ford was laid where clearing would do")


## A river with no bridge. Fording is the dearest op and the search must still reach for it when it
## is the only thing that works.
func test_repair_fords_a_river_when_nothing_else_will_do() -> void:
	var md: MapData = _barrier_map(TerrainTyper.Type.WATER, MapData.Water.RIVER)
	var result: Dictionary = ConnectivityRepair.repair(md, cfg)
	assert_true(bool(result["connected"]), "repair failed: %s" % str(result["reason"]))
	assert_gt(float(int(result["fords"])), 0.0, "the river was crossed without a ford")

	var crossing: int = -1
	for y: int in md.size:
		if md.water[md.idx(8, y)] == MapData.Water.FORD:
			crossing = md.idx(8, y)
			break
	assert_ge(float(crossing), 0.0, "no ford tile was created")
	if crossing < 0:
		return

	# A ford is not a marker. The tile has to have come up out of the bed far enough that both banks
	# are a legal step, or the crossing leads into the water.
	assert_true(md.is_passable(crossing), "the ford is not drivable")
	assert_true(md.can_move(crossing, Grid.W), "the west bank is not reachable from the ford")
	assert_true(md.can_move(crossing, Grid.E), "the east bank is not reachable from the ford")


## The penalties are an order apart on purpose. Given a map where cutting would serve, the search
## must not reach for the chainsaw or the ford.
func test_repair_prefers_earthwork_to_felling() -> void:
	var md: MapData = _walled_map()
	for y: int in range(4, 12):
		md.deploy_zone[md.idx(1, y)] = 1
		md.deploy_zone[md.idx(12, y)] = 2
	md.objectives = PackedInt32Array([md.idx(11, 7)])
	# Heavy forest beside the wall, offering a second way through that costs more.
	for y2: int in range(0, 4):
		md.terrain[md.idx(6, y2)] = TerrainTyper.Type.WOODS_HEAVY
	TerrainTyper.apply_terrain_attributes(md, cfg)

	var result: Dictionary = ConnectivityRepair.repair(md, cfg)
	assert_true(bool(result["connected"]), "repair failed: %s" % str(result["reason"]))
	assert_eq(int(result["fords"]), 0, "a ford was laid on a map with no river worth crossing")

	var felled: int = 0
	for y3: int in range(0, 4):
		if int(md.terrain[md.idx(6, y3)]) != TerrainTyper.Type.WOODS_HEAVY:
			felled += 1
	assert_eq(felled, 0, "the repair felled forest when cutting the escarpment was available")


# --- the acceptance check -------------------------------------------------------------------------

## "Every deployment zone reaches every objective."
func test_generated_maps_are_connected() -> void:
	for master_seed: int in [12345, 777, 4242]:
		var md: MapData = MapGenerator.generate_small(cfg, master_seed)
		assert_not_null(md, "seed %d was rejected as unrepairable" % master_seed)
		if md == null:
			continue

		var graph: TraversalGraph = _graph(md)
		for zone: int in [1, 2]:
			var seen: PackedByteArray = ConnectivityRepair.reachable_from(
				md, md.zone_tiles(zone), graph
			)
			for k: int in md.objectives.size():
				assert_eq(int(seen[md.objectives[k]]), 1,
					"seed %d: zone %d cannot reach objective %d" % [master_seed, zone, k])

			# And the zones must reach each other, or one side has nowhere to attack.
			var other: PackedInt32Array = md.zone_tiles(3 - zone)
			var any: bool = false
			for k2: int in other.size():
				if seen[other[k2]] == 1:
					any = true
					break
			assert_true(any, "seed %d: zone %d cannot reach zone %d" % [master_seed, zone, 3 - zone])


## "No river crossing without a crossing point." True by construction — RIVER is impassable to the
## reference class, so no legal route can enter one; a crossed river tile is a FORD or a BRIDGE by
## then. But this is the user-facing promise the whole connectivity apparatus exists to keep, so
## it is pinned end to end: an actual driven route from each zone to every objective and to the
## far zone, checked tile by tile. STREAM is allowed — a stream is drivable ground with a water
## overlay, and the traversal layer never reads `water` at all.
func test_zone_routes_cross_water_only_at_fords_and_bridges() -> void:
	for master_seed: int in [12345, 777, 4242]:
		var md: MapData = MapGenerator.generate_small(cfg, master_seed)
		assert_not_null(md, "seed %d was rejected as unrepairable" % master_seed)
		if md == null:
			continue

		var graph: TraversalGraph = _graph(md)
		var pf := TankPathfinder.new(md, cfg, graph)
		for zone: int in [1, 2]:
			var start: int = _first_passable(md, md.zone_tiles(zone))
			assert_ge(float(start), 0.0, "seed %d: zone %d has no passable tile" % [master_seed, zone])
			if start < 0:
				continue

			var goals: PackedInt32Array = md.objectives.duplicate()
			var far: int = _first_passable(md, md.zone_tiles(3 - zone))
			if far >= 0:
				goals.append(far)

			for g: int in goals.size():
				var path: PathResult = pf.find_path(start, Grid.E, goals[g])
				assert_true(path.found,
					"seed %d: no route from zone %d to goal %d" % [master_seed, zone, g])
				for k: int in path.tiles.size():
					assert_ne(int(md.water[path.tiles[k]]), MapData.Water.RIVER,
						"seed %d: the route from zone %d to goal %d drives through an unbridged river at tile %d"
							% [master_seed, zone, g, path.tiles[k]])


## The overflow fallback must not strand a unit across a barrier the zone cannot reach past — it
## takes reachable tiles first, and only a zone with no usable ground at all falls back to the
## whole map.
func test_deployment_overflow_stays_in_the_zone_component() -> void:
	var md: MapData = _walled_map()
	for y: int in range(4, 7):
		md.deploy_zone[md.idx(1, y)] = 1

	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, md.zone_tiles(1), _graph(md)
	)
	var starts: PackedInt32Array = Deployment.start_tiles(md, cfg, 1, 10, 6)
	assert_eq(starts.size(), 10, "the overflow did not fill the request")
	for k: int in starts.size():
		assert_eq(int(seen[starts[k]]), 1,
			"unit %d deployed on tile %d, across the wall from its zone" % [k, starts[k]])


func _first_passable(md: MapData, tiles: PackedInt32Array) -> int:
	for k: int in tiles.size():
		if md.is_passable(tiles[k]):
			return tiles[k]
	return -1


func test_generation_is_deterministic() -> void:
	var a: MapData = MapGenerator.generate_small(cfg, 24680)
	var b: MapData = MapGenerator.generate_small(cfg, 24680)
	assert_not_null(a, "first generation failed")
	assert_not_null(b, "second generation failed")
	assert_eq(a.content_hash(), b.content_hash(), "the same seed produced a different map")


func test_different_seeds_produce_different_maps() -> void:
	var a: MapData = MapGenerator.generate_small(cfg, 111)
	var b: MapData = MapGenerator.generate_small(cfg, 222)
	assert_not_null(a, "seed 111 failed")
	assert_not_null(b, "seed 222 failed")
	assert_ne(a.content_hash(), b.content_hash(), "two seeds produced identical maps")


func _centroid(md: MapData, tiles: PackedInt32Array) -> Vector2:
	var sx: float = 0.0
	var sy: float = 0.0
	for k: int in tiles.size():
		sx += float(md.tx(tiles[k]))
		sy += float(md.ty(tiles[k]))
	return Vector2(sx, sy) / float(maxi(tiles.size(), 1))
