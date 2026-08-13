class_name Grid
extends RefCounted

## Static geometry for the 200x200 gameplay grid. No state, no allocation.
##
## Directions and facings share one numbering, 0..7 clockwise from north. A tank's facing is a
## direction; a step is a direction; a turn is the difference between two directions. Keeping them
## the same type is what lets the pathfinder pack (tile, facing) into one integer.
##
##        7  0  1
##         \ | /
##       6 - + - 2        +X is east, +Z is south (Godot's -Z is north)
##         / | \
##        5  4  3

const SIZE: int = 200
const COUNT: int = SIZE * SIZE
const TILE_M: float = 10.0
const QUANT: float = 0.5

const N: int = 0
const NE: int = 1
const E: int = 2
const SE: int = 3
const S: int = 4
const SW: int = 5
const W: int = 6
const NW: int = 7

# Treat every table below as const. They are `static var` only because GDScript cannot evaluate a
# PackedInt32Array constructor at compile time, and Packed arrays are what the hot loops need —
# an Array[int] would box each element as a Variant. Never write to them.
static var DX := PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])
static var DY := PackedInt32Array([-1, -1, 0, 1, 1, 1, 0, -1])
static var IS_DIAG := PackedByteArray([0, 1, 0, 1, 0, 1, 0, 1])

## The four directions in which transitions are stored canonically (E, SE, S, SW). The reverse of
## each is read from the neighbor tile instead of being stored twice, which makes edge symmetry
## structural rather than something to test for.
static var CANON := PackedInt32Array([E, SE, S, SW])

## Where each direction sits in CANON, or -1 if it is a reverse direction.
static var CANON_SLOT := PackedInt32Array([-1, -1, 0, 1, 2, 3, -1, -1])


static func idx(x: int, y: int) -> int:
	return y * SIZE + x


static func tx(i: int) -> int:
	return i % SIZE


static func ty(i: int) -> int:
	return i / SIZE


static func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < SIZE and y >= 0 and y < SIZE


## Neighbor tile index in direction d, or -1 if it would leave the map.
static func neighbor(i: int, d: int) -> int:
	var x: int = (i % SIZE) + DX[d]
	var y: int = (i / SIZE) + DY[d]
	if x < 0 or x >= SIZE or y < 0 or y >= SIZE:
		return -1
	return y * SIZE + x


static func opposite(d: int) -> int:
	return (d + 4) & 7


## Number of 45-degree steps between two facings, 0..4. Symmetric.
static func turn_steps(from_facing: int, to_facing: int) -> int:
	var d: int = absi(to_facing - from_facing)
	return mini(d, 8 - d)


## Octile distance in movement cost units (orthogonal 10, diagonal 14).
##
## This is the A* heuristic. It ignores terrain and turning, which is what keeps it admissible;
## see docs/decisions/0008 for why turn-cost lower bounds are deliberately not added.
static func octile(ax: int, ay: int, bx: int, by: int) -> int:
	var dx: int = absi(ax - bx)
	var dy: int = absi(ay - by)
	return 10 * maxi(dx, dy) + 4 * mini(dx, dy)


## The direction from one tile toward another, snapped to the nearest of the eight.
static func dir_between(ax: int, ay: int, bx: int, by: int) -> int:
	var dx: int = signi(bx - ax)
	var dy: int = signi(by - ay)
	for d: int in 8:
		if DX[d] == dx and DY[d] == dy:
			return d
	return -1


## Euclidean distance in meters between two tile centers.
static func dist_m(a: int, b: int) -> float:
	var dx: float = float((a % SIZE) - (b % SIZE)) * TILE_M
	var dy: float = float((a / SIZE) - (b / SIZE)) * TILE_M
	return sqrt(dx * dx + dy * dy)


## World-space center of a tile at a given quantized level. Godot is Y-up; the grid's Y axis maps
## to world Z, so tile (0,0) sits at the world origin corner and +Y on the grid runs south.
static func center_world(i: int, level: int) -> Vector3:
	return Vector3(
		(float(i % SIZE) + 0.5) * TILE_M,
		float(level) * QUANT,
		(float(i / SIZE) + 0.5) * TILE_M
	)
