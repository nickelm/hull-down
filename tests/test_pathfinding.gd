extends TestCase

## Stage 4.12. The acceptance check has a headless half — the tank drives to any reachable tile and
## faces sensibly along its path — and a visual half. What is asserted here is that the search is
## actually optimal, which is the part that is invisible on screen: a route that is merely plausible
## looks exactly like a route that is shortest.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _open(size: int = 16) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


# --- optimality --------------------------------------------------------------------------------

## A* against brute force.
##
## The heuristic is what makes A* fast and it is also what makes it wrong when it overestimates —
## and an inadmissible heuristic produces routes that look fine and are not shortest. The only way
## to know is to compare against a search with no heuristic at all.
func test_astar_matches_brute_force_dijkstra() -> void:
	var md: MapData = _open(14)
	# Terrain variety, so cost actually varies.
	for y: int in md.size:
		for x: int in md.size:
			var i: int = md.idx(x, y)
			if (x * 7 + y * 3) % 11 == 0:
				md.level[i] = 3
			if (x + y) % 5 == 0:
				md.terrain[i] = TerrainTyper.Type.WOODS
				md.move_cost[i] = int(cfg.terrain_move_cost[TerrainTyper.Type.WOODS] * 10.0)
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var start: int = md.idx(1, 1)
	var reference: PackedInt32Array = pf.reachable(start, Grid.E, 100000)

	var mismatches: int = 0
	for y2: int in range(0, md.size, 3):
		for x2: int in range(0, md.size, 3):
			var goal: int = md.idx(x2, y2)
			if reference[goal] < 0:
				continue
			var p: PathResult = pf.find_path(start, Grid.E, goal)
			if not p.found:
				mismatches += 1
				continue
			if p.cost != reference[goal]:
				mismatches += 1
	assert_eq(mismatches, 0,
		"%d destinations where A* disagreed with an exhaustive search" % mismatches)


func test_a_path_is_a_sequence_of_legal_moves() -> void:
	var md: MapData = _open(20)
	for y: int in range(4, 16):
		md.level[md.idx(10, y)] = 14  # an escarpment with a gap at each end
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(2, 10), Grid.E, md.idx(18, 10))
	assert_true(p.found, "no route around the escarpment")

	for k: int in range(1, p.tiles.size()):
		var a: int = p.tiles[k - 1]
		var b: int = p.tiles[k]
		var d: int = Grid.dir_between(md.tx(a), md.ty(a), md.tx(b), md.ty(b))
		assert_ge(float(d), 0.0, "step %d does not move to an adjacent tile" % k)
		assert_true(md.can_move(a, d), "step %d is not a legal move" % k)


func test_escarpments_are_never_crossed() -> void:
	var md: MapData = _open(20)
	for y: int in md.size:
		md.level[md.idx(10, y)] = 40  # a wall clean across the map
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(2, 10), Grid.E, md.idx(18, 10))
	assert_false(p.found, "the pathfinder drove over a twenty-meter escarpment")

	var reach: PackedInt32Array = pf.reachable(md.idx(2, 10), Grid.E, 100000)
	assert_lt(float(reach[md.idx(18, 10)]), 0.0, "the far side should be unreachable")
	assert_ge(float(reach[md.idx(9, 10)]), 0.0, "the near side should be reachable")


func test_impassable_terrain_is_never_entered() -> void:
	var md: MapData = _open(12)
	for y: int in md.size:
		md.move_cost[md.idx(6, y)] = -10  # a river
	var pf := TankPathfinder.new(md, cfg)
	var reach: PackedInt32Array = pf.reachable(md.idx(1, 6), Grid.E, 100000)
	assert_lt(float(reach[md.idx(6, 6)]), 0.0, "a river tile was entered")
	assert_lt(float(reach[md.idx(10, 6)]), 0.0, "the far bank should be unreachable")


func test_diagonal_corner_cutting_is_refused() -> void:
	var md: MapData = _open(9)
	md.level[md.idx(5, 4)] = 20
	md.level[md.idx(4, 5)] = 20
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(4, 4), Grid.SE, md.idx(5, 5))
	if p.found:
		for k: int in range(1, p.tiles.size()):
			var a: int = p.tiles[k - 1]
			var b: int = p.tiles[k]
			assert_false(a == md.idx(4, 4) and b == md.idx(5, 5),
				"the tank slipped diagonally between two escarpment corners")


