class_name TankPathfinder
extends RefCounted

## Movement for a tank, with facing in the search state.
##
## A tank is not a chess piece. It points somewhere, turning costs time, and reversing costs more
## than driving forward â€” so the state is (tile, facing), 200 x 200 x 8 = 320,000 states, and the
## cheapest route to a tile depends on which way you arrive facing.
##
## The moves available from a state are deliberately few:
##
##   turn 45 degrees either way, in place
##   drive forward, along the current facing
##   reverse, to the tile directly behind
##
## Four edges rather than eight. Changing direction means paying for the turn first, which is both
## what a tracked vehicle actually does and the thing that keeps the branching factor low enough for
## the flood fill to finish inside a frame.
##
## Costs are integers throughout. Orthogonal steps are 10 and diagonal 14 â€” the standard octile
## scaling â€” multiplied by the destination tile's terrain cost, which terrain.json stores times ten.

## Reusable per-query state, sized once. Reallocating 320k entries per query would cost more than
## the search.
var _g: PackedInt32Array
var _from_state: PackedInt32Array
var _stamp: PackedInt32Array
var _query: int = 0
var _queue: DialQueue

var _md: MapData
var _cfg: Config

var _base_ortho: int
var _base_diag: int
var _turn_cost: int
var _reverse_mult: float
var _rough_extra: int
var _min_terrain_cost: int
var _max_cost: int
var _edge_cost: PackedInt32Array
var _edge_target: PackedInt32Array

## Diagnostics for the HUD â€” the movement overlay has a 50 ms budget and it is worth being able to
## see when it is being missed rather than guessing.
var last_states_expanded: int = 0
var last_elapsed_usec: int = 0


func _init(md: MapData, cfg: Config) -> void:
	_md = md
	_cfg = cfg

	_base_ortho = cfg.i("movement.base_ortho", 10)
	_base_diag = cfg.i("movement.base_diag", 14)
	_turn_cost = cfg.i("movement.turn_cost_per_45", 3)
	_reverse_mult = cfg.f("movement.reverse_mult", 1.6)
	_rough_extra = cfg.i("movement.rough_extra_cost", 8)
	_max_cost = cfg.i("movement.max_path_cost", 12000)

	# The cheapest terrain on this map, for the heuristic. Taken from the map rather than from the
	# data file so it is a true lower bound on what is actually there.
	_min_terrain_cost = 10
	for i: int in md.n:
		var c: int = md.move_cost[i]
		if c > 0 and c < _min_terrain_cost:
			_min_terrain_cost = c

	_build_edge_tables()

	var states: int = md.n * 8
	_g = PackedInt32Array()
	_g.resize(states)
	_from_state = PackedInt32Array()
	_from_state.resize(states)
	_stamp = PackedInt32Array()
	_stamp.resize(states)
	_stamp.fill(-1)
	_queue = DialQueue.new(_max_cost, states * 2)


static func state_of(tile: int, facing: int) -> int:
	return (tile << 3) | facing


static func tile_of(state: int) -> int:
	return state >> 3


static func facing_of(state: int) -> int:
	return state & 7


## Cost of entering `to` from `from` in direction `d`, or -1 if the move is illegal.
func _step_cost(from_tile: int, to_tile: int, d: int) -> int:
	var base: int = _base_diag if Grid.IS_DIAG[d] == 1 else _base_ortho
	var cost: int = base * _md.move_cost[to_tile] / 10
	if _md.transition(from_tile, d) == MapData.Trans.ROUGH:
		cost += _rough_extra
	return cost


