class_name TilePicker
extends RefCounted

## Which tile is under the mouse.
##
## Marched analytically against the heightfield rather than raycast against physics bodies. Forty
## thousand collision shapes would cost memory and build time for a query that is a dozen array
## reads — and the terraced heightfield is a function, so the ray can simply be walked until it
## drops below the ground.


## Returns the tile under the screen position, or -1 if the ray misses the map.
static func pick(md: MapData, camera: Camera3D, screen_pos: Vector2) -> int:
	var origin: Vector3 = camera.project_ray_origin(screen_pos)
	var dir: Vector3 = camera.project_ray_normal(screen_pos)
	return pick_ray(md, origin, dir)


static func pick_ray(md: MapData, origin: Vector3, dir: Vector3) -> int:
	var extent: float = float(md.size) * md.tile_m

	# Skip the empty air above the map: jump straight to where the ray crosses the highest ground.
	# Cached on the map rather than rescanned — this runs once per mouse-motion event, and scanning
	# forty thousand tiles for a number that cannot change after generation is forty thousand array
	# reads per pixel of mouse travel.
	var top: float = float(md.max_level()) * md.quant

	var t: float = 0.0
	if origin.y > top and dir.y < -0.0001:
		t = (top - origin.y) / dir.y

	# Step in half-tiles. Finer than a tile so the first tile is never skipped on a shallow ray,
	# coarse enough that a two-kilometer ray is a few hundred samples.
	var step: float = md.tile_m * 0.5
	var max_t: float = t + extent * 3.0

	while t < max_t:
		var p: Vector3 = origin + dir * t
		if p.x < 0.0 or p.x >= extent or p.z < 0.0 or p.z >= extent:
			# Outside the map: keep going only while the ray could still come back over it.
			if (p.x < 0.0 and dir.x <= 0.0) or (p.x >= extent and dir.x >= 0.0):
				return -1
			if (p.z < 0.0 and dir.z <= 0.0) or (p.z >= extent and dir.z >= 0.0):
				return -1
			t += step
			continue

		var tile: int = int(p.z / md.tile_m) * md.size + int(p.x / md.tile_m)
		if p.y <= float(md.level[tile]) * md.quant:
			return tile
		t += step

	return -1
