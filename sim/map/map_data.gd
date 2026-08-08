class_name MapData
extends RefCounted

## The gameplay map. Everything from stage 4.6 onward reads this and never touches the continuous
## heightfield again.
##
## **Elevation is stored as integer quanta, not metres.** `level[i] * 0.5` is the height in metres.
## That choice propagates: the spec's traversal thresholds become exact integer comparisons —
## `|dl| <= 2` is "under a metre", `3..4` is "one to two metres", `>= 5` is an escarpment — so there
## is no epsilon anywhere in passability, and the map hashes cleanly for the determinism tests.
##
## Every per-tile layer is a flat Packed*Array of `n` entries. The whole map is about a megabyte,
## which is what makes MapCodec worth having: full generation costs minutes, and stages 4.7 through
## 4.14 must not pay that on every run.

## Tile-to-tile transition classes, in increasing order of difficulty. The ordering is relied on:
## `trans[..] >= BLOCKED` is the passability test.
enum Trans { NORMAL = 0, ROUGH = 1, BLOCKED = 2 }

## Water state of a tile. NONE and FORD are drivable; STREAM, RIVER are not; BRIDGE is drivable and
## carries a road deck above the water.
enum Water { NONE = 0, STREAM = 1, RIVER = 2, FORD = 3, BRIDGE = 4 }

var size: int = Grid.SIZE
var n: int = Grid.COUNT
var tile_m: float = Grid.TILE_M
var quant: float = Grid.QUANT
var master_seed: int = 0

## Elevation in 0.5 m quanta.
var level: PackedInt32Array
## TerrainTyper.Type per tile.
var terrain: PackedByteArray
## Transition class per tile for the four canonical directions (E, SE, S, SW), `n * 4` entries.
## The reverse of each edge is read from the neighbour rather than stored twice, so edge symmetry
## is structural instead of something to test for.
var trans: PackedByteArray
## Movement cost multiplier x10, from terrain.json. -10 marks impassable ground.
var move_cost: PackedInt32Array
## Water enum per tile.
var water: PackedByteArray
## Water surface elevation in quanta. Zero where there is no water.
var water_level: PackedInt32Array
## Normalized log flow accumulation, 0..1.
var moisture: PackedFloat32Array
## Height of line-of-sight-blocking cover above ground, in metres. Woods and villages set this.
var blocker_h: PackedFloat32Array
## Road connectivity per tile, as a bitmask: bit `d` is set when this tile's road connects to its
## neighbour in direction `d`. Zero means no road.
##
## A mask rather than an entry/exit pair because a tile can carry more than one road. Two roads
## crossing produce a degree-4 tile, and stamping ORs bits in, so neither road is erased by the
## other — see docs/decisions/0011. Routing is 4-connected, so only the orthogonal bits are set.
var road_links: PackedByteArray
## 0 none, 1 side A, 2 side B.
var deploy_zone: PackedByteArray
## Tile indices of the objectives. Connectivity anchors and metric anchors in iteration 1; nothing
## captures them until iteration 2.
var objectives: PackedInt32Array

## Lazy cache behind `max_level()`. INT_MIN means "not computed yet".
const INT_MIN := -9223372036854775808
var _max_level: int = INT_MIN


static func create(grid_size: int = Grid.SIZE) -> MapData:
	var m := MapData.new()
	m.size = grid_size
	m.n = grid_size * grid_size
	m.level = PackedInt32Array()
	m.level.resize(m.n)
	m.terrain = PackedByteArray()
	m.terrain.resize(m.n)
	m.trans = PackedByteArray()
	m.trans.resize(m.n * 4)
	m.move_cost = PackedInt32Array()
	m.move_cost.resize(m.n)
	m.water = PackedByteArray()
	m.water.resize(m.n)
	m.water_level = PackedInt32Array()
	m.water_level.resize(m.n)
	m.moisture = PackedFloat32Array()
	m.moisture.resize(m.n)
	m.blocker_h = PackedFloat32Array()
	m.blocker_h.resize(m.n)
	m.road_links = PackedByteArray()
	m.road_links.resize(m.n)
	m.deploy_zone = PackedByteArray()
	m.deploy_zone.resize(m.n)
	m.objectives = PackedInt32Array()
	return m


func idx(x: int, y: int) -> int:
	return y * size + x


func tx(i: int) -> int:
	return i % size


func ty(i: int) -> int:
	return i / size


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < size and y >= 0 and y < size


func height_m(i: int) -> float:
	return float(level[i]) * quant


func water_m(i: int) -> float:
	return float(water_level[i]) * quant


## Height of the line-of-sight silhouette at a tile: the ground plus whatever stands on it.
func blocker_top_m(i: int) -> float:
	return float(level[i]) * quant + blocker_h[i]


## Neighbour tile index in direction `d`, or -1 off the map.
func neighbour(i: int, d: int) -> int:
	var x: int = i % size + Grid.DX[d]
	var y: int = i / size + Grid.DY[d]
	if x < 0 or x >= size or y < 0 or y >= size:
		return -1
	return y * size + x


