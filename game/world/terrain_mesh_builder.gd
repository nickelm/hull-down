class_name TerrainMeshBuilder
extends RefCounted

## Builds the terraced, flat-shaded terrain mesh.
##
## Three decisions do the work here:
##
## - **ArrayMesh filled directly, not SurfaceTool.** SurfaceTool does per-vertex Variant work and
##   vertex deduplication; at six hundred thousand vertices that costs seconds and fights the flat
##   shading. Filling pre-sized Packed arrays costs a few hundred milliseconds, once per map.
## - **Flat shading is structural.** Vertices are never shared between faces and every face writes
##   one constant normal. No smoothing groups, no `generate_normals()`, no shader trickery — and
##   crisp terrace edges are guaranteed rather than hoped for.
## - **Each wall is emitted once, by the higher tile.** Emitting from both sides would double the
##   geometry and put two coplanar faces in the same place to z-fight.
##
## Escarpment walls get a distinct cliff color. That single decision is most of what makes the
## fly-over legible: impassable edges are visible as terrain, with no overlay and no legend.

## Tiles per chunk. Chunking gives frustum culling and lets a local edit rebuild one chunk instead
## of the map.
const CHUNK := 40


static func build_chunks(md: MapData, cfg: Config, palette: Palette) -> Array:
	var out: Array = []
	var chunks: int = int(ceil(float(md.size) / float(CHUNK)))
	for cy: int in chunks:
		for cx: int in chunks:
			var mesh: ArrayMesh = build_chunk(md, cfg, palette, cx, cy)
			if mesh != null:
				out.append({"mesh": mesh, "cx": cx, "cy": cy})
	return out


