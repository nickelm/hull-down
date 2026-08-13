class_name ScatterBuilder
extends RefCounted

## Trees on the woods and buildings in the villages.
##
## The point is not decoration. `terrain.json` says a woods tile carries 8 m of line-of-sight cover
## and a village 6 m, and `Los` marches against exactly that — so before this existed the model was
## asserting cover the player had no way to see. A ridge that reads as clear ground while the
## visibility overlay calls it masked is the overlay's fault as far as anyone playing can tell.
##
## Heights therefore come from `blocker_h`, never from a literal here. What is on screen is what the
## rules use, which is the same contract the terraced mesh keeps with the movement rules.
##
## One `MultiMesh` per terrain chunk, matching `TerrainMeshBuilder.CHUNK`. A single map-wide
## instance would have one two-kilometer bounding box and would never be frustum-culled.

const CHUNK := TerrainMeshBuilder.CHUNK

enum Kind { TREE = 0, BUILDING = 1 }


## Placement only — no `RenderingServer`, no nodes, so the rules are testable headless.
##
## Returns one entry per (chunk, kind) that has anything in it:
##   {"kind": int, "cx": int, "cy": int, "xforms": Array[Transform3D]}
static func place(md: MapData, cfg: Config) -> Array:
	var per_tile: int = maxi(cfg.i("look.scatter.trees_per_woods_tile", 3), 0)
	var inset: float = clampf(cfg.f("look.scatter.inset_frac", 0.14), 0.0, 0.45)
	var jitter: float = clampf(cfg.f("look.scatter.scale_jitter", 0.10), 0.0, 0.5)

	var building_h: float = cfg.terrain_blocker_h[TerrainTyper.Type.VILLAGE]

	var chunks: int = int(ceil(float(md.size) / float(CHUNK)))
	var out: Array = []

	for cy: int in chunks:
		for cx: int in chunks:
			var trees: Array[Transform3D] = []
			var buildings: Array[Transform3D] = []

			var x1: int = mini(cx * CHUNK + CHUNK, md.size)
			var y1: int = mini(cy * CHUNK + CHUNK, md.size)
			for y: int in range(cy * CHUNK, y1):
				for x: int in range(cx * CHUNK, x1):
					var i: int = y * md.size + x
					# A road cuts through the forest, and a bridge deck is not a building site.
					if md.has_road(i) or md.water[i] != MapData.Water.NONE:
						continue

					var t: int = int(md.terrain[i])
					if t == TerrainTyper.Type.VILLAGE:
						buildings.append(_one(md, i, 0, inset, jitter, building_h, true))
					elif TerrainTyper.is_woods(t):
						# Height per tier, straight from the tile's own blocker. Splitting woods
						# into tiers and leaving this matching WOODS exactly would have given the
						# new tiers no scatter at all, silently — light woods would read as open
						# ground while Los kept marching against its cover, which is precisely the
						# defect the note at the top of this file is about.
						var h: float = cfg.terrain_blocker_h[t]
						for j: int in per_tile:
							trees.append(_one(md, i, j, inset, jitter, h, false))

			if not trees.is_empty():
				out.append({"kind": Kind.TREE, "cx": cx, "cy": cy, "xforms": trees})
			if not buildings.is_empty():
				out.append({"kind": Kind.BUILDING, "cx": cx, "cy": cy, "xforms": buildings})

	return out


