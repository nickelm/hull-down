class_name GridAStar
extends RefCounted

## Tile-level A* with a caller-supplied edge cost.
##
## Deliberately separate from TankPathfinder. This one takes a `Callable` per edge, which is a
## luxury the tank's hot loop cannot afford — but road routing and connectivity repair run once at
## generation time, where a few hundred thousand Callable dispatches cost milliseconds and the
## flexibility is worth it.
##
## Godot's built-in AStarGrid2D cannot serve either caller: it supports per-*point* weights, not
## per-*edge* costs, so it cannot express "this edge is steep" or "this edge crosses a river".

## Roads move on the four orthogonal directions only.
##
## A road segment is defined by the edge it enters through and the edge it leaves by, drawn as a
## curve through the tile center. A diagonal step would enter through a corner, and corners are not
## edges — the curve would have nothing to attach to and adjacent segments would not meet.
static func route_4(
	md: MapData, from_tile: int, to_tile: int, edge_cost: Callable, heuristic_scale: float = 1.0
) -> PackedInt32Array:
	return _search(md, from_tile, to_tile, edge_cost, heuristic_scale, false)


static func route_8(
	md: MapData, from_tile: int, to_tile: int, edge_cost: Callable, heuristic_scale: float = 1.0
) -> PackedInt32Array:
	return _search(md, from_tile, to_tile, edge_cost, heuristic_scale, true)


## `edge_cost` is called as edge_cost(from_tile, to_tile, direction) and returns a non-negative
## integer, or a negative number to mean "impassable".
static func _search(
	md: MapData, from_tile: int, to_tile: int, edge_cost: Callable,
	heuristic_scale: float, diagonals: bool
) -> PackedInt32Array:
	var n: int = md.n
	var g := PackedInt32Array()
	g.resize(n)
	g.fill(-1)
	var came := PackedInt32Array()
	came.resize(n)
	came.fill(-1)
	var closed := PackedByteArray()
	closed.resize(n)

	var dir_count: int = 8 if diagonals else 4
	# Orthogonals are directions 0, 2, 4, 6 in Grid's tables.
	var dirs := PackedInt32Array()
	for d: int in 8:
		if diagonals or (d & 1) == 0:
			dirs.append(d)

	var heap := IntHeap.new()
	g[from_tile] = 0
	heap.push(_h(md, from_tile, to_tile, heuristic_scale), from_tile)

	while not heap.is_empty():
		var packed: int = heap.pop()
		var c: int = IntHeap.value_of(packed)
		if closed[c] != 0:
			continue
		closed[c] = 1
		if c == to_tile:
			break

		for k: int in dirs.size():
			var d: int = dirs[k]
			var nb: int = md.neighbor(c, d)
			if nb < 0 or closed[nb] != 0:
				continue
			var step: int = edge_cost.call(c, nb, d)
			if step < 0:
				continue
			var nd: int = g[c] + step
			if g[nb] == -1 or nd < g[nb]:
				g[nb] = nd
				came[nb] = c
				heap.push(nd + _h(md, nb, to_tile, heuristic_scale), nb)

	if g[to_tile] == -1:
		return PackedInt32Array()

	var path := PackedInt32Array()
	var cur: int = to_tile
	while cur != -1:
		path.append(cur)
		cur = came[cur]
	path.reverse()
	return path


## Manhattan for the 4-connected case, scaled to the caller's cost units. Scaled by the cheapest
## possible edge so it stays admissible — an overestimate here produces a route that looks optimal
## and is not, which on a road shows up as an unnecessary detour nobody can explain.
static func _h(md: MapData, a: int, b: int, scale: float) -> int:
	var dx: int = absi(md.tx(a) - md.tx(b))
	var dy: int = absi(md.ty(a) - md.ty(b))
	return int(float(dx + dy) * scale)
