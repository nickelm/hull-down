extends TestCase

## The traversal graph — the one table the movement overlay, the connectivity flood fill, the repair
## pass and the chokepoint min-cut all read.
##
## Two things are asserted here that are invisible on screen. First, that the graph and `MapData`
## agree for the reference class: the graph is a cache of a rule, and a cache that has drifted from
## its rule is worse than no cache. Second, that the movement classes genuinely disagree about the
## same ground — a class dimension every consumer threads but nothing ever exercises is decoration,
## and would rot without anyone noticing.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _open(size: int = 16) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


# --- the graph is a faithful cache of the rule ---------------------------------------------------

## Every edge, both answers, on terrain rough enough to exercise the interesting cases.
func test_the_graph_agrees_with_map_data_for_the_reference_class() -> void:
	var md: MapData = MapGenerator.generate_small(cfg, 12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var g: TraversalGraph = TraversalGraph.build(md, cfg)
	var cost_mismatch: int = 0
	var edge_mismatch: int = 0
	for i: int in md.n:
		if g.passable(i) != md.is_passable(i):
			cost_mismatch += 1
		for d: int in 8:
			# The graph also requires the source tile to be standable, which `can_move` leaves to
			# the caller. Everywhere it matters the caller had already checked.
			var expected: bool = md.is_passable(i) and md.can_move(i, d)
			if g.can_move(i, d) != expected:
				edge_mismatch += 1

	assert_eq(cost_mismatch, 0, "%d tiles disagree about passability" % cost_mismatch)
	assert_eq(edge_mismatch, 0, "%d edges disagree about legality" % edge_mismatch)


## The reference class reads the baked layer; every other class derives its own from `terrain` and
## `road_links`. That asymmetry is only safe while the derivation agrees with what the generator
## baked, so this rebuilds the reference row the derived way and compares.
func test_the_derived_costs_match_the_baked_ones() -> void:
	var md: MapData = MapGenerator.generate_small(cfg, 777)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var types: int = cfg.type_count()
	var base: int = MovementClass.REFERENCE * types
	var road_cost: float = cfg.class_move_cost[base + TerrainTyper.Type.ROAD]
	var mismatch: int = 0
	for i: int in md.n:
		var cost: float = cfg.class_move_cost[base + int(md.terrain[i])]
		# Deck only: a road makes impassable ground standable, but does not discount the tile.
		if md.road_links[i] != 0 and cost < 0.0:
			cost = road_cost
		var expected: int = -10 if cost < 0.0 else int(round(cost * 10.0))
		if md.move_cost[i] != expected:
			mismatch += 1
	assert_eq(mismatch, 0,
		"%d tiles where the baked cost is not what the class table says" % mismatch)


func test_the_graph_prices_a_step_by_the_destination() -> void:
	var md: MapData = _open(8)
	var slow: int = md.idx(4, 4)
	md.terrain[slow] = TerrainTyper.Type.MARSH
	md.move_cost[slow] = int(cfg.terrain_move_cost[TerrainTyper.Type.MARSH] * 10.0)

	var g: TraversalGraph = TraversalGraph.build(md, cfg)
	var into_marsh: int = g.edge_cost[md.idx(3, 4) * 8 + Grid.E]
	var over_open: int = g.edge_cost[md.idx(2, 4) * 8 + Grid.E]
	assert_gt(float(into_marsh), float(over_open),
		"entering a marsh cost the same as crossing open ground")


# --- the classes disagree ------------------------------------------------------------------------

## A river across the middle of the map. A tank must stop at it; an amphibian must not.
func test_a_class_that_cannot_enter_a_terrain_never_enters_it() -> void:
	var md: MapData = _open(14)
	for y: int in md.size:
		var wet: int = md.idx(7, y)
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.move_cost[wet] = -10

	var start := PackedInt32Array([md.idx(0, 7)])
	var far: int = md.idx(13, 7)

	var tracked: PackedByteArray = ConnectivityRepair.reachable_from(
		md, start, TraversalGraph.build(md, cfg, MovementClass.Kind.TRACKED)
	)
	assert_eq(int(tracked[far]), 0, "a tank crossed a river")

	var swimmer: PackedByteArray = ConnectivityRepair.reachable_from(
		md, start, TraversalGraph.build(md, cfg, MovementClass.Kind.AMPHIBIOUS)
	)
	assert_eq(int(swimmer[far]), 1, "an amphibian could not cross a river")


## The same map, two classes, two different answers about cost. If these ever come out equal the
## class dimension has quietly stopped being read.
func test_two_classes_disagree_about_the_same_ground() -> void:
	var md: MapData = _open(8)
	for y: int in md.size:
		var w: int = md.idx(4, y)
		md.terrain[w] = TerrainTyper.Type.WOODS
		md.move_cost[w] = int(cfg.terrain_move_cost[TerrainTyper.Type.WOODS] * 10.0)

	var from: int = md.idx(3, 4)
	var tracked: TraversalGraph = TraversalGraph.build(md, cfg, MovementClass.Kind.TRACKED)
	var foot: TraversalGraph = TraversalGraph.build(md, cfg, MovementClass.Kind.FOOT)

	assert_lt(
		float(foot.edge_cost[from * 8 + Grid.E]),
		float(tracked.edge_cost[from * 8 + Grid.E]),
		"infantry paid as much as armor to enter woods"
	)


func test_a_lorry_cannot_cross_a_marsh_a_tank_can() -> void:
	var md: MapData = _open(8)
	var bog: int = md.idx(4, 4)
	md.terrain[bog] = TerrainTyper.Type.MARSH
	md.move_cost[bog] = int(cfg.terrain_move_cost[TerrainTyper.Type.MARSH] * 10.0)

	assert_true(TraversalGraph.build(md, cfg, MovementClass.Kind.TRACKED).passable(bog),
		"a tank cannot enter a marsh")
	assert_false(TraversalGraph.build(md, cfg, MovementClass.Kind.WHEELED).passable(bog),
		"a lorry drove into a marsh")


# --- roads are an edge property --------------------------------------------------------------------

## Two woods tiles with a road between them. Driving along the link costs road surface; driving into
## the same tile from the side costs woods.
func test_a_road_step_costs_the_surface_and_a_crossing_does_not() -> void:
	var md: MapData = _open(10)
	var woods_cost: int = int(cfg.terrain_move_cost[TerrainTyper.Type.WOODS] * 10.0)
	for i: int in md.n:
		md.terrain[i] = TerrainTyper.Type.WOODS
		md.move_cost[i] = woods_cost

	var a: int = md.idx(4, 5)
	var b: int = md.idx(5, 5)
	md.link_road(a, Grid.E)

	var g: TraversalGraph = TraversalGraph.build(md, cfg)
	var road_x10: int = int(round(cfg.terrain_move_cost[TerrainTyper.Type.ROAD] * 10.0))

	assert_eq(g.edge_cost[a * 8 + Grid.E], 10 * road_x10 / 10,
		"driving along the road did not cost road surface")
	# Into b from the south — the same destination tile, no road link on that edge.
	assert_eq(g.edge_cost[md.idx(5, 6) * 8 + Grid.N], 10 * woods_cost / 10,
		"crossing onto a road tile took the road discount for free")
	assert_gt(float(g.edge_cost[md.idx(5, 6) * 8 + Grid.N]), float(g.edge_cost[a * 8 + Grid.E]),
		"the perpendicular crossing was not dearer than travelling along the road")
	assert_eq(md.move_cost[b], woods_cost,
		"the road tile itself should keep the going of the ground underneath it")


## The deck half of the rule: a road over ground the class cannot enter makes that tile standable.
## That is what a bridge is.
func test_a_road_deck_makes_impassable_ground_standable() -> void:
	var md: MapData = _open(10)
	var wet: int = md.idx(5, 5)
	md.terrain[wet] = TerrainTyper.Type.WATER
	md.move_cost[wet] = -10

	assert_false(TraversalGraph.build(md, cfg).passable(wet), "open water should not be standable")

	md.link_road(md.idx(4, 5), Grid.E)
	md.link_road(wet, Grid.E)
	TerrainTyper.apply_terrain_attributes(md, cfg)
	assert_true(TraversalGraph.build(md, cfg).passable(wet), "the bridge deck is not standable")


## The octile heuristic must never exceed the true cost. A road step is cheaper than any tile on the
## map, so a bound taken from the tiles would overestimate — and an inadmissible heuristic returns
## routes that are not the shortest.
func test_the_heuristic_bound_survives_roads() -> void:
	var md: MapData = _open(10)
	md.link_road(md.idx(4, 5), Grid.E)

	var g: TraversalGraph = TraversalGraph.build(md, cfg)
	var road_x10: int = int(round(cfg.terrain_move_cost[TerrainTyper.Type.ROAD] * 10.0))
	assert_le(float(g.min_cost_x10), float(road_x10),
		"the heuristic bound is above the road surface cost and so overestimates along a road")

	for i: int in md.n:
		for d: int in 8:
			var ec: int = g.edge_cost[i * 8 + d]
			if ec < 0:
				continue
			var base: int = 14 if Grid.IS_DIAG[d] == 1 else 10
			assert_le(float(base * g.min_cost_x10 / 10), float(ec),
				"the heuristic overestimates the edge from %d in direction %d" % [i, d])


# --- the diagonal corner rule --------------------------------------------------------------------

## The one-tile diagonal staircase: water at (5,5) and (6,6), land at (6,5) and (5,6). The
## destination is dry and both transitions are flat, so every other check passes it. A tank must
## still not drive between the two.
func test_a_diagonal_between_two_impassable_corners_is_refused() -> void:
	var md: MapData = _open(12)
	for wet: int in [md.idx(5, 5), md.idx(6, 6)]:
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.move_cost[wet] = -10

	# (6,5) -> (5,6) is south-west; the corners are (5,5) and (6,6).
	assert_false(md.can_move(md.idx(6, 5), Grid.SW), "a tank cut the corner of a river")
	assert_false(md.can_move(md.idx(5, 6), Grid.NE), "and the same edge from the other side")

	var g: TraversalGraph = TraversalGraph.build(md, cfg)
	assert_false(g.can_move(md.idx(6, 5), Grid.SW), "the graph disagrees with the map")


## An amphibian is not cutting a corner — it is entering the water. The corner rule must not stop it.
func test_the_corner_rule_is_per_class() -> void:
	var md: MapData = _open(12)
	for wet: int in [md.idx(5, 5), md.idx(6, 6)]:
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.move_cost[wet] = -10

	var swimmer: TraversalGraph = TraversalGraph.build(md, cfg, MovementClass.Kind.AMPHIBIOUS)
	assert_true(swimmer.can_move(md.idx(6, 5), Grid.SW),
		"an amphibian was stopped by corners it can swim through")


## The pre-existing escarpment-corner rule must not regress: this is the case that motivated the
## diagonal check in the first place.
func test_a_diagonal_between_two_escarpment_corners_is_still_refused() -> void:
	var md: MapData = _open(12)
	md.level[md.idx(5, 5)] = 40
	md.level[md.idx(6, 6)] = 40
	Quantizer.classify_transitions(md, cfg)

	assert_false(md.can_move(md.idx(6, 5), Grid.SW), "a tank cut between two escarpment corners")


## Passability is unchanged by the corner rule — it removes edges, not ground. The escarpment band
## the generator is tuned against reads `trans`, so it must not move either.
func test_the_corner_rule_does_not_change_the_escarpment_band() -> void:
	var md: MapData = _open(12)
	for wet: int in [md.idx(5, 5), md.idx(6, 6)]:
		md.terrain[wet] = TerrainTyper.Type.WATER
		md.move_cost[wet] = -10
	assert_eq(md.escarpment_fraction(), 0.0,
		"impassable terrain leaked into the escarpment fraction, which counts height steps only")


# --- dynamic blockers ----------------------------------------------------------------------------

## The overlay is per query, not part of the graph. An empty one must be indistinguishable from
## passing nothing at all — otherwise every existing caller silently changes behavior.
func test_an_empty_blocker_overlay_changes_nothing() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var plain: PackedInt32Array = pf.reachable(md.idx(6, 6), Grid.E, 200)
	var empty: PackedInt32Array = pf.reachable(md.idx(6, 6), Grid.E, 200, PackedByteArray())

	assert_eq(plain.size(), empty.size(), "the two reachable sets are different sizes")
	var diff: int = 0
	for i: int in plain.size():
		if plain[i] != empty[i]:
			diff += 1
	assert_eq(diff, 0, "%d tiles differ with an empty overlay" % diff)


func test_a_blocked_tile_is_not_reachable() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var start: int = md.idx(2, 6)
	var occupied: int = md.idx(6, 6)

	var before: PackedInt32Array = pf.reachable(start, Grid.E, 400)
	assert_ge(float(before[occupied]), 0.0, "the fixture cannot reach the tile in the first place")

	var blockers := PackedByteArray()
	blockers.resize(md.n)
	blockers[occupied] = 1
	var after: PackedInt32Array = pf.reachable(start, Grid.E, 400, blockers)
	assert_lt(float(after[occupied]), 0.0, "a tank drove onto an occupied tile")


## A wall of units with one gap: the route must go through the gap rather than through a unit.
func test_a_path_routes_around_a_blocker() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var blockers := PackedByteArray()
	blockers.resize(md.n)
	for y: int in md.size:
		if y != 1:
			blockers[md.idx(6, y)] = 1

	var path: PathResult = pf.find_path(md.idx(2, 6), Grid.E, md.idx(9, 6), 2000, blockers)
	assert_true(path.found, "no route through the gap")
	if not path.found:
		return
	for k: int in path.tiles.size():
		assert_eq(int(blockers[path.tiles[k]]), 0,
			"the route ran through an occupied tile at %d" % path.tiles[k])


func test_a_blocked_goal_is_refused() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var goal: int = md.idx(8, 6)
	var blockers := PackedByteArray()
	blockers.resize(md.n)
	blockers[goal] = 1

	var path: PathResult = pf.find_path(md.idx(2, 6), Grid.E, goal, 2000, blockers)
	assert_false(path.found, "a tank was ordered onto a tile another unit is standing on")


## A unit must not block itself, or it can never be given an order again.
func test_a_unit_does_not_block_itself() -> void:
	var state := MatchState.create(2)
	var a := UnitState.new()
	a.tile = 40
	var b := UnitState.new()
	b.tile = 55
	state.add_unit(a)
	state.add_unit(b)

	var overlay: PackedByteArray = state.occupancy(100, 0)
	assert_eq(int(overlay[40]), 0, "the moving unit blocked its own starting tile")
	assert_eq(int(overlay[55]), 1, "the other unit is not blocking anything")

	var both: PackedByteArray = state.occupancy(100)
	assert_eq(int(both[40]), 1, "excluding nothing should block every occupied tile")
