class_name VertexMinCut
extends RefCounted

## How many tiles must be held to seal one side of the map off from the other.
##
## A **vertex** cut, not an edge cut. "How many adjacencies must be severed" is not a question
## anyone can act on; "how many tiles must a company physically occupy to close this route" is the
## tactical question, and on a grid the two give very different numbers — edge cuts are inflated by
## the fact that every tile has eight of them.
##
## Standard reduction: split each passable tile into an in-node and an out-node joined by an arc of
## capacity one. Cutting that arc costs one tile. Adjacency arcs between tiles get effectively
## infinite capacity so the cut never falls on them. Max flow then equals the minimum number of
## tiles that must be blocked.
##
## Edmonds-Karp is normally too slow to reach for, but here the answer is *small by design* — the
## metric targets two to six — and the algorithm performs one breadth-first search per unit of
## flow. Capping the search at eight augmentations makes the whole thing seven or eight passes over
## the graph regardless of map size.

const INF_CAP := 1 << 20


## Returns the number of tiles that must be blocked, or `cap + 1` if it exceeds the cap.
##
## Takes the traversal graph rather than consulting `MapData` directly, so this measures the same
## graph the connectivity flood fill walks. The two loops below — one to size the arc arrays, one to
## fill them — must read the *same* predicate: if they ever disagree, the fill writes past the end
## of `to` and `capacity`, which is a hard runtime error rather than a wrong number.
static func min_cut(
	md: MapData, source_tiles: PackedInt32Array, sink_tiles: PackedInt32Array, cap: int,
	g: TraversalGraph
) -> int:
	var n: int = md.n
	# Node numbering: tile i has in-node 2i and out-node 2i+1.
	var nodes: int = n * 2 + 2
	var super_source: int = n * 2
	var super_sink: int = n * 2 + 1

	# Adjacency as parallel arrays. An edge and its reverse are stored together so `k ^ 1` is the
	# reverse of edge `k` — the usual trick, and it keeps residual updates to two array writes.
	#
	# Built with the insertion written out inline rather than through a helper. A lambda would be
	# the obvious way to express it and is a trap here: GDScript closures capture by value, so the
	# graph arrays end up shared between the closure and this scope, and every one of the three
	# hundred thousand appends copies the whole graph. It does not fail — it just never finishes.
	var edges: int = 0
	for i: int in n:
		if g.passable(i):
			edges += 1
			for d: int in 8:
				if g.can_move(i, d):
					edges += 1
	edges += source_tiles.size() + sink_tiles.size()

	var head := PackedInt32Array()
	head.resize(nodes)
	head.fill(-1)
	var next := PackedInt32Array()
	var to := PackedInt32Array()
	var capacity := PackedInt32Array()
	next.resize(edges * 2)
	to.resize(edges * 2)
	capacity.resize(edges * 2)
	var e_count: int = 0

	for i2: int in n:
		if not g.passable(i2):
			continue

		# The tile itself: capacity one, so routing through it costs one tile of the cut.
		to[e_count] = i2 * 2 + 1
		capacity[e_count] = 1
		next[e_count] = head[i2 * 2]
		head[i2 * 2] = e_count
		to[e_count + 1] = i2 * 2
		capacity[e_count + 1] = 0
		next[e_count + 1] = head[i2 * 2 + 1]
		head[i2 * 2 + 1] = e_count + 1
		e_count += 2

		for d2: int in 8:
			if not g.can_move(i2, d2):
				continue
			var nb: int = g.edge_target[i2 * 8 + d2]
			to[e_count] = nb * 2
			capacity[e_count] = INF_CAP
			next[e_count] = head[i2 * 2 + 1]
			head[i2 * 2 + 1] = e_count
			to[e_count + 1] = i2 * 2 + 1
			capacity[e_count + 1] = 0
			next[e_count + 1] = head[nb * 2]
			head[nb * 2] = e_count + 1
			e_count += 2

	# The zones themselves must not be cuttable, or the answer is just "block the deployment zone".
	for k: int in source_tiles.size():
		var s: int = source_tiles[k]
		if not g.passable(s):
			continue
		to[e_count] = s * 2
		capacity[e_count] = INF_CAP
		next[e_count] = head[super_source]
		head[super_source] = e_count
		to[e_count + 1] = super_source
		capacity[e_count + 1] = 0
		next[e_count + 1] = head[s * 2]
		head[s * 2] = e_count + 1
		e_count += 2

	for k2: int in sink_tiles.size():
		var t: int = sink_tiles[k2]
		if not g.passable(t):
			continue
		to[e_count] = super_sink
		capacity[e_count] = INF_CAP
		next[e_count] = head[t * 2 + 1]
		head[t * 2 + 1] = e_count
		to[e_count + 1] = t * 2 + 1
		capacity[e_count + 1] = 0
		next[e_count + 1] = head[super_sink]
		head[super_sink] = e_count + 1
		e_count += 2

	var flow: int = 0
	var parent_edge := PackedInt32Array()
	var queue := PackedInt32Array()
	parent_edge.resize(nodes)
	queue.resize(nodes)

	while flow <= cap:
		parent_edge.fill(-1)
		parent_edge[super_source] = -2
		var qh: int = 0
		var qt: int = 0
		queue[qt] = super_source
		qt += 1
		var found: bool = false

		while qh < qt and not found:
			var u: int = queue[qh]
			qh += 1
			var e: int = head[u]
			while e != -1:
				var v: int = to[e]
				if capacity[e] > 0 and parent_edge[v] == -1:
					parent_edge[v] = e
					if v == super_sink:
						found = true
						break
					queue[qt] = v
					qt += 1
				e = next[e]

		if not found:
			return flow

		# Every augmenting path here carries exactly one unit: each passes through at least one
		# tile arc, and those have capacity one.
		var cur: int = super_sink
		while cur != super_source:
			var e2: int = parent_edge[cur]
			capacity[e2] -= 1
			capacity[e2 ^ 1] += 1
			cur = to[e2 ^ 1]
		flow += 1

	return cap + 1
