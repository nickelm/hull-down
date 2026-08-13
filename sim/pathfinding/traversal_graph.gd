class_name TraversalGraph
extends RefCounted

## What a vehicle can do on this map, flattened once into arrays.
##
## Everything that asks "can something move from here to there, and what does that cost" reads this:
## the movement overlay, the connectivity flood fill, the repair pass, and the chokepoint min-cut.
## That is the point of it. Each of those used to re-derive the answer independently through
## `can_move -> neighbor -> transition -> neighbor`, six function calls deep per edge — which was
## most of the overlay's frame budget on its own, and which left nothing structurally guaranteeing
## the four agreed with each other. A map the flood fill calls connected and the min-cut calls
## severed is a disagreement nobody can see.
##
## Built once per map and never invalidated by anything the *game* does. Dynamic obstructions — the
## units standing on tiles — are deliberately not here. They belong to a per-query overlay passed
## into the search, because they change every time a unit moves and rebuilding two megabytes of
## table for that would be absurd. Generation is the one caller that does mutate the ground under
## the graph, and it rebuilds rather than patching.

var md: MapData
var n: int = 0

## Which kind of vehicle this graph is about. See MovementClass.
var mclass: int = MovementClass.REFERENCE

## Movement cost multiplier x10 for entering each tile. -10 marks ground this class cannot enter.
##
## For the reference class this is `MapData.move_cost` — the row the generator baked, which is
## authoritative because the generator is entitled to edit it. Other classes are derived here from
## `terrain` and `road_links` using the same rule, on demand, since nothing stores them.
var tile_cost: PackedInt32Array = PackedInt32Array()

## Full integer step cost for each (tile, direction), or -1 where the move is illegal. Includes the
## rough-going surcharge, so the search never has to look at the transition class again.
var edge_cost: PackedInt32Array = PackedInt32Array()

## Destination tile for each (tile, direction), or -1 where the move is illegal.
var edge_target: PackedInt32Array = PackedInt32Array()

## Lower bound on the cost multiplier of any tile on this map, for the octile heuristic. Taken from
## the map rather than from the data file so it is a true lower bound on what is actually there.
var min_cost_x10: int = 10

var _cfg: Config
var _base_ortho: int = 10
var _base_diag: int = 14
var _rough_extra: int = 8
## The road's surface cost x10 for this class — the price of a step that follows a road link.
var _road_cost_x10: int = 6


static func build(
	map: MapData, cfg: Config, movement_class: int = MovementClass.REFERENCE
) -> TraversalGraph:
	var g := TraversalGraph.new()
	g.md = map
	g.n = map.n
	g.mclass = movement_class
	g._cfg = cfg
	g._base_ortho = cfg.i("movement.base_ortho", 10)
	g._base_diag = cfg.i("movement.base_diag", 14)
	g._rough_extra = cfg.i("traversal.rough_extra_cost", 8)
	var road: float = cfg.class_cost(movement_class, TerrainTyper.Type.ROAD)
	g._road_cost_x10 = int(round(road * 10.0)) if road > 0.0 else 10
	g.rebuild()
	return g


## Recompute every table from the map as it stands now.
##
## About 320,000 entries and a fifth of a second at full size. Generation calls this after it has
## moved the ground; nothing else needs to, because the map does not change once a match starts.
func rebuild() -> void:
	_bake_tile_cost()

	edge_cost = PackedInt32Array()
	edge_cost.resize(n * 8)
	edge_target = PackedInt32Array()
	edge_target.resize(n * 8)

	for i: int in n:
		var base_idx: int = i * 8
		if tile_cost[i] < 0:
			for d: int in 8:
				edge_cost[base_idx + d] = -1
				edge_target[base_idx + d] = -1
			continue

		for d2: int in 8:
			var nb: int = _legal_target(i, d2)
			edge_target[base_idx + d2] = nb
			edge_cost[base_idx + d2] = -1 if nb < 0 else _step_cost(i, nb, d2)

	_compute_min_cost()


## The octile heuristic's lower bound, recovered from the edge table rather than from the tiles.
##
## Scanning `tile_cost` was right while roads discounted the tile. It is wrong now: a road step is
## priced on the edge, so it can be cheaper than any tile on the map, and a heuristic scaled by the
## cheapest *tile* would overestimate the cost of a route along a road. An overestimate is an
## inadmissible heuristic, and an inadmissible heuristic returns routes that are visibly not the
## shortest and very hard to argue with afterwards.
##
## Dividing the step cost back out by its own base recovers the effective multiplier exactly. The
## integer division truncates downward, which is the safe direction: a lower bound that is slightly
## too low costs a few more expanded states, one that is too high costs correctness.
func _compute_min_cost() -> void:
	min_cost_x10 = 10
	for i: int in n:
		var base_idx: int = i * 8
		for d: int in 8:
			var ec: int = edge_cost[base_idx + d]
			if ec < 0:
				continue
			var base: int = _base_diag if Grid.IS_DIAG[d] == 1 else _base_ortho
			var effective: int = ec * 10 / base
			if effective > 0 and effective < min_cost_x10:
				min_cost_x10 = effective
	if min_cost_x10 < 1:
		min_cost_x10 = 1