## One instance's transform, derived entirely from the tile index and the instance number.
##
## `Rng.fnv1a` rather than `randi()`: the same map has to scatter identically in the editor, in a
## rebuild, and under `tools/screenshot.gd`, or a screenshot diff is noise. Independent bit ranges
## of one hash give the three independent values, the same trick `Palette.jitter` uses.
static func _one(
	md: MapData, tile: int, index: int, inset: float, jitter: float, height: float, snap_yaw: bool
) -> Transform3D:
	var h: int = Rng.fnv1a("scatter%d_%d" % [tile, index])
	var u: float = float((h >> 4) & 0xFFFF) / 65535.0
	var v: float = float((h >> 20) & 0xFFFF) / 65535.0
	var w: float = float((h >> 36) & 0xFFFF) / 65535.0
	var yaw_bits: float = float((h >> 52) & 0x7FF) / 2047.0

	# Kept away from the tile edge so a trunk never straddles a terrace step.
	var span: float = 1.0 - inset * 2.0
	var px: float = (float(md.tx(tile)) + inset + u * span) * md.tile_m
	var pz: float = (float(md.ty(tile)) + inset + v * span) * md.tile_m
	var py: float = float(md.level[tile]) * md.quant

	# A village reads as built rather than strewn if its walls line up, so buildings snap to one of
	# eight headings and trees do not.
	var yaw: float = (
		floor(yaw_bits * 8.0) * (TAU / 8.0) if snap_yaw else yaw_bits * TAU
	)

	# Cosmetic only. Occlusion is one flat blocker height per tile, and letting this look like
	# per-tree occlusion would be a lie about the rules.
	var scale: float = height * (1.0 + (w - 0.5) * 2.0 * jitter)

	var b := Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale))
	return Transform3D(b, Vector3(px, py, pz))


## Wrap the placement into nodes. Meshes are built once and shared by every chunk.
static func build(md: MapData, cfg: Config, palette: Palette) -> Array:
	var groups: Array = place(md, cfg)
	if groups.is_empty():
		return []

	var meshes: Array[ArrayMesh] = [tree_mesh(cfg), building_mesh(cfg)]
	var shadows: bool = cfg.b("look.scatter.tree_shadows", false)
	var range_end: float = cfg.f("look.scatter.visible_range_m", 900.0)

	var out: Array = []
	for g: Dictionary in groups:
		var kind: int = int(g["kind"])
		var xforms: Array = g["xforms"]

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[kind]
		mm.instance_count = xforms.size()
		for k: int in xforms.size():
			mm.set_instance_transform(k, xforms[k])

		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.name = "%s_%d_%d" % [
			"Trees" if kind == Kind.TREE else "Buildings", int(g["cx"]), int(g["cy"])
		]
		# Twenty thousand shadow casters against a 900 m shadow distance costs far more than the
		# triangles do, and the flat woods tint already reads as forest from altitude.
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		if range_end > 0.0:
			mi.visibility_range_end = range_end
		out.append(mi)

	return out


## A unit-height tree: hexagonal trunk, hexagonal cone canopy. Scaled to the blocker height by the
## instance transform, so the mesh itself is dimensionless.
static func tree_mesh(cfg: Config) -> ArrayMesh:
	var trunk_frac: float = clampf(cfg.f("look.scatter.trunk_frac", 0.28), 0.05, 0.9)
	var canopy_r: float = cfg.f("look.scatter.canopy_radius_m", 2.3)
	# The ordinary tier is the reference height. One mesh serves all three: the instance transform
	# scales it uniformly by each tile's own blocker, so a light stand comes out both shorter and
	# proportionally narrower, which is what distinguishes brush from timber on screen. Authoring a
	# separate mesh per tier would put the canopy radius in two places and let them disagree.
	var tree_h: float = maxf(cfg.terrain_blocker_h[TerrainTyper.Type.WOODS], 0.001)
	# Radii are authored in meters but the mesh is unit-height, so they divide out by the height the
	# instance transform will scale by.
	var r: float = canopy_r / tree_h

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()

	var trunk: Color = cfg.color("look.scatter.trunk_color", Color(0.29, 0.23, 0.17))
	var canopy: Color = cfg.color("look.scatter.canopy_color", Color(0.20, 0.27, 0.16))
	_prism(verts, norms, cols, 6, r * 0.22, 0.0, trunk_frac, trunk.srgb_to_linear())
	_cone(verts, norms, cols, 6, r, trunk_frac, 1.0, canopy.srgb_to_linear())

	return _finish(verts, norms, cols)


