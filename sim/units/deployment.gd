class_name Deployment
extends RefCounted

## Putting units on the board at the start of a match.
##
## Deliberately dumb, and deterministic without touching the RNG: walk each deployment zone in tile
## order and take passable tiles that are far enough apart to be distinguishable. Unit composition
## and anything tactical about where a side sets up are iteration 2 problems — guessing at them now
## would be work thrown away, and a fixed rule is one less thing between a change and seeing it.


static func deploy(md: MapData, cfg: Config, per_side: int = -1) -> MatchState:
	var sides: int = maxi(cfg.i("turn.sides", 2), 1)
	var count: int = per_side if per_side > 0 else maxi(cfg.i("turn.units_per_side", 2), 1)
	var spacing: int = maxi(cfg.i("turn.unit_spacing_tiles", 6), 1)
	var type_name: String = cfg.default_unit_name()

	var m: MatchState = MatchState.create(sides)

	for side: int in range(1, sides + 1):
		var starts: PackedInt32Array = start_tiles(md, side, count, spacing)
		for k: int in starts.size():
			var u: UnitState = UnitState.create(md, cfg, starts[k], type_name)
			u.side = side
			u.facing = _facing_across_map(md, starts[k])
			m.add_unit(u)

	var first: PackedInt32Array = m.side_units(m.active_side)
	if not first.is_empty():
		m.selected = first[0]
	return m


## Up to `count` passable tiles in a deployment zone, each at least `spacing` tiles from the ones
## already chosen.
##
## Falls back twice: first by relaxing the spacing, then by taking any passable tile on the map.
## A zone can be small, split across components, or mostly impassable, and a match that fails to
## deploy is worse than one whose units start closer together than intended.
static func start_tiles(md: MapData, zone: int, count: int, spacing: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var zone_tiles: PackedInt32Array = md.zone_tiles(zone)

	var gap: int = spacing
	while gap >= 0 and out.size() < count:
		for k: int in zone_tiles.size():
			if out.size() >= count:
				break
			var t: int = zone_tiles[k]
			if not md.is_passable(t) or out.has(t):
				continue
			if _too_close(md, out, t, gap):
				continue
			out.append(t)
		gap -= 2

	for i: int in md.n:
		if out.size() >= count:
			break
		if md.is_passable(i) and not out.has(i):
			out.append(i)

	return out


static func _too_close(md: MapData, chosen: PackedInt32Array, tile: int, gap: int) -> bool:
	var x: int = md.tx(tile)
	var y: int = md.ty(tile)
	for k: int in chosen.size():
		var dx: int = absi(md.tx(chosen[k]) - x)
		var dy: int = absi(md.ty(chosen[k]) - y)
		if maxi(dx, dy) < gap:
			return true
	return false


## Point at the middle of the map, so the first thing the visibility overlay shows is the ground the
## unit would actually be fighting across.
static func _facing_across_map(md: MapData, tile: int) -> int:
	var f: int = Grid.dir_between(md.tx(tile), md.ty(tile), md.size / 2, md.size / 2)
	return f if f >= 0 else Grid.E