# --- facing ------------------------------------------------------------------------------------

## Turning costs movement, so a route that ends facing the wrong way is not free. The facing
## recorded for each tile has to be the facing the tank actually holds there.
func test_facing_follows_the_route() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(2, 6), Grid.E, md.idx(9, 6))
	assert_true(p.found, "no route across open ground")
	assert_eq(p.tiles.size(), p.facings.size(), "facings do not match tiles")

	# Driving due east the whole way, the tank should be facing east on arrival.
	assert_eq(p.final_facing(), Grid.E, "the tank did not end up facing along its route")


## Turning round costs four turn steps; reversing one tile should be cheaper than that, and the
## search should notice.
func test_reversing_beats_turning_round_for_one_tile() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)

	# Facing east, asked to move one tile west.
	var p: PathResult = pf.find_path(md.idx(6, 6), Grid.E, md.idx(5, 6))
	assert_true(p.found, "no route to the tile behind")
	assert_eq(p.final_facing(), Grid.E,
		"the tank turned round to move one tile instead of reversing")
	assert_eq(int(p.reversed[p.reversed.size() - 1]), 1, "the step was not marked as a reverse")

	var turn_cost: int = cfg.i("movement.turn_cost_per_45", 3)
	assert_lt(float(p.cost), float(turn_cost * 4 + cfg.i("movement.base_ortho", 10)),
		"reversing cost more than turning round would have")


## And over a long enough run, turning round wins — reversing is costlier per tile, so it should
## only be used for short moves.
func test_turning_round_beats_reversing_over_distance() -> void:
	var md: MapData = _open(20)
	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(16, 10), Grid.E, md.idx(2, 10))
	assert_true(p.found, "no route back across the map")
	assert_eq(p.final_facing(), Grid.W,
		"the tank reversed the whole way instead of turning round")


func test_rough_going_is_reported() -> void:
	var md: MapData = _open(10)
	# A three-quantum step: passable but rough.
	for y: int in md.size:
		md.level[md.idx(5, y)] = 3
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(2, 5), Grid.E, md.idx(8, 5))
	assert_true(p.found, "no route over rough ground")
	assert_true(p.blocks_firing, "crossing a rough transition was not flagged")

	var flat: PathResult = pf.find_path(md.idx(6, 5), Grid.E, md.idx(8, 5))
	assert_false(flat.blocks_firing, "a route over level ground was flagged as rough")


# --- the movement overlay ----------------------------------------------------------------------

## The reachable set and the path search must agree about what is reachable, or the overlay offers
## the player moves the pathfinder then refuses.
func test_reachable_set_matches_what_paths_exist() -> void:
	var md: MapData = _open(14)
	for y: int in range(2, 12):
		md.level[md.idx(7, y)] = 16
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var budget: int = 90
	var reach: PackedInt32Array = pf.reachable(md.idx(2, 7), Grid.E, budget)

	var wrong: int = 0
	for i: int in md.n:
		var p: PathResult = pf.find_path(md.idx(2, 7), Grid.E, i, budget)
		if (reach[i] >= 0) != p.found:
			wrong += 1
		elif p.found and p.cost != reach[i]:
			wrong += 1
	assert_eq(wrong, 0, "%d tiles where the overlay and the pathfinder disagree" % wrong)


func test_budget_is_respected() -> void:
	var md: MapData = _open(20)
	var pf := TankPathfinder.new(md, cfg)
	var budget: int = 50
	var reach: PackedInt32Array = pf.reachable(md.idx(10, 10), Grid.E, budget)
	for i: int in md.n:
		assert_le(float(reach[i]), float(budget), "tile %d is listed above the budget" % i)