## Destination of a legal move from `i` in direction `d`, or -1.
##
## This is `MapData.can_move`'s rule, applied against **this class's** costs rather than the baked
## reference row. It has to be restated here rather than delegated: `md.can_move` answers for the
## vehicles the game fields, so asking it about an amphibian gets the tank's answer — which is how
## a boat first failed to cross a river.
##
## Two statements of one rule is a drift risk, and the thing that keeps it honest is
## `tests/test_traversal::test_the_graph_agrees_with_map_data_for_the_reference_class`, which walks
## every edge of a generated map and compares the two directly.
func _legal_target(i: int, d: int) -> int:
	var nb: int = md.neighbor(i, d)
	if nb < 0 or tile_cost[nb] < 0:
		return -1
	if md.transition(i, d) >= MapData.Trans.BLOCKED:
		return -1
	if Grid.IS_DIAG[d] == 0:
		return nb
	var da: int = (d + 7) & 7
	var db: int = (d + 1) & 7
	if md.transition(i, da) >= MapData.Trans.BLOCKED:
		return -1
	if md.transition(i, db) >= MapData.Trans.BLOCKED:
		return -1
	# Both corner tiles must be ground this class can stand on, or it cuts diagonally between two
	# tiles of river that meet at a point. See MapData.can_move.
	var ca: int = md.neighbor(i, da)
	var cb: int = md.neighbor(i, db)
	if ca < 0 or cb < 0 or tile_cost[ca] < 0 or tile_cost[cb] < 0:
		return -1
	return nb


## What it costs this class to stand on each tile.
##
## The reference class reads the baked layer straight off the map. That is not a shortcut — it is
## the definition: `MapData.move_cost` *is* the reference row, the generator writes it, and the
## generator is allowed to edit it directly. Re-deriving it here would quietly disagree with
## anything that had.
##
## Other classes are derived with the same rule `TerrainTyper.apply_terrain_attributes` uses, and
## `tests/test_traversal` asserts the two agree for the reference class on a generated map, which is
## what keeps that asymmetry honest rather than merely convenient.
func _bake_tile_cost() -> void:
	if mclass == MovementClass.REFERENCE:
		tile_cost = md.move_cost.duplicate()
		return

	var types: int = _cfg.type_count()
	var base: int = mclass * types
	var road_cost: float = _cfg.class_move_cost[base + TerrainTyper.Type.ROAD]

	tile_cost = PackedInt32Array()
	tile_cost.resize(n)
	for i: int in n:
		var cost: float = _cfg.class_move_cost[base + int(md.terrain[i])]
		# The deck override only, matching TerrainTyper.apply_terrain_attributes. The surface
		# discount is an edge property and is applied in _step_cost.
		if md.road_links[i] != 0 and cost < 0.0:
			cost = road_cost
		tile_cost[i] = -10 if cost < 0.0 else int(round(cost * 10.0))


## Cost of entering `to_tile` from `from_tile` in direction `d`.
##
## The step cost is the base octile step scaled by the destination tile's terrain multiplier, plus a
## flat surcharge where the edge is rough going. Rough is folded in here rather than left to the
## caller so the search reads one number — but note that `PathResult.blocks_firing` still has to ask
## `MapData.transition` directly, because once the surcharge is baked in this array can no longer
## say *which* edges were rough.
## A step that follows a road link is priced at the road's surface cost outright, not at the
## destination tile's terrain — the vehicle is on the made surface for the whole step and what is
## underneath it is irrelevant. `link_road` sets the bit on both sides of one shared edge, so
## `has_road_link(from, d)` is exactly "the entering and the leaving edge are both road-connected";
## there is one bit, not two.
##
## Cost the reduction here rather than on the tile and a tank crossing a road perpendicular pays
## full price for the ground it is actually on, which is the point.
func _step_cost(from_tile: int, to_tile: int, d: int) -> int:
	var base: int = _base_diag if Grid.IS_DIAG[d] == 1 else _base_ortho
	var mult: int = _road_cost_x10 if md.has_road_link(from_tile, d) else tile_cost[to_tile]
	var cost: int = base * mult / 10
	if md.transition(from_tile, d) == MapData.Trans.ROUGH:
		cost += _rough_extra
	return cost


## Whether anything can stand on this tile.
func passable(i: int) -> bool:
	return tile_cost[i] >= 0


## Whether a move from `i` in direction `d` is legal. Unlike `MapData.can_move` this also requires
## the *source* tile to be passable, which is what every caller wanted anyway.
func can_move(i: int, d: int) -> bool:
	return edge_target[i * 8 + d] >= 0