## A unit-height building: a box with a shallow prism roof.
static func building_mesh(cfg: Config) -> ArrayMesh:
	var h: float = maxf(cfg.terrain_blocker_h[TerrainTyper.Type.VILLAGE], 0.001)
	var w: float = cfg.f("look.scatter.building_w_m", 6.0) / h
	var d: float = cfg.f("look.scatter.building_d_m", 7.0) / h

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()

	var wall: Color = cfg.color("look.scatter.building_color", Color(0.60, 0.55, 0.49))
	var roof: Color = cfg.color("look.scatter.roof_color", Color(0.43, 0.31, 0.26))
	_box(verts, norms, cols, w, d, 0.0, 0.68, wall.srgb_to_linear())
	_pyramid(verts, norms, cols, w, d, 0.68, 1.0, roof.srgb_to_linear())

	return _finish(verts, norms, cols)


static func _finish(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray
) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func _tri(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	a: Vector3, b: Vector3, c: Vector3, color: Color
) -> void:
	# Flat shaded like the terrain: one normal per face, vertices never shared.
	var nrm: Vector3 = (b - a).cross(c - b)
	if nrm.length_squared() < 1e-12:
		return
	nrm = nrm.normalized()
	for v: Vector3 in [a, b, c]:
		verts.push_back(v)
		norms.push_back(nrm)
		cols.push_back(color)


static func _prism(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	sides: int, r: float, y0: float, y1: float, color: Color
) -> void:
	for k: int in sides:
		var a0: float = TAU * float(k) / float(sides)
		var a1: float = TAU * float(k + 1) / float(sides)
		var p0 := Vector3(cos(a0) * r, 0.0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		_tri(verts, norms, cols, p0 + Vector3(0, y0, 0), p1 + Vector3(0, y0, 0),
			p1 + Vector3(0, y1, 0), color)
		_tri(verts, norms, cols, p0 + Vector3(0, y0, 0), p1 + Vector3(0, y1, 0),
			p0 + Vector3(0, y1, 0), color)


static func _cone(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	sides: int, r: float, y0: float, y1: float, color: Color
) -> void:
	var apex := Vector3(0.0, y1, 0.0)
	for k: int in sides:
		var a0: float = TAU * float(k) / float(sides)
		var a1: float = TAU * float(k + 1) / float(sides)
		var p0 := Vector3(cos(a0) * r, y0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, y0, sin(a1) * r)
		_tri(verts, norms, cols, p0, p1, apex, color)
		# Underside, so a canopy seen from below is not a hole.
		_tri(verts, norms, cols, Vector3(0.0, y0, 0.0), p1, p0, color)


static func _box(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	w: float, d: float, y0: float, y1: float, color: Color
) -> void:
	var hx: float = w * 0.5
	var hz: float = d * 0.5
	var corners := PackedVector3Array([
		Vector3(-hx, 0.0, -hz), Vector3(hx, 0.0, -hz),
		Vector3(hx, 0.0, hz), Vector3(-hx, 0.0, hz),
	])
	for k: int in 4:
		var p0: Vector3 = corners[k]
		var p1: Vector3 = corners[(k + 1) % 4]
		_tri(verts, norms, cols, p0 + Vector3(0, y0, 0), p1 + Vector3(0, y0, 0),
			p1 + Vector3(0, y1, 0), color)
		_tri(verts, norms, cols, p0 + Vector3(0, y0, 0), p1 + Vector3(0, y1, 0),
			p0 + Vector3(0, y1, 0), color)


## A roof: four triangles from the box's own corners up to a ridge point.
##
## Built from the footprint rather than from a regular polygon. A four-sided `_cone` puts a base
## vertex on +X, so its corners land on the *face midpoints* of an axis-aligned box and every roof
## sat 45 degrees out of true — and even phased round a quarter turn it can only ever be square,
## which a 6 x 7 m building is not.
static func _pyramid(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	w: float, d: float, y0: float, y1: float, color: Color
) -> void:
	var hx: float = w * 0.5
	var hz: float = d * 0.5
	var corners := PackedVector3Array([
		Vector3(-hx, y0, -hz), Vector3(hx, y0, -hz),
		Vector3(hx, y0, hz), Vector3(-hx, y0, hz),
	])
	var apex := Vector3(0.0, y1, 0.0)
	for k: int in 4:
		_tri(verts, norms, cols, corners[k], corners[(k + 1) % 4], apex, color)