## The overlay is recomputed on every selection change and after every move, and it has a frame to
## do it in. Measured on the shipping map size with a realistic allowance.
func test_the_movement_overlay_fits_its_budget() -> void:
	var md: MapData = _open(Grid.SIZE)
	var pf := TankPathfinder.new(md, cfg)
	var mp: int = cfg.i("movement.default_mp", 220)

	# Warm: the first call sizes the reusable buffers, and that cost is paid once per map.
	pf.reachable(md.idx(100, 100), Grid.E, mp)
	var reach: PackedInt32Array = pf.reachable(md.idx(100, 100), Grid.E, mp)

	var reached: int = 0
	for i: int in md.n:
		if reach[i] >= 0:
			reached += 1
	assert_gt(float(reached), 100.0, "the flood fill barely went anywhere")

	var ms: float = float(pf.last_elapsed_usec) / 1000.0
	# Open ground with no obstacles is the worst case for a given allowance: nothing prunes the
	# search. The target is 50 ms; failing this means the overlay stutters on selection.
	assert_lt(ms, 50.0,
		"the movement overlay took %.1f ms for %d tiles (%d states) — budget is 50 ms"
			% [ms, reached, pf.last_states_expanded])


# --- state encoding ----------------------------------------------------------------------------

func test_state_packing_round_trips() -> void:
	for tile: int in [0, 1, 4321, Grid.COUNT - 1]:
		for facing: int in 8:
			var s: int = TankPathfinder.state_of(tile, facing)
			assert_eq(TankPathfinder.tile_of(s), tile, "tile did not survive packing")
			assert_eq(TankPathfinder.facing_of(s), facing, "facing did not survive packing")


func test_dial_queue_pops_in_key_order() -> void:
	var q := DialQueue.new(64, 32)
	q.push(9, 1)
	q.push(2, 2)
	q.push(5, 3)
	q.push(2, 4)

	var keys := PackedInt32Array()
	while not q.is_empty():
		var v: int = q.pop()
		assert_ge(float(v), 0.0, "pop returned an invalid value")
		keys.append(q.last_key)

	for k: int in range(1, keys.size()):
		assert_ge(float(keys[k]), float(keys[k - 1]), "the queue popped out of order")


func test_dial_queue_clear_resets_it() -> void:
	var q := DialQueue.new(32, 16)
	q.push(4, 1)
	q.clear()
	assert_true(q.is_empty(), "clear left items behind")
	assert_eq(q.pop(), -1, "popping an empty queue should give -1")
	q.push(3, 2)
	assert_eq(q.pop(), 2, "the queue is unusable after being cleared")


## The facing recorded on a tile is the one the tank *departs* with, not the one it arrived with.
##
## `find_path` collapses turn-in-place states, keeping the last facing held on each tile. The view
## drives leg k with `facings[k]`; reading `facings[k + 1]` aims at the next leg's heading, which
## made the tank turn a full tile early and crab sideways across the first one.
func test_the_facing_on_a_tile_is_the_one_it_leaves_with() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)

	# Start facing north, drive to a tile due east. The tank must turn first, and the turn belongs
	# to the starting tile.
	var start: int = md.idx(2, 6)
	var goal: int = md.idx(6, 6)
	var path: PathResult = pf.find_path(start, Grid.N, goal, 10000)
	assert_true(path.found, "no route across open ground")
	if not path.found:
		return

	assert_eq(path.tiles[0], start, "the path should start where the tank is")
	assert_eq(path.facings[0], Grid.E,
		"the starting tile should record the facing the tank leaves with, not the one it arrived with")

	# Every leg's recorded facing must be the direction actually traveled, for a forward route.
	for k: int in path.tiles.size() - 1:
		var travel: int = Grid.dir_between(
			md.tx(path.tiles[k]), md.ty(path.tiles[k]),
			md.tx(path.tiles[k + 1]), md.ty(path.tiles[k + 1])
		)
		if path.reversed[k + 1] == 1:
			continue
		assert_eq(path.facings[k], travel,
			"leg %d travels %d but the tile records facing %d" % [k, travel, path.facings[k]])


## No tile appears twice: a turn is folded into the tile it happens on, which is what makes
## `facings[k]` a departure facing in the first place.
func test_turns_do_not_duplicate_a_tile() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var path: PathResult = pf.find_path(md.idx(2, 6), Grid.S, md.idx(8, 6), 10000)
	assert_true(path.found, "no route")
	if not path.found:
		return

	var seen := {}
	for k: int in path.tiles.size():
		assert_false(seen.has(path.tiles[k]), "tile %d appears twice in the path" % path.tiles[k])
		seen[path.tiles[k]] = true


# --- per-step cost -------------------------------------------------------------------------------

