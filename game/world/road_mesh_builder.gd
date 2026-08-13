class_name RoadMeshBuilder
extends RefCounted

## Roads, built from the per-tile link mask (`MapData.road_links`, docs/decisions/0011).
##
## What a tile draws depends on how many edges its road connects to:
##
##   degree 2      a quadratic Bezier from one edge midpoint, through the tile center, to the other.
##                 Straight-through gives a straight line and a turn gives a quarter arc.
##   degree 1      a straight stub from the center out to the one connected edge, plus the hub,
##                 which rounds off the end.
##   degree 3+     a straight stub per connected edge, plus a hub polygon at the tile center that
##                 covers the corners where they meet. This is what an entry/exit pair could not
##                 express, and why crossings used to render as holes.
##
## **Seams are exact rather than approximately closed.** Two things make that true. The ribbon
## carries a mitred cross-section along the polyline, so consecutive quads *share* their corner
## vertices instead of each being extruded independently — extruding independently leaves a wedge
## notch at every joint, which is what turned an eight-sample arc into eight visibly separate
## chunks. And at a tile boundary the cross-section works out to exactly the edge perpendicular:
## the Bezier's control point is the tile center, so its end tangent is exactly the edge normal, and
## both tiles sharing the edge derive the same axis from integer direction offsets. Neither tile
## needs to know anything about the other.


## Structural, not a tunable: it exists only to break a depth tie between the junction hub and the
## stubs it overlaps, and any value large enough to be worth tuning would be visible.
const HUB_LIFT_M := 0.01