## Flatten "can I move there, and what does it cost" into one lookup per (tile, direction).
##
## The search asks that question about four edges for every state it expands, and answering it
## live means `can_move` -> `neighbour` -> `transition` -> `neighbour` again, six function calls
## deep, per edge. GDScript charges for every one of them, and at ten thousand states that call
## chain was most of the overlay's frame budget on its own.
##
## Built once per map: 320,000 entries, about 1.3 MB, a fifth of a second. After that the inner
## loop is an array read and a comparison.
func _build_edge_tables() -> void:
	var n: int = _md.n
	_edge_cost = PackedInt32Array()
	_edge_cost.resize(n * 8)
	_edge_target = PackedInt32Array()
	_edge_target.resize(n * 8)

	for i: int in n:
		var base_idx: int = i * 8
		if not _md.is_passable(i):
			for d: int in 8:
				_edge_cost[base_idx + d] = -1
				_edge_target[base_idx + d] = -1
			continue
		for d: int in 8:
			if not _md.can_move(i, d):
				_edge_cost[base_idx + d] = -1
				_edge_target[base_idx + d] = -1
				continue
			var nb: int = _md.neighbour(i, d)
			_edge_target[base_idx + d] = nb
			_edge_cost[base_idx + d] = _step_cost(i, nb, d)


## Every tile reachable within `budget` movement points, as cost-to-reach per tile (-1 unreachable).
##
## This is the movement overlay, and it has to land inside a frame. It is only recomputed when the
## selection changes or a move finishes â€” never per frame â€” because even at 40 ms a per-frame cost
## would be the whole budget.
func reachable(start_tile: int, start_facing: int, budget: int) -> PackedInt32Array:
	var t0: int = Time.get_ticks_usec()
	_query += 1
	_queue.clear()
	last_states_expanded = 0

	var start: int = state_of(start_tile, start_facing)
	_g[start] = 0
	_stamp[start] = _query
	_from_state[start] = -1
	_queue.push(0, start)

	var best := PackedInt32Array()
	best.resize(_md.n)
	best.fill(-1)
	best[start_tile] = 0

	while true:
		var s: int = _queue.pop()
		if s == -1:
			break
		var cost: int = _queue.last_key
		if cost > _g[s] or _stamp[s] != _query:
			continue
		last_states_expanded += 1

		var tile: int = s >> 3
		var facing: int = s & 7

		for e: int in 4:
			var to_state: int = -1
			var nd: int = -1

			match e:
				0:
					# Turn left in place.
					to_state = state_of(tile, (facing + 7) & 7)
					nd = cost + _turn_cost
				1:
					# Turn right in place.
					to_state = state_of(tile, (facing + 1) & 7)
					nd = cost + _turn_cost
				2:
					# Drive forward.
					var ec: int = _edge_cost[tile * 8 + facing]
					if ec < 0:
						continue
					to_state = (_edge_target[tile * 8 + facing] << 3) | facing
					nd = cost + ec
				_:
					# Reverse: into the tile behind, without turning round.
					var back: int = (facing + 4) & 7
					var rc: int = _edge_cost[tile * 8 + back]
					if rc < 0:
						continue
					to_state = (_edge_target[tile * 8 + back] << 3) | facing
					nd = cost + int(float(rc) * _reverse_mult)

			if nd > budget:
				continue
			if _stamp[to_state] == _query and nd >= _g[to_state]:
				continue
			_stamp[to_state] = _query
			_g[to_state] = nd
			_from_state[to_state] = s
			_queue.push(nd, to_state)

			var nt: int = to_state >> 3
			if best[nt] == -1 or nd < best[nt]:
				best[nt] = nd

	last_elapsed_usec = Time.get_ticks_usec() - t0
	return best


