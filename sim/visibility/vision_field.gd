class_name VisionField
extends RefCounted

## Exposure of every tile around an observer, for the overlay.
##
## The obvious implementation — cast a ray at each tile in range — is about twenty thousand rays of
## sixty samples each, two million samples, one to three seconds. Unusable for something that has
## to repaint whenever the selected tank moves.
##
## Instead: **one radial sweep**. Cast a ray per unit of circumference, and march it outward
## carrying a running maximum of the elevation angle of everything it has passed. Each tile is
## classified as the ray reaches it, from that one number:
##
##   turret angle below the running max      -> masked
##   turret above, hull below                -> hull down
##   both above                              -> exposed
##
## All three states fall out of a single traversal, and the cost is proportional to the *perimeter*
## times the radius rather than the area times the radius — roughly forty thousand samples, ten
## milliseconds, two orders of magnitude better.
##
## The running maximum is updated *after* the tile is classified. A tile is not hidden by the cover
## standing on it; it is hidden by what lies between it and the observer.


## Fills `out` with one Los.Exposure per tile. The caller owns the buffer so a repeated call does
## not allocate 40 kB every time the selection moves.
static func compute(
	md: MapData, cfg: Config, observer_tile: int, out: PackedByteArray, max_range_tiles: int = -1
) -> void:
	if out.size() != md.n:
		out.resize(md.n)
	out.fill(Los.Exposure.MASKED)

	var hull_h: float = cfg.f("visibility.hull_h_m", 1.4)
	var turret_h: float = cfg.f("visibility.turret_h_m", 2.6)
	var density: float = cfg.f("visibility.ray_density", 1.25)
	var radius: int = max_range_tiles if max_range_tiles > 0 else cfg.i("visibility.max_range_tiles", 90)

	var eye: float = md.height_m(observer_tile) + turret_h
	var ox: float = float(md.tx(observer_tile)) + 0.5
	var oy: float = float(md.ty(observer_tile)) + 0.5
	var tile_m: float = md.tile_m
	var size: int = md.size

	out[observer_tile] = Los.Exposure.EXPOSED

	# One ray per unit of circumference at the outer radius means every tile out there is hit by at
	# least one; tiles closer in are hit by several, and the most permissive result wins.
	var rays: int = maxi(int(ceil(TAU * float(radius) * density)), 8)
	var step: float = TAU / float(rays)

	for r: int in rays:
		var a: float = float(r) * step
		var dx: float = cos(a)
		var dy: float = sin(a)
		var max_angle: float = -INF
		var last_tile: int = observer_tile

		for s: int in range(1, radius + 1):
			var fx: float = ox + dx * float(s)
			var fy: float = oy + dy * float(s)
			var x: int = int(fx)
			var y: int = int(fy)
			if x < 0 or x >= size or y < 0 or y >= size:
				break
			var tile: int = y * size + x
			if tile == last_tile:
				continue
			last_tile = tile

			# Horizontal distance. Using the slant distance instead would make angles from
			# different heights incomparable, which is the whole basis of the sweep.
			var d: float = sqrt((fx - ox) * (fx - ox) + (fy - oy) * (fy - oy)) * tile_m
			if d < 0.001:
				continue

			var ground: float = md.height_m(tile)
			var e: int = Los.Exposure.MASKED
			if (ground + turret_h - eye) / d > max_angle:
				e = (
					Los.Exposure.EXPOSED
					if (ground + hull_h - eye) / d > max_angle
					else Los.Exposure.HULL_DOWN
				)
			if e > out[tile]:
				out[tile] = e

			var blocker: float = (md.blocker_top_m(tile) - eye) / d
			if blocker > max_angle:
				max_angle = blocker


## Translate an exposure buffer into overlay channel bytes.
static func to_channel(exposure: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(exposure.size())
	for i: int in exposure.size():
		out[i] = Los.CHANNEL_VALUE[exposure[i]]
	return out


## Tiles that are hull-down positions *against* a given observer: places a tank could sit where its
## turret would see out but its hull would be masked.
static func hull_down_count(exposure: PackedByteArray) -> int:
	var count: int = 0
	for i: int in exposure.size():
		if exposure[i] == Los.Exposure.HULL_DOWN:
			count += 1
	return count
