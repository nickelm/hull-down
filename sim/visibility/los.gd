class_name Los
extends RefCounted

## Line of sight, and the three exposure states the game is named after.
##
## The observer looks from turret height. A target is **exposed** if both its hull and its turret
## can be seen, **hull down** if the turret is visible but the hull is masked by ground in between,
## and **masked** if neither is. Hull down is the state worth fighting for: you can shoot and be
## shot at only through the turret, which is the smallest and thickest part of the tank.
##
## Heights are sampled from the tile's own quantized level, not interpolated between tiles. The
## terrain is piecewise constant — that is what the mesh draws and what the player reads off a
## crest — so interpolating here would make the rules disagree with the picture, which is exactly
## the mismatch the gunner view in 4.14 exists to expose.

enum Exposure { MASKED = 0, HULL_DOWN = 1, EXPOSED = 2 }

## What the overlay writes into the exposure channel for each state. Read-only; `static var` only
## because a PackedByteArray is not a constant expression in GDScript.
static var CHANNEL_VALUE := PackedByteArray([0, 128, 255])


## Exposure of `to` as seen from `from`. The authoritative single-pair test; VisionField does the
## same thing in bulk for the interactive overlay.
static func classify(md: MapData, cfg: Config, from_tile: int, to_tile: int) -> int:
	if from_tile == to_tile:
		return Exposure.EXPOSED

	var hull_h: float = cfg.f("visibility.hull_h_m", 1.4)
	var turret_h: float = cfg.f("visibility.turret_h_m", 2.6)
	var eye: float = md.height_m(from_tile) + turret_h

	var ax: int = md.tx(from_tile)
	var ay: int = md.ty(from_tile)
	var bx: int = md.tx(to_tile)
	var by: int = md.ty(to_tile)

	var steps: int = maxi(absi(bx - ax), absi(by - ay))
	var inv_steps: float = 1.0 / float(steps)
	var dist_m: float = md.tile_m * sqrt(
		float((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
	)

	# Running maximum elevation angle of everything already passed. A target has to rise above this
	# to be seen at all.
	var max_angle: float = -INF
	var last: int = from_tile

	for s: int in range(1, steps):
		var t: float = float(s) * inv_steps
		var x: int = int(round(float(ax) + float(bx - ax) * t))
		var y: int = int(round(float(ay) + float(by - ay) * t))
		var tile: int = y * md.size + x
		if tile == last:
			continue
		last = tile

		var d: float = dist_m * t
		if d < 0.001:
			continue
		var angle: float = (md.blocker_top_m(tile) - eye) / d
		if angle > max_angle:
			max_angle = angle

	# The target's own cover does not hide it from itself, so the target tile is measured by its
	# ground level rather than by what stands on it.
	var ground: float = md.height_m(to_tile)
	var a_turret: float = (ground + turret_h - eye) / dist_m
	var a_hull: float = (ground + hull_h - eye) / dist_m

	if a_turret <= max_angle:
		return Exposure.MASKED
	return Exposure.EXPOSED if a_hull > max_angle else Exposure.HULL_DOWN


static func has_los(md: MapData, cfg: Config, from_tile: int, to_tile: int) -> bool:
	return classify(md, cfg, from_tile, to_tile) != Exposure.MASKED


## How far the view runs from a tile in one direction before something blocks it, in metres.
##
## This is what the sightline metric measures. Marching a ray until it is blocked answers "how far
## can you see from here", which is a property of the terrain; measuring the distance between
## random visible pairs answers "how big is the map", which is not.
static func clear_range(
	md: MapData, cfg: Config, from_tile: int, dir: int, max_tiles: int
) -> float:
	var turret_h: float = cfg.f("visibility.turret_h_m", 2.6)
	var eye: float = md.height_m(from_tile) + turret_h

	var x: int = md.tx(from_tile)
	var y: int = md.ty(from_tile)
	var dx: int = Grid.DX[dir]
	var dy: int = Grid.DY[dir]
	var step_m: float = md.tile_m * (sqrt(2.0) if Grid.IS_DIAG[dir] == 1 else 1.0)

	var max_angle: float = -INF
	var reached: float = 0.0

	for s: int in range(1, max_tiles + 1):
		x += dx
		y += dy
		if x < 0 or x >= md.size or y < 0 or y >= md.size:
			break
		var tile: int = y * md.size + x
		var d: float = float(s) * step_m

		# A target standing here would be seen if its turret clears everything so far.
		var a_turret: float = (md.height_m(tile) + turret_h - eye) / d
		if a_turret <= max_angle:
			break
		reached = d

		var angle: float = (md.blocker_top_m(tile) - eye) / d
		if angle > max_angle:
			max_angle = angle

	return reached