## Transition class leaving tile `i` in direction `d`.
##
## Only four directions are stored. For the other four the edge is looked up from the neighbour in
## the opposite direction, which is the same edge — so `transition(a, E)` and `transition(b, W)` can
## never disagree, because they read the same byte.
func transition(i: int, d: int) -> int:
	var slot: int = Grid.CANON_SLOT[d]
	if slot >= 0:
		return int(trans[i * 4 + slot])
	var nb: int = neighbour(i, d)
	if nb < 0:
		return Trans.BLOCKED
	return int(trans[nb * 4 + Grid.CANON_SLOT[Grid.opposite(d)]])


func set_transition(i: int, d: int, value: int) -> void:
	var slot: int = Grid.CANON_SLOT[d]
	if slot >= 0:
		trans[i * 4 + slot] = value
		return
	var nb: int = neighbour(i, d)
	if nb >= 0:
		trans[nb * 4 + Grid.CANON_SLOT[Grid.opposite(d)]] = value


## Whether a tank can move from `i` in direction `d`.
##
## Diagonals additionally require both adjoining orthogonal edges to be passable. Without that a
## tank slips between two escarpment corners that meet at a point — legal on the graph, absurd on
## the ground.
func can_move(i: int, d: int) -> bool:
	var nb: int = neighbour(i, d)
	if nb < 0:
		return false
	if move_cost[nb] < 0:
		return false
	if transition(i, d) >= Trans.BLOCKED:
		return false
	if Grid.IS_DIAG[d] == 0:
		return true
	var da: int = (d + 7) & 7
	var db: int = (d + 1) & 7
	return transition(i, da) < Trans.BLOCKED and transition(i, db) < Trans.BLOCKED


func is_passable(i: int) -> bool:
	return move_cost[i] >= 0


## Highest level anywhere on the map, in quanta. Computed once and kept, since levels do not change
## after generation — the ray picker asks for this on every mouse-motion event.
##
## Anything that mutates `level` after generation must call `invalidate_max_level()`. Only the
## generation stages do, and they all run before anyone can pick a tile.
func max_level() -> int:
	if _max_level == INT_MIN:
		var top: int = 0
		for i: int in n:
			if level[i] > top:
				top = level[i]
		_max_level = top
	return _max_level


func invalidate_max_level() -> void:
	_max_level = INT_MIN


## Whether a road runs across this tile. Replaces the old `terrain[i] == Type.ROAD` test — a road is
## a surface laid on ground, not a kind of ground, so the tile keeps its natural terrain type.
func has_road(i: int) -> bool:
	return road_links[i] != 0


## How many edges the tile's road connects to. 1 is a dead end or a map-edge terminus, 2 is a
## through tile or a turn, 3 or more is a junction.
func road_degree(i: int) -> int:
	var m: int = int(road_links[i])
	var c: int = 0
	while m != 0:
		c += m & 1
		m >>= 1
	return c


func has_road_link(i: int, d: int) -> bool:
	return (int(road_links[i]) >> d) & 1 == 1


## Connect a tile's road to its neighbour in direction `d`, from both sides. Symmetry is maintained
## here rather than checked for later; the mesh builder relies on it to make seams exact.
func link_road(i: int, d: int) -> void:
	road_links[i] = int(road_links[i]) | (1 << d)
	var nb: int = neighbour(i, d)
	if nb >= 0:
		road_links[nb] = int(road_links[nb]) | (1 << Grid.opposite(d))


## Fingerprint of everything that defines the map, for the determinism tests. Not a security hash;
## it needs to be stable across runs and sensitive to any content change.
func content_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(level.to_byte_array())
	ctx.update(terrain)
	ctx.update(trans)
	ctx.update(move_cost.to_byte_array())
	ctx.update(water)
	ctx.update(water_level.to_byte_array())
	ctx.update(moisture.to_byte_array())
	ctx.update(blocker_h.to_byte_array())
	ctx.update(road_links)
	ctx.update(deploy_zone)
	# HashingContext.update rejects an empty buffer, and objectives is empty on a bare MapData.
	if not objectives.is_empty():
		ctx.update(objectives.to_byte_array())
	return ctx.finish().hex_encode()


## Fraction of on-map edges that are impassable escarpment.
##
## The number that keeps the angle of repose honest. Too low and there are no escarpments at all,
## so the connectivity repair in 4.6 is code that never runs and the map has no hard edges to
## manoeuvre around. Too high and the map is a maze of cliffs with a few drivable corridors, which
## is what 220 m of relief at a 40 degree repose produced on the first attempt.
func escarpment_fraction() -> float:
	var blocked: int = 0
	var total: int = 0
	for i: int in n:
		var x: int = i % size
		var y: int = i / size
		for slot: int in 4:
			var d: int = Grid.CANON[slot]
			var nx: int = x + Grid.DX[d]
			var ny: int = y + Grid.DY[d]
			if nx < 0 or nx >= size or ny < 0 or ny >= size:
				continue
			total += 1
			if trans[i * 4 + slot] >= Trans.BLOCKED:
				blocked += 1
	return float(blocked) / float(maxi(total, 1))


## Fraction of tiles a tank can stand on at all.
func passable_fraction() -> float:
	var ok: int = 0
	for i: int in n:
		if move_cost[i] >= 0:
			ok += 1
	return float(ok) / float(maxi(n, 1))


## Tiles making up a deployment zone.
func zone_tiles(zone: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i: int in n:
		if deploy_zone[i] == zone:
			out.append(i)
	return out