## Cheapest route to `goal_tile`, arriving on any facing.
##
## Runs the same relaxation as `reachable` with an octile heuristic. The heuristic is scaled by the
## cheapest terrain on the map so it never overestimates â€” an inadmissible heuristic here produces
## routes that are visibly not the shortest and are very hard to argue with afterwards. Turn costs
## are deliberately *not* folded in: a lower bound on them is easy to get wrong, and getting it
## wrong is the same bug.
func find_path(start_tile: int, start_facing: int, goal_tile: int, budget: int = -1) -> PathResult:
	var t0: int = Time.get_ticks_usec()
	var result := PathResult.new()
	var limit: int = budget if budget > 0 else _max_cost

	if not _md.is_passable(goal_tile):
		return result
	if start_tile == goal_tile:
		result.found = true
		result.tiles = PackedInt32Array([start_tile])
		result.facings = PackedInt32Array([start_facing])
		result.reversed = PackedByteArray([0])
		return result

	_query += 1
	_queue.clear()
	last_states_expanded = 0

	var gx: int = _md.tx(goal_tile)
	var gy: int = _md.ty(goal_tile)

	var start: int = state_of(start_tile, start_facing)
	_g[start] = 0
	_stamp[start] = _query
	_from_state[start] = -1
	_queue.push(_heuristic(start_tile, gx, gy), start)

	var goal_state: int = -1
	# Sentinel, not a budget. The queue is ordered by f = g + heuristic, so comparing it against a
	# movement allowance aborts the search the moment the heuristic alone exceeds what is left â€”
	# which for a distant goal is immediately. The allowance is enforced on g, where it belongs.
	var goal_cost: int = 1 << 30

	while true:
		var s: int = _queue.pop()
		if s == -1:
			break
		var f: int = _queue.last_key
		# Stop once nothing left in the queue could beat the best route already found. Taking the
		# first popped goal state instead would be correct only if the heuristic is provably
		# consistent, and that is an argument about integer division and turn costs that is easy to
		# get subtly wrong â€” this holds whenever the heuristic merely never overestimates.
		if f >= goal_cost:
			break

		var tile: int = s >> 3
		var cost: int = _g[s]
		last_states_expanded += 1

		if tile == goal_tile:
			if cost < goal_cost:
				goal_cost = cost
				goal_state = s
			continue

		var facing: int = s & 7
		for e: int in 4:
			var to_state: int = -1
			var nd: int = -1
			var rev: bool = false

			match e:
				0:
					to_state = state_of(tile, (facing + 7) & 7)
					nd = cost + _turn_cost
				1:
					to_state = state_of(tile, (facing + 1) & 7)
					nd = cost + _turn_cost
				2:
					var ec: int = _edge_cost[tile * 8 + facing]
					if ec < 0:
						continue
					to_state = (_edge_target[tile * 8 + facing] << 3) | facing
					nd = cost + ec
				_:
					var back: int = (facing + 4) & 7
					var rc: int = _edge_cost[tile * 8 + back]
					if rc < 0:
						continue
					to_state = (_edge_target[tile * 8 + back] << 3) | facing
					nd = cost + int(float(rc) * _reverse_mult)
					rev = true

			if nd > limit:
				continue
			if _stamp[to_state] == _query and nd >= _g[to_state]:
				continue
			_stamp[to_state] = _query
			_g[to_state] = nd
			_from_state[to_state] = s
			_queue.push(nd + _heuristic(to_state >> 3, gx, gy), to_state)

	last_elapsed_usec = Time.get_ticks_usec() - t0
	if goal_state == -1:
		return result

	# Walk the predecessors back. Turn-in-place steps stay on the same tile and are collapsed into
	# the facing recorded for that tile.
	var states := PackedInt32Array()
	var cur: int = goal_state
	while cur != -1:
		states.append(cur)
		cur = _from_state[cur]
	states.reverse()

	result.found = true
	result.cost = _g[goal_state]
	for k: int in states.size():
		var st: int = states[k]
		var tile2: int = st >> 3
		if result.tiles.size() > 0 and result.tiles[result.tiles.size() - 1] == tile2:
			# Same tile, new facing: a turn. Overwrite rather than append.
			result.facings[result.facings.size() - 1] = st & 7
			continue
		result.tiles.append(tile2)
		result.facings.append(st & 7)
		# Driven in reverse if the facing points away from the direction of travel.
		var driven_backwards: bool = false
		if result.tiles.size() > 1:
			var prev: int = result.tiles[result.tiles.size() - 2]
			var travel: int = Grid.dir_between(
				_md.tx(prev), _md.ty(prev), tile2 % _md.size, tile2 / _md.size
			)
			driven_backwards = travel != (st & 7)
			if _md.transition(prev, travel) == MapData.Trans.ROUGH:
				result.blocks_firing = true
		result.reversed.append(1 if driven_backwards else 0)

	return result


func _heuristic(tile: int, gx: int, gy: int) -> int:
	return Grid.octile(tile % _md.size, tile / _md.size, gx, gy) * _min_terrain_cost / 10
