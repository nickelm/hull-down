extends TestCase

## Rivers as obstacles rather than as decoration.
##
## The requirement is stated as a property, not as a width: **a river must be diagonally
## impermeable**. Two tiles is what the channels usually come out at and it is not the mechanism —
## the mechanism is the corner-tile rule in `MapData.can_move`, and a width guarantee without that
## rule still leaks, because a one-tile diagonal staircase has a dry destination and flat
## transitions and passes every other check.
##
## So the test is local and exhaustive rather than a bank-to-bank flood fill. A component count
## would be the obvious thing to assert and it would be wrong: a river fades upstream into `STREAM`,
## which becomes drivable marsh, so on many perfectly good seeds the river runs from mid-map to one
## edge and divides nothing at all.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


## Every diagonal step between two tiles of dry land whose two shared corners are both water. There
## must be none that is legal. This is the property, stated exactly, and it is one pass over the map.
func test_a_river_cannot_be_crossed_diagonally() -> void:
	for master_seed: int in [12345, 777, 4242]:
		var md: MapData = MapGenerator.generate_small(cfg, master_seed)
		assert_not_null(md, "seed %d was rejected" % master_seed)
		if md == null:
			continue

		var leaks: int = 0
		var checked: int = 0
		for i: int in md.n:
			if not md.is_passable(i):
				continue
			for d: int in 8:
				if Grid.IS_DIAG[d] == 0:
					continue
				var nb: int = md.neighbor(i, d)
				if nb < 0 or not md.is_passable(nb):
					continue
				var ca: int = md.neighbor(i, (d + 7) & 7)
				var cb: int = md.neighbor(i, (d + 1) & 7)
				if ca < 0 or cb < 0:
					continue
				if md.is_passable(ca) or md.is_passable(cb):
					continue
				checked += 1
				if md.can_move(i, d):
					leaks += 1

		assert_eq(leaks, 0,
			"seed %d: %d diagonal steps slip between two impassable corners (of %d)"
				% [master_seed, leaks, checked])


## The same property on a hand-built staircase, so the assertion above cannot pass merely because a
## seed happened not to contain the shape.
func test_the_staircase_shape_is_refused() -> void:
	var md := MapData.create(12)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)

	# A one-tile diagonal channel corner to corner, so there is genuinely no way round it and the
	# only question left is whether a tank can slip between two tiles of it.
	for k: int in md.size:
		var wet: int = md.idx(k, md.size - 1 - k)
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.move_cost[wet] = -10

	var leaks: int = 0
	for i: int in md.n:
		if not md.is_passable(i):
			continue
		for d: int in 8:
			if Grid.IS_DIAG[d] == 0 or not md.can_move(i, d):
				continue
			var ca: int = md.neighbor(i, (d + 7) & 7)
			var cb: int = md.neighbor(i, (d + 1) & 7)
			if ca >= 0 and cb >= 0 and not md.is_passable(ca) and not md.is_passable(cb):
				leaks += 1
	assert_eq(leaks, 0, "a one-tile diagonal channel leaked in %d places" % leaks)

	# And the channel really does separate the map, which is the point of refusing those steps.
	var graph: TraversalGraph = TraversalGraph.build(md, cfg)
	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, PackedInt32Array([md.idx(0, 0)]), graph
	)
	assert_eq(int(seen[md.idx(11, 11)]), 0, "the far bank was reached across a one-tile channel")


## A ford is what makes a river crossable. With the crossings closed the two banks are separate
## components; opening them joins the two.
func test_a_crossing_joins_two_banks() -> void:
	var md := MapData.create(16)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for y: int in md.size:
		var wet: int = md.idx(8, y)
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.water[wet] = MapData.Water.RIVER
		md.move_cost[wet] = -10
	Quantizer.classify_transitions(md, cfg)

	var graph: TraversalGraph = TraversalGraph.build(md, cfg)
	var before: Dictionary = MapMetrics.river_crossings(md, graph)
	assert_eq(int(before["crossings"]), 0, "a river with no ford reported a crossing")
	assert_true(bool(before["spans_map"]), "a river straight across the map did not divide it")

	# Lay one ford and the two banks become one component again.
	var ford: int = md.idx(8, 8)
	md.terrain[ford] = TerrainTyper.Type.FORD
	md.water[ford] = MapData.Water.FORD
	TerrainTyper.apply_terrain_attributes(md, cfg)

	graph.rebuild()
	var after: Dictionary = MapMetrics.river_crossings(md, graph)
	assert_eq(int(after["crossings"]), 1, "the ford did not register as a crossing")

	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, PackedInt32Array([md.idx(0, 8)]), graph
	)
	assert_eq(int(seen[md.idx(15, 8)]), 1, "the far bank is unreachable across the ford")


## An amphibian does not need the ford. The river metric is about tracked vehicles, and this is what
## proves the class parameter is threaded through it rather than being decorative.
func test_an_amphibian_does_not_need_a_crossing() -> void:
	var md := MapData.create(16)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for y: int in md.size:
		var wet: int = md.idx(8, y)
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.water[wet] = MapData.Water.RIVER
		md.move_cost[wet] = -10
	Quantizer.classify_transitions(md, cfg)

	var start := PackedInt32Array([md.idx(0, 8)])
	var far: int = md.idx(15, 8)

	var tracked: PackedByteArray = ConnectivityRepair.reachable_from(
		md, start, TraversalGraph.build(md, cfg, MovementClass.Kind.TRACKED)
	)
	assert_eq(int(tracked[far]), 0, "a tank forded a river that has no ford")

	var swimmer: PackedByteArray = ConnectivityRepair.reachable_from(
		md, start, TraversalGraph.build(md, cfg, MovementClass.Kind.AMPHIBIOUS)
	)
	assert_eq(int(swimmer[far]), 1, "an amphibian could not cross open water")
