class_name WaterMeshBuilder
extends RefCounted

## Water surfaces, as one quad per wet tile at that tile's own surface level.
##
## The spec says "water plane for rivers", and a single plane cannot work: a river descends tens of
## meters between where it enters the map and where it leaves, so one plane either floods the
## lowlands or hangs above the uplands. Per-tile quads step down with the river, exactly like the
## terraced ground beneath them, which is also the only version that agrees with what the LOS code
## thinks the terrain is.
##
## Bridges are excluded — a bridge tile carries a road deck, and drawing water over the deck would
## put a river on top of the crossing.


static func build(md: MapData) -> ArrayMesh:
	# Rivers and fords only.
	#
	# A stream tile is wet ground, not open water — it is typed as marsh and a tank drives through
	# it. Drawing a water surface over it says the opposite, and since the drainage network reaches
	# nearly everywhere it also covered most of the terrain with quads, hiding the ground the
	# player is supposed to be reading.
	var wet := PackedInt32Array()
	for i: int in md.n:
		var w: int = int(md.water[i])
		if w == MapData.Water.RIVER or w == MapData.Water.FORD:
			wet.append(i)
	if wet.is_empty():
		return null

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(wet.size() * 6)
	norms.resize(wet.size() * 6)

	var tile_m: float = md.tile_m
	var quant: float = md.quant
	var cur: int = 0

	for k: int in wet.size():
		var i2: int = wet[k]
		# A hair above the recorded surface, so it never z-fights the river bed it sits in.
		var y: float = float(md.water_level[i2]) * quant + 0.03
		var x0: float = float(md.tx(i2)) * tile_m
		var z0: float = float(md.ty(i2)) * tile_m
		var x1: float = x0 + tile_m
		var z1: float = z0 + tile_m

		verts[cur] = Vector3(x0, y, z1)
		verts[cur + 1] = Vector3(x1, y, z1)
		verts[cur + 2] = Vector3(x1, y, z0)
		verts[cur + 3] = Vector3(x0, y, z1)
		verts[cur + 4] = Vector3(x1, y, z0)
		verts[cur + 5] = Vector3(x0, y, z0)
		for j: int in 6:
			norms[cur + j] = Vector3.UP
		cur += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
