class_name SettlementPlacer
extends RefCounted

## Stage 4.8, second half — villages and their fields.
##
## Villages go where people would put them: at road junctions, and at river crossings. Both are
## already on the map by the time this runs, so nothing here decides where a settlement "should"
## be — it reads where the roads and the water already made one inevitable.
##
## Tactically a village is cover that blocks line of sight and slows movement, sitting on exactly
## the ground both sides want. Fields ring it: open, fast, and completely exposed.

const TAG := "settlements"


static func place(md: MapData, roads: Array, cfg: Config, master_seed: int) -> int:
	var max_villages: int = cfg.i("settlements.max_villages", 4)
	var village_r: int = cfg.i("settlements.village_radius_tiles", 2)
	var field_r: int = cfg.i("settlements.field_radius_tiles", 4)
	var min_sep: float = cfg.f("settlements.min_separation_tiles", 25.0)
	var min_sep2: float = min_sep * min_sep

	var candidates: PackedInt32Array = _candidates(md, roads, cfg)
	var placed := PackedInt32Array()

	for k: int in candidates.size():
		if placed.size() >= max_villages:
			break
		var c: int = candidates[k]
		var ok: bool = true
		for p: int in placed.size():
			var dx: float = float(md.tx(c) - md.tx(placed[p]))
			var dy: float = float(md.ty(c) - md.ty(placed[p]))
			if dx * dx + dy * dy < min_sep2:
				ok = false
				break
		if not ok:
			continue
		_stamp(md, cfg, c, village_r, field_r)
		placed.append(c)

	return placed.size()


## Junctions first, then crossings. A tile where three or more roads meet is a junction; a road
## tile adjacent to a bridge or a ford is a crossing.
static func _candidates(md: MapData, roads: Array, cfg: Config) -> PackedInt32Array:
	var min_degree: int = cfg.i("settlements.min_junction_degree", 3)

	# How many edges each road tile connects to. Two means a through road or a turn, three or more
	# means the roads branch here. Read straight off the link mask, which counts road *connections*
	# rather than road *neighbours* — two roads running side by side are adjacent without meeting.
	var junctions := PackedInt32Array()
	var crossings := PackedInt32Array()
	for i2: int in md.n:
		if not md.has_road(i2) or not md.is_passable(i2):
			continue
		if md.road_degree(i2) >= min_degree:
			junctions.append(i2)
			continue
		for d2: int in 8:
			var nb3: int = md.neighbour(i2, d2)
			if nb3 < 0:
				continue
			var w: int = int(md.water[nb3])
			if w == MapData.Water.BRIDGE or w == MapData.Water.FORD:
				crossings.append(i2)
				break

	var out := PackedInt32Array()
	out.append_array(junctions)
	out.append_array(crossings)

	# If a map has neither — two parallel roads and no crossing — fall back to the midpoint of the
	# longest road, so every map still has somewhere to fight over.
	if out.is_empty() and roads.size() > 0:
		var longest: RoadBuilder.Road = roads[0]
		for r: int in roads.size():
			var road: RoadBuilder.Road = roads[r]
			if road.length() > longest.length():
				longest = road
		if longest.length() > 0:
			out.append(longest.tiles[longest.length() / 2])

	return out


## A village footprint with a ring of fields around it, flattened to its own median height.
##
## The flattening is what makes a village read as built rather than draped: buildings sit on level
## ground, and the ground beside them is where the earth went.
static func _stamp(md: MapData, cfg: Config, centre: int, village_r: int, field_r: int) -> void:
	var size: int = md.size
	var cx: int = md.tx(centre)
	var cy: int = md.ty(centre)

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