## The invariant that makes the split trustworthy. `cost` is what the search paid; `step_cost` and
## `turn_cost` are that same figure attributed to the tiles it was spent on. If they ever disagree,
## the path preview is charging the player for something other than what the move will cost.
func test_step_and_turn_costs_sum_to_the_total() -> void:
	var md: MapData = _open(14)
	for y: int in md.size:
		for x: int in md.size:
			var i: int = md.idx(x, y)
			if (x * 7 + y * 3) % 11 == 0:
				md.level[i] = 3
			if (x + y) % 5 == 0:
				md.terrain[i] = TerrainTyper.Type.WOODS
				md.move_cost[i] = int(cfg.terrain_move_cost[TerrainTyper.Type.WOODS] * 10.0)
	Quantizer.classify_transitions(md, cfg)

	var pf := TankPathfinder.new(md, cfg)
	var start: int = md.idx(1, 1)
	var checked: int = 0
	for y2: int in range(0, md.size, 3):
		for x2: int in range(0, md.size, 3):
			var p: PathResult = pf.find_path(start, Grid.E, md.idx(x2, y2))
			if not p.found:
				continue
			checked += 1
			var total: int = 0
			for k: int in p.tiles.size():
				total += p.step_cost[k] + p.turn_cost[k]
			assert_eq(total, p.cost,
				"attributed cost %d disagrees with the search's %d for (%d,%d)"
					% [total, p.cost, x2, y2])
	assert_gt(float(checked), 4.0, "too few routes were actually exercised")


func test_the_cost_arrays_are_parallel_to_the_tiles() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(2, 2), Grid.N, md.idx(9, 7), 10000)
	assert_true(p.found, "no route across open ground")
	var n: int = p.tiles.size()
	assert_eq(p.facings.size(), n, "facings is not parallel to tiles")
	assert_eq(p.reversed.size(), n, "reversed is not parallel to tiles")
	assert_eq(p.step_cost.size(), n, "step_cost is not parallel to tiles")
	assert_eq(p.turn_cost.size(), n, "turn_cost is not parallel to tiles")


## The swing before the tank sets off is banked against the tile it stands on, not against the first
## tile it reaches. Nothing is charged for entering the tile it is already on.
func test_the_opening_turn_is_charged_to_the_starting_tile() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)

	# Facing north, ordered due east: a two-step swing before anything moves.
	var p: PathResult = pf.find_path(md.idx(2, 6), Grid.N, md.idx(6, 6), 10000)
	assert_true(p.found, "no route")
	if not p.found:
		return
	assert_eq(p.step_cost[0], 0, "there is no step into the tile the tank is already standing on")
	assert_eq(p.turn_cost[0], cfg.i("movement.turn_cost_per_45", 3) * 2,
		"the ninety-degree swing before setting off is not charged to the starting tile")


## A route straight ahead pays nothing for turning, which is the baseline the opening-turn test is
## measured against.
func test_a_straight_route_has_no_turn_cost() -> void:
	var md: MapData = _open(12)
	var pf := TankPathfinder.new(md, cfg)
	var p: PathResult = pf.find_path(md.idx(2, 6), Grid.E, md.idx(8, 6), 10000)
	assert_true(p.found, "no route")
	if not p.found:
		return
	for k: int in p.tiles.size():
		assert_eq(p.turn_cost[k], 0, "tile %d was charged for a turn on a straight route" % k)
		if k > 0:
			assert_eq(p.step_cost[k], cfg.i("movement.base_ortho", 10),
				"an orthogonal step across open ground should cost the base rate")


## The degenerate route. `start == goal` returns early, before the backtracking that fills the cost
## arrays, so it has to size them itself or every consumer indexes off the end of a shorter array
## than `tiles`.
func test_a_zero_length_route_still_sizes_its_cost_arrays() -> void:
	var md: MapData = _open(10)
	var pf := TankPathfinder.new(md, cfg)
	var here: int = md.idx(4, 4)
	var p: PathResult = pf.find_path(here, Grid.N, here, 10000)
	assert_true(p.found, "standing still is a route")
	assert_eq(p.step_cost.size(), p.tiles.size(), "step_cost is not parallel to tiles")
	assert_eq(p.turn_cost.size(), p.tiles.size(), "turn_cost is not parallel to tiles")
	assert_eq(p.tile_cost(0), 0, "standing still costs nothing")
