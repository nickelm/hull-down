class_name SettlementPlacer
extends RefCounted

## Stage 4.8, second half — villages and their fields.
##
## Villages used to go wherever the roads had already made a junction, which meant the settlements
## were a consequence of the road network. That is backwards as geography: people settle on good
## ground and then build roads between the places they settled. So the **sites are chosen first**,
## on the ground a village would actually want, and the road network is a spanning tree over them —
## see docs/decisions/0019.
##
## Choosing and stamping are separate calls, and the split is load-bearing. A village flattens its
## footprint to a median height and the road runs straight through the middle of it, so the stamp
## has to happen *after* the road earthworks and be followed by a resmooth. Only the choosing moved
## earlier.
##
## Tactically a village is cover that blocks line of sight and slows movement, sitting on exactly
## the ground both sides want. Fields ring it: open, fast, and completely exposed.

const TAG := "settlements"


## Where the villages will go, chosen before a single road is routed.
##
## Low, flat, dry, drivable ground away from the deployment zones, spread out. The scoring is
## deliberately plain — this decides where the map's landmarks are, and a clever rule here would be
## hard to argue with when a seed puts a village somewhere silly.
static func choose_sites(md: MapData, cfg: Config, master_seed: int) -> PackedInt32Array:
	var want: int = cfg.i("settlements.site_count", 4)
	var min_sep: float = cfg.f("settlements.min_separation_tiles", 25.0)
	var field_r: int = cfg.i("settlements.field_radius_tiles", 4)
	var margin: int = field_r + 2

	# Drawn from the settlements substream, which until now was declared and never used. Its only
	# job is to break ties between equally good ground so the villages are not always in the same
	# corner of the elevation histogram.
	var rng: RandomNumberGenerator = Rng.substream(master_seed, Rng.Stream.TERRAIN, TAG)

	var scored := PackedInt64Array()
	for i: int in md.n:
		var x: int = i % md.size
		var y: int = i / md.size
		if x < margin or y < margin or x >= md.size - margin or y >= md.size - margin:
			continue
		if not md.is_passable(i) or md.deploy_zone[i] != 0:
			continue
		if md.water[i] != MapData.Water.NONE:
			continue
		var t: int = int(md.terrain[i])
		if t == TerrainTyper.Type.ROCK or t == TerrainTyper.Type.MARSH:
			continue
		if TerrainTyper.is_woods(t):
			continue

		# Flat ground, low down, with a nudge so ties do not resolve by tile order.
		var rough: int = 0
		for d: int in 4:
			var nb: int = md.neighbor(i, Grid.CANON[d])
			if nb >= 0:
				rough += absi(md.level[nb] - md.level[i])
		var key: int = clampi(md.level[i] + rough * 8 + rng.randi_range(0, 3), 0, 999999)
		scored.append((key << 21) | i)
	scored.sort()

	var chosen := PackedInt32Array()
	var min_sep2: float = min_sep * min_sep
	for k: int in scored.size():
		if chosen.size() >= want:
			break
		var tile: int = int(scored[k] & 0x1FFFFF)
		var ok: bool = true
		for c: int in chosen.size():
			var dx: float = float(md.tx(tile) - md.tx(chosen[c]))
			var dy: float = float(md.ty(tile) - md.ty(chosen[c]))
			if dx * dx + dy * dy < min_sep2:
				ok = false
				break
		if ok:
			chosen.append(tile)

	return chosen


## Stamp every chosen site. Runs after the road earthworks, and is why `RoadBuilder.resmooth` exists.
static func stamp_all(md: MapData, cfg: Config, sites: PackedInt32Array) -> int:
	var village_r: int = cfg.i("settlements.village_radius_tiles", 2)
	var field_r: int = cfg.i("settlements.field_radius_tiles", 4)
	for k: int in sites.size():
		_stamp(md, cfg, sites[k], village_r, field_r)
	return sites.size()


## A village footprint with a ring of fields around it, flattened to its own median height.
##
## The flattening is what makes a village read as built rather than draped: buildings sit on level
## ground, and the ground beside them is where the earth went.
static func _stamp(md: MapData, cfg: Config, center: int, village_r: int, field_r: int) -> void:
	var size: int = md.size
	var cx: int = md.tx(center)
	var cy: int = md.ty(center)

	# Median rather than mean: one deep river tile inside the footprint would drag a mean down and
	# leave the village in a hole.
	var levels := PackedInt32Array()
	for oy: int in range(maxi(cy - village_r, 0), mini(cy + village_r + 1, size)):
		for ox: int in range(maxi(cx - village_r, 0), mini(cx + village_r + 1, size)):
			var j: int = oy * size + ox
			if md.water[j] == MapData.Water.NONE:
				levels.append(md.level[j])
	if levels.is_empty():
		return
	levels.sort()
	var median: int = levels[levels.size() / 2]

	var touched := PackedInt32Array()
	for oy2: int in range(maxi(cy - field_r, 0), mini(cy + field_r + 1, size)):
		for ox2: int in range(maxi(cx - field_r, 0), mini(cx + field_r + 1, size)):
			var dx: float = float(ox2 - cx)
			var dy: float = float(oy2 - cy)
			var dist: float = sqrt(dx * dx + dy * dy)
			if dist > float(field_r):
				continue
			var j2: int = oy2 * size + ox2

			# Water, fords and bridges are left exactly as they are — a village does not fill in
			# the river it was built beside.
			if md.water[j2] != MapData.Water.NONE:
				continue
			# A road tile takes the village's terrain and level like any other. The road itself
			# lives in the link mask, not in the terrain type, so it rides over the village rather
			# than being erased by it — and `apply_terrain_attributes` gives it back the road's
			# going and clears the village's cover.
			if dist <= float(village_r):
				md.level[j2] = median
				md.terrain[j2] = TerrainTyper.Type.VILLAGE
			else:
				# Fields ease from the village's level back to the natural ground.
				var t: float = (dist - float(village_r)) / float(maxi(field_r - village_r, 1))
				md.level[j2] = int(round(lerpf(float(median), float(md.level[j2]), t)))
				if md.terrain[j2] != TerrainTyper.Type.VILLAGE:
					md.terrain[j2] = TerrainTyper.Type.FIELD
			touched.append(j2)

	TerrainTyper.apply_terrain_attributes(md, cfg)
	for k: int in touched.size():
		Quantizer.reclassify_around(md, touched[k], cfg)