static func build(md: MapData, cfg: Config) -> ArrayMesh:
	var samples: int = maxi(cfg.i("roads.bezier_samples", 8), 2)
	var half_w: float = cfg.f("roads.width_m", 4.5) * 0.5
	var lift: float = cfg.f("look.road_lift_m", 0.12)
	var hub_sides: int = maxi(cfg.i("roads.junction_hub_sides", 8), 3)
	var color: Color = cfg.terrain_colors[TerrainTyper.Type.ROAD].lightened(0.06).srgb_to_linear()

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()

	var dirs := PackedInt32Array()
	var pts := PackedVector3Array()

	for i: int in md.n:
		var mask: int = int(md.road_links[i])
		if mask == 0:
			continue

		dirs.clear()
		for d: int in 8:
			if (mask >> d) & 1 == 1:
				dirs.append(d)

		var center: Vector3 = _tile_center(md, i, lift)

		if dirs.size() == 2:
			var p0: Vector3 = _edge_midpoint(md, i, dirs[0], lift)
			var p2: Vector3 = _edge_midpoint(md, i, dirs[1], lift)
			pts.clear()
			for s: int in range(samples + 1):
				pts.append(_bezier(p0, center, p2, float(s) / float(samples)))
			_emit_ribbon(
				verts, norms, cols, pts, half_w, color,
				_edge_normal(dirs[0]), _edge_normal(dirs[1])
			)
			continue

		# A junction or a dead end. Each arm is its own straight ribbon out to its edge, and the hub
		# fills the middle — a fan is cheaper and more robust than trying to mitre three or four
		# arms meeting at arbitrary angles.
		for k: int in dirs.size():
			var n: Vector3 = _edge_normal(dirs[k])
			pts.clear()
			pts.append(center)
			pts.append(_edge_midpoint(md, i, dirs[k], lift))
			_emit_ribbon(verts, norms, cols, pts, half_w, color, n, n)
		# The hub overlaps the inner end of every stub, and coplanar overlapping triangles z-fight.
		# A centimeter of lift breaks the tie without being visible on a 4.5 m ribbon; moving the
		# stubs out to the rim instead would leave a hairline gap at each corner.
		_emit_hub(verts, norms, cols, center + Vector3(0.0, HUB_LIFT_M, 0.0),
			half_w, hub_sides, color)

	if verts.is_empty():
		return null

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _bezier(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	var u: float = 1.0 - t
	return a * (u * u) + b * (2.0 * u * t) + c * (t * t)


static func _tile_center(md: MapData, i: int, lift: float) -> Vector3:
	return Vector3(
		(float(md.tx(i)) + 0.5) * md.tile_m,
		float(md.level[i]) * md.quant + lift,
		(float(md.ty(i)) + 0.5) * md.tile_m
	)


## Midpoint of the tile's edge in direction `d`, at the height of the **higher** of the two tiles
## sharing it.
##
## Taking the average instead — which is what this did first — puts the ribbon half a quantum below
## the higher tile's top face for the whole half tile leading up to a terrace, so the road sinks
## into the ground and reappears past the step. `max` is symmetric, so both tiles still agree on the
## point, and the ribbon rides over the terrace instead of through it.
static func _edge_midpoint(md: MapData, i: int, d: int, lift: float) -> Vector3:
	var cx: float = (float(md.tx(i)) + 0.5) * md.tile_m
	var cz: float = (float(md.ty(i)) + 0.5) * md.tile_m
	var half: float = md.tile_m * 0.5

	var lv: int = md.level[i]
	var nb: int = md.neighbor(i, d)
	if nb >= 0:
		lv = maxi(lv, md.level[nb])

	return Vector3(
		cx + float(Grid.DX[d]) * half,
		float(lv) * md.quant + lift,
		cz + float(Grid.DY[d]) * half
	)


## Unit horizontal normal of a tile edge — the axis a cross-section lies along where a road crosses
## that edge. Derived from the integer direction table, so two tiles sharing an edge compute it
## bit-for-bit identically.
static func _edge_normal(d: int) -> Vector3:
	return Vector3(-float(Grid.DY[d]), 0.0, float(Grid.DX[d])).normalized()


## Extrude a polyline into a flat ribbon, sharing a mitred cross-section at every interior vertex.
##
## The cross-section normal at an interior vertex is the bisector of the two adjoining segment
## normals, lengthened by 1/cos(half the turn) so the ribbon keeps its width through the corner.
## The scale is clamped because a hairpin sends that to infinity; at the angles a sampled quarter
## arc actually produces it sits a fraction of a percent above 1.
##
## `end_a` and `end_b` force the normal of the first and last cross-sections, and this is what makes
## a seam exact. It is tempting to let the endpoints derive their normal like everything else — the
## Bezier's control point is the tile center, so its *derivative* at the endpoint is exactly the
## edge normal. But the ribbon is built from *chords*, and the chord to the first sample has already
## begun to curve toward the far edge. On a quarter arc at eight samples that tilts the end
## cross-section by about nine degrees, which moved the seam vertices 15 cm off the tile boundary
## while the straight tile next door put them exactly on it. Small, and exactly the kind of small
## that reads as a crack in the road.
static func _emit_ribbon(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	pts: PackedVector3Array, half_w: float, color: Color,
	end_a: Vector3 = Vector3.ZERO, end_b: Vector3 = Vector3.ZERO
) -> void:
	var n: int = pts.size()
	if n < 2:
		return

	# Horizontal unit normal of each segment. The ribbon stays level across its width — a road on a
	# side slope is banked by the terrain under it, not by the mesh.
	var seg_normal := PackedVector3Array()
	seg_normal.resize(n - 1)
	var valid: int = 0
	for k: int in n - 1:
		var along: Vector3 = pts[k + 1] - pts[k]
		along.y = 0.0
		if along.length_squared() < 1e-10:
			seg_normal[k] = Vector3.ZERO
			continue
		along = along.normalized()
		seg_normal[k] = Vector3(-along.z, 0.0, along.x)
		valid += 1
	if valid == 0:
		return

	# Carry the last good normal forward across any degenerate segment, so a repeated sample point
	# cannot collapse a cross-section to zero width.
	var last := Vector3.ZERO
	for k2: int in n - 1:
		if seg_normal[k2] == Vector3.ZERO:
			seg_normal[k2] = last
		else:
			last = seg_normal[k2]
	for k3: int in range(n - 2, -1, -1):
		if seg_normal[k3] == Vector3.ZERO:
			seg_normal[k3] = seg_normal[k3 + 1]

	# The forced endpoint normals keep the axis exact but must not flip the ribbon over: the sign is
	# taken from the segment so left stays left and the quads do not come out as a bowtie.
	var fixed_a: Vector3 = _oriented(end_a, seg_normal[0])
	var fixed_b: Vector3 = _oriented(end_b, seg_normal[n - 2])

	var side := PackedVector3Array()
	side.resize(n)
	for v: int in n:
		if v == 0:
			side[0] = fixed_a * half_w
		elif v == n - 1:
			side[v] = fixed_b * half_w
		else:
			var a: Vector3 = seg_normal[v - 1]
			var b: Vector3 = seg_normal[v]
			var m: Vector3 = a + b
			if m.length_squared() < 1e-10:
				side[v] = a * half_w
			else:
				m = m.normalized()
				side[v] = m * (half_w * clampf(1.0 / maxf(m.dot(a), 0.001), 1.0, 2.5))

	for q: int in n - 1:
		var pl: Vector3 = pts[q] - side[q]
		var pr: Vector3 = pts[q] + side[q]
		var cl: Vector3 = pts[q + 1] - side[q + 1]
		var cr: Vector3 = pts[q + 1] + side[q + 1]
		for vtx: Vector3 in [pl, cl, cr, pl, cr, pr]:
			verts.push_back(vtx)
			norms.push_back(Vector3.UP)
			cols.push_back(color)


## `forced` if one was given, flipped to sit on the same side as `derived`; otherwise `derived`.
static func _oriented(forced: Vector3, derived: Vector3) -> Vector3:
	if forced == Vector3.ZERO:
		return derived
	return -forced if forced.dot(derived) < 0.0 else forced


## A regular polygon at a junction's center, as a triangle fan. Wound to match the ribbon.
static func _emit_hub(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
	center: Vector3, radius: float, sides: int, color: Color
) -> void:
	for k: int in sides:
		var a0: float = TAU * float(k) / float(sides)
		var a1: float = TAU * float(k + 1) / float(sides)
		var v0 := center + Vector3(cos(a0), 0.0, sin(a0)) * radius
		var v1 := center + Vector3(cos(a1), 0.0, sin(a1)) * radius
		for vtx: Vector3 in [center, v0, v1]:
			verts.push_back(vtx)
			norms.push_back(Vector3.UP)
			cols.push_back(color)