static func build_chunk(
	md: MapData, cfg: Config, palette: Palette, cx: int, cy: int
) -> ArrayMesh:
	var x0: int = cx * CHUNK
	var y0: int = cy * CHUNK
	var x1: int = mini(x0 + CHUNK, md.size)
	var y1: int = mini(y0 + CHUNK, md.size)
	if x0 >= x1 or y0 >= y1:
		return null

	var tile_m: float = md.tile_m
	var quant: float = md.quant
	var escarpment_dl: int = cfg.i("traversal.rough_max_dl", 4)
	var jitter: float = cfg.f("look.color_jitter", 0.02)

	# Pass one counts faces so the arrays are sized exactly once. Integer work only, about a
	# millisecond; the alternative is repeatedly growing three arrays of half a million entries.
	var quads: int = 0
	for y: int in range(y0, y1):
		for x: int in range(x0, x1):
			quads += 1  # the tile top
			var i: int = md.idx(x, y)
			var lv: int = md.level[i]
			if x + 1 < md.size and md.level[i + 1] < lv:
				quads += 1
			if x > 0 and md.level[i - 1] < lv:
				quads += 1
			if y + 1 < md.size and md.level[i + md.size] < lv:
				quads += 1
			if y > 0 and md.level[i - md.size] < lv:
				quads += 1
			# Map border: a skirt so the edge of the world is solid rather than a hole.
			if x == 0 or x == md.size - 1 or y == 0 or y == md.size - 1:
				quads += 1

	var vcount: int = quads * 6
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(vcount)
	norms.resize(vcount)
	cols.resize(vcount)

	var skirt_y: float = _lowest_level(md) * quant - 8.0
	var cur: int = 0

	for y2: int in range(y0, y1):
		for x2: int in range(x0, x1):
			var i2: int = md.idx(x2, y2)
			var lv2: int = md.level[i2]
			var yy: float = float(lv2) * quant
			var wx0: float = float(x2) * tile_m
			var wx1: float = wx0 + tile_m
			var wz0: float = float(y2) * tile_m
			var wz1: float = wz0 + tile_m

			var t: int = int(md.terrain[i2])
			var top: Color = Palette.jitter(palette.ground[t], i2, jitter)

			cur = _quad(
				verts, norms, cols, cur,
				Vector3(wx0, yy, wz1), Vector3(wx1, yy, wz1),
				Vector3(wx1, yy, wz0), Vector3(wx0, yy, wz0),
				Vector3.UP, top
			)

			# Walls, emitted only towards lower neighbors.
			if x2 + 1 < md.size:
				var ln: int = md.level[i2 + 1]
				if ln < lv2:
					var wcol: Color = (
						palette.cliff if (lv2 - ln) > escarpment_dl else palette.wall[t]
					)
					cur = _quad(
						verts, norms, cols, cur,
						Vector3(wx1, yy, wz0), Vector3(wx1, yy, wz1),
						Vector3(wx1, float(ln) * quant, wz1), Vector3(wx1, float(ln) * quant, wz0),
						Vector3.RIGHT, wcol
					)
			if x2 > 0:
				var lw: int = md.level[i2 - 1]
				if lw < lv2:
					var wcol2: Color = (
						palette.cliff if (lv2 - lw) > escarpment_dl else palette.wall[t]
					)
					cur = _quad(
						verts, norms, cols, cur,
						Vector3(wx0, yy, wz1), Vector3(wx0, yy, wz0),
						Vector3(wx0, float(lw) * quant, wz0), Vector3(wx0, float(lw) * quant, wz1),
						Vector3.LEFT, wcol2
					)
			if y2 + 1 < md.size:
				var ls: int = md.level[i2 + md.size]
				if ls < lv2:
					var wcol3: Color = (
						palette.cliff if (lv2 - ls) > escarpment_dl else palette.wall[t]
					)
					cur = _quad(
						verts, norms, cols, cur,
						Vector3(wx1, yy, wz1), Vector3(wx0, yy, wz1),
						Vector3(wx0, float(ls) * quant, wz1), Vector3(wx1, float(ls) * quant, wz1),
						Vector3.BACK, wcol3
					)
			if y2 > 0:
				var ln2: int = md.level[i2 - md.size]
				if ln2 < lv2:
					var wcol4: Color = (
						palette.cliff if (lv2 - ln2) > escarpment_dl else palette.wall[t]
					)
					cur = _quad(
						verts, norms, cols, cur,
						Vector3(wx0, yy, wz0), Vector3(wx1, yy, wz0),
						Vector3(wx1, float(ln2) * quant, wz0), Vector3(wx0, float(ln2) * quant, wz0),
						Vector3.FORWARD, wcol4
					)

			# Border skirt.
			if x2 == 0:
				cur = _quad(
					verts, norms, cols, cur,
					Vector3(wx0, yy, wz1), Vector3(wx0, yy, wz0),
					Vector3(wx0, skirt_y, wz0), Vector3(wx0, skirt_y, wz1),
					Vector3.LEFT, palette.cliff
				)
			elif x2 == md.size - 1:
				cur = _quad(
					verts, norms, cols, cur,
					Vector3(wx1, yy, wz0), Vector3(wx1, yy, wz1),
					Vector3(wx1, skirt_y, wz1), Vector3(wx1, skirt_y, wz0),
					Vector3.RIGHT, palette.cliff
				)
			elif y2 == 0:
				cur = _quad(
					verts, norms, cols, cur,
					Vector3(wx0, yy, wz0), Vector3(wx1, yy, wz0),
					Vector3(wx1, skirt_y, wz0), Vector3(wx0, skirt_y, wz0),
					Vector3.FORWARD, palette.cliff
				)
			elif y2 == md.size - 1:
				cur = _quad(
					verts, norms, cols, cur,
					Vector3(wx1, yy, wz1), Vector3(wx0, yy, wz1),
					Vector3(wx0, skirt_y, wz1), Vector3(wx1, skirt_y, wz1),
					Vector3.BACK, palette.cliff
				)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Emit one quad as two triangles, six unshared vertices, one normal, one color. Returns the new
## write cursor.
##
## Callers pass a, b, c, d in the order the right-hand rule would give for the outward normal, and
## this reverses them, because Godot's front faces wind the other way. Doing the flip once here
## rather than at each call site is what keeps the emission code above readable — and getting it
## wrong is not obvious from the result: with the faces inverted, every tile top was culled while
## the walls appeared to render fine (they were being seen from the inside, through the holes the
## missing tops left), which looks like anything except a winding problem.
static func _quad(
	verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, cur: int,
	a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color
) -> int:
	verts[cur] = a
	verts[cur + 1] = d
	verts[cur + 2] = c
	verts[cur + 3] = a
	verts[cur + 4] = c
	verts[cur + 5] = b
	for k: int in 6:
		norms[cur + k] = n
		cols[cur + k] = col
	return cur + 6


static func _lowest_level(md: MapData) -> float:
	var lo: int = md.level[0]
	for i: int in md.n:
		if md.level[i] < lo:
			lo = md.level[i]
	return float(lo)
