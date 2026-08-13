class_name Armor
extends RefCounted

## Which plate a shot strikes, and how thick it still is — docs/decisions/0004 and 0029.
##
## Five facings, as 0004 and `docs/design/rules.md` §4 have said since they were written. `TOP` exists
## in the data and is never struck by direct fire in iteration 2; there is deliberately no code path
## that produces it, because a branch that cannot execute is worse than a missing one.

enum Facing { FRONT = 0, LEFT = 1, RIGHT = 2, REAR = 3, TOP = 4 }

## The key each facing is stored under in `data/units.json`, parallel to the enum.
const KEYS: Array[String] = ["front", "left", "right", "rear", "top"]

## Facing struck, by the bearing of the shooter **relative to the target's hull**:
## `rel = posmod(bearing - hull, 8)`.
##
##     rel 7, 0, 1  ->  front      three eighths of the circle
##     rel 2, 3     ->  right      two eighths
##     rel 5, 6     ->  left       two eighths
##     rel 4        ->  rear       one eighth
##
## The split is not even, and that is the rule rather than a rounding artifact. Getting *directly*
## behind a tank is worth strictly more than reaching a rear quarter, which is the geometry that makes
## 0004's "position is the primary damage multiplier" true rather than approximately true.
##
## `static var` because a `PackedInt32Array` is not a constant expression in GDScript. Read-only.
static var FACING_BY_REL := PackedInt32Array([
	Facing.FRONT, Facing.FRONT, Facing.RIGHT, Facing.RIGHT,
	Facing.REAR, Facing.LEFT, Facing.LEFT, Facing.FRONT,
])

## 169/408 approximates tan(22.5 degrees) = sqrt(2) - 1 to within a millionth.
##
## A structural constant of the same class as `Grid.DX`, not a tunable — it is the octant boundary
## and there is nothing to tune about it. Integer, because docs/decisions/0010 records that float
## determinism is not promised across engine versions and the boundary cases genuinely occur: at
## dx=12, dy=5 the true angle is 22.6 degrees, a tenth of a degree off the line.
const OCTANT_NUM: int = 169
const OCTANT_DEN: int = 408


## The compass direction from one tile to another, quantized to eight octants by **angle**.
##
## Not `Grid.dir_between`, and the difference is a rules bug waiting to happen. `dir_between` uses
## `signi(dx)`, which means "one unit step in that direction" — correct for movement, where the answer
## has to be a legal edge. For armor it is wrong: a shot from ten tiles east and one tile north snaps
## to NE, and strikes the front-right plate of a tank being shot squarely in the side.
##
## Returns -1 for the same tile.
static func bearing(md: MapData, from_tile: int, to_tile: int) -> int:
	var dx: int = md.tx(to_tile) - md.tx(from_tile)
	var dy: int = md.ty(to_tile) - md.ty(from_tile)
	if dx == 0 and dy == 0:
		return -1

	var adx: int = absi(dx)
	var ady: int = absi(dy)

	# Within 22.5 degrees of the horizontal: east or west outright.
	if ady * OCTANT_DEN <= adx * OCTANT_NUM:
		return Grid.E if dx > 0 else Grid.W
	# Within 22.5 degrees of the vertical. +Y is south — the grid's rows run downwards.
	if adx * OCTANT_DEN <= ady * OCTANT_NUM:
		return Grid.S if dy > 0 else Grid.N

	if dx > 0:
		return Grid.SE if dy > 0 else Grid.NE
	return Grid.SW if dy > 0 else Grid.NW


## The plate a shot coming from `bearing_to_shooter` lands on, for a hull pointing `hull_facing`.
static func facing_struck(hull_facing: int, bearing_to_shooter: int) -> int:
	if bearing_to_shooter < 0:
		return Facing.FRONT
	return FACING_BY_REL[posmod(bearing_to_shooter - hull_facing, 8)]


## Nominal thickness from the roster, before anything has been shot off it.
static func base_mm(cfg: Config, unit_type: StringName, facing: int) -> int:
	if facing < 0 or facing >= KEYS.size():
		return 0
	var plate: Dictionary = cfg.unit(String(unit_type)).get("armor", {})
	return int(plate.get(KEYS[facing], 0))


## Thickness now, after everything that has been shot off it. Never negative: a plate shredded to
## nothing is paper, not a hole that penetrates itself.
static func current_mm(cfg: Config, u: UnitState, facing: int) -> int:
	if u == null or facing < 0 or facing >= u.shred_mm.size():
		return 0
	return maxi(base_mm(cfg, u.unit_type, facing) - u.shred_mm[facing], 0)


## Take millimeters off a plate, permanently. Armor never regenerates — 0004 — so this only ever
## adds, and `current_mm` only ever falls.
##
## Called through `EventApplier` and nowhere else, because it is one of the two genuinely
## non-idempotent mutations in the game and the guard against applying it twice is
## `ActionResult.committed`.
static func shred(cfg: Config, u: UnitState, facing: int, mm: int) -> void:
	if u == null or facing < 0 or facing >= u.shred_mm.size() or mm <= 0:
		return
	u.shred_mm[facing] = mini(u.shred_mm[facing] + mm, base_mm(cfg, u.unit_type, facing))


## Total millimeters this unit has lost, across every facing. The card's condition line, and the
## cheap answer to "has this tank been in a fight".
static func total_shred(u: UnitState) -> int:
	var total: int = 0
	for k: int in u.shred_mm.size():
		total += u.shred_mm[k]
	return total
