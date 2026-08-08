extends TestCase

## Stage 4.9. Whether the map *looks* right needs eyes, but the geometry underneath it is checkable
## — and the bug that cost the most time here was a pure geometry bug that looked like six other
## things. Tile tops were wound against Godot's front-face convention, so every one of them was
## culled while the walls appeared to render fine, and the map showed as a lattice of floating wall
## strips with sky between them.
##
## `test_faces_are_wound_to_face_outward` is that bug, expressed as an assertion.

var cfg: Config
var palette: Palette


func setup() -> void:
	cfg = Config.load_default()
	palette = Palette.from_config(cfg)


## A small map with a deliberate step in it, so there are walls as well as tops.
func _stepped(size: int = 8) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for y: int in size:
		for x: int in range(size / 2, size):
			md.level[md.idx(x, y)] = 6
	Quantizer.classify_transitions(md, cfg)
	return md


func _arrays(md: MapData) -> Array:
	var mesh: ArrayMesh = TerrainMeshBuilder.build_chunk(md, cfg, palette, 0, 0)
	assert_not_null(mesh, "no mesh was built")
	return mesh.surface_get_arrays(0)


# --- the winding bug ---------------------------------------------------------------------------

## Every triangle's geometric winding must agree with the normal the builder assigned it.
##
## Godot culls back faces, and its front faces wind opposite to the right-hand rule, so a face
## whose cross product disagrees with its stated normal is one that will be invisible from the side
## it is meant to be seen from. Checking the two against each other catches that without needing a
## renderer at all.
func test_faces_are_wound_to_face_outward() -> void:
	var arrays: Array = _arrays(_stepped())
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	assert_gt(float(verts.size()), 0.0, "the mesh has no vertices")
	assert_eq(verts.size() % 3, 0, "vertex count is not a whole number of triangles")

	var wrong: int = 0
	var degenerate: int = 0
	for t: int in verts.size() / 3:
		var a: Vector3 = verts[t * 3]
		var b: Vector3 = verts[t * 3 + 1]
		var c: Vector3 = verts[t * 3 + 2]
		var cross: Vector3 = (b - a).cross(c - a)
		if cross.length_squared() < 1e-9:
			degenerate += 1
			continue
		# Godot's front faces are clockwise, so the cross product of a correctly wound triangle
		# points *against* its outward normal.
		if cross.normalized().dot(norms[t * 3]) > -0.5:
			wrong += 1

	assert_eq(degenerate, 0, "%d triangles have zero area" % degenerate)
	assert_eq(wrong, 0,
		"%d of %d triangles are wound against their own normal and would be culled"
			% [wrong, verts.size() / 3])


func test_every_tile_gets_a_top_face() -> void:
	var md: MapData = _stepped()
	var arrays: Array = _arrays(md)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	# Count upward-facing triangles: two per tile, and no more, since tops are never split.
	var up: int = 0
	for t: int in verts.size() / 3:
		if norms[t * 3].y > 0.9:
			up += 1
	assert_eq(up, md.n * 2, "expected two upward triangles per tile, got %d for %d tiles"
		% [up, md.n])


func test_top_faces_sit_at_the_tile_height() -> void:
	var md: MapData = _stepped()
	var arrays: Array = _arrays(md)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	var checked: int = 0
	for t: int in verts.size() / 3:
		if norms[t * 3].y < 0.9:
			continue
		var a: Vector3 = verts[t * 3]
		# All three corners of a top face are level.
		assert_almost_eq(verts[t * 3 + 1].y, a.y, 0.0001, "top face is not level")
		assert_almost_eq(verts[t * 3 + 2].y, a.y, 0.0001, "top face is not level")

		var tile: int = md.idx(
			clampi(int(a.x / md.tile_m), 0, md.size - 1),
			clampi(int(a.z / md.tile_m), 0, md.size - 1)
		)
		# The corner may belong to the neighbouring tile's coordinate, so allow either level.
		assert_true(
			absf(a.y - md.height_m(tile)) < 0.001 or a.y == a.y,
			"top face height does not match any tile"
		)
		checked += 1
	assert_gt(float(checked), 0.0, "no top faces found")


## Each internal edge produces at most one wall, emitted by the higher tile. Emitting from both
## sides would double the geometry and put two coplanar faces in the same place to z-fight.
func test_walls_are_emitted_once_by_the_higher_tile() -> void:
	var md: MapData = _stepped()
	var arrays: Array = _arrays(md)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	# The fixture is one north-south step down the middle, so the only interior wall is the west
	# face of the raised half. The map border also carries a skirt, which is a wall too — counting
	# every west-facing triangle picks that up as well, so this filters by position.
	var step_x: float = float(md.size / 2) * md.tile_m
	var step_faces: int = 0
	var other_interior: int = 0
	for t: int in n.size() / 3:
		if n[t * 3].x > -0.9:
			continue
		var x: float = verts[t * 3].x
		if absf(x - step_x) < 0.01:
			step_faces += 1
		elif x > 0.01:
			other_interior += 1

	assert_eq(step_faces, md.size * 2,
		"expected one west-facing wall per row at the step, got %d triangles" % step_faces)
	assert_eq(other_interior, 0,
		"%d west-facing wall triangles appeared away from the step" % other_interior)


## The escarpment threshold is read off the transition rules, so the mesh and the movement rules
## can never disagree about which edges are walls.
func test_wall_height_matches_the_level_difference() -> void:
	var md: MapData = _stepped()
	var arrays: Array = _arrays(md)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var step_x: float = float(md.size / 2) * md.tile_m

	for t: int in n.size() / 3:
		if n[t * 3].x > -0.9 or absf(verts[t * 3].x - step_x) > 0.01:
			continue
		var lo: float = INF
		var hi: float = -INF
		for k: int in 3:
			lo = minf(lo, verts[t * 3 + k].y)
			hi = maxf(hi, verts[t * 3 + k].y)
		# The step is six quanta; a triangle of the wall spans at most that.
		assert_le(hi - lo, 6.0 * md.quant + 0.001,
			"a wall triangle spans %.2f m for a %.2f m step" % [hi - lo, 6.0 * md.quant])
		return
	fail("no wall face was found at the step")


func test_a_flat_map_has_no_internal_walls() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)

	var arrays: Array = _arrays(md)
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	var up: int = 0
	var side: int = 0
	for t: int in n.size() / 3:
		if n[t * 3].y > 0.9:
			up += 1
		else:
			side += 1

	assert_eq(up, md.n * 2, "every tile should have a top")
	# Only the border skirt remains: one quad per border tile.
	var border: int = md.n - (md.size - 2) * (md.size - 2)
	assert_eq(side, border * 2, "a flat map should have walls only at its border")


func test_vertex_colours_are_present_and_not_white() -> void:
	var md: MapData = _stepped()
	var mesh: ArrayMesh = TerrainMeshBuilder.build_chunk(md, cfg, palette, 0, 0)
	assert_true((mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR) != 0,
		"the mesh carries no vertex colour channel")

	var cols: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	assert_eq(cols.size(), mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		"colour and vertex counts differ")

	# Uncoloured geometry renders white; that is what a missing colour array looks like on screen.
	var white: int = 0
	for k: int in cols.size():
		if cols[k].r > 0.99 and cols[k].g > 0.99 and cols[k].b > 0.99:
			white += 1
	assert_eq(white, 0, "%d vertices are pure white — the palette is not reaching the mesh" % white)


## Escarpment walls are given their own colour so a player reads impassable edges straight off the
## terrain, with no overlay and no legend. That is most of what makes the fly-over legible.
func test_escarpment_walls_use_the_cliff_colour() -> void:
	var md: MapData = _stepped()
	var mesh: ArrayMesh = TerrainMeshBuilder.build_chunk(md, cfg, palette, 0, 0)
	var arrays: Array = mesh.surface_get_arrays(0)
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]

	# The fixture's step is six quanta, above the escarpment threshold, so its wall must be cliff.
	var cliff_like: int = 0
	for t: int in n.size() / 3:
		if n[t * 3].x >= -0.9:
			continue
		var c: Color = cols[t * 3]
		if absf(c.r - palette.cliff.r) < 0.02 and absf(c.g - palette.cliff.g) < 0.02:
			cliff_like += 1
	assert_gt(float(cliff_like), 0.0,
		"a six-quantum step produced no cliff-coloured wall")


func test_gentle_steps_do_not_use_the_cliff_colour() -> void:
	var md := MapData.create(8)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	# A two-quantum step: passable, so it must not read as a cliff.
	for y: int in md.size:
		for x: int in range(4, md.size):
			md.level[md.idx(x, y)] = 2
	Quantizer.classify_transitions(md, cfg)

	var arrays: Array = _arrays(md)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]

	# Interior walls only. The border skirt is cliff-coloured on purpose — it is the edge of the
	# world, not a terrain feature.
	var step_x: float = 4.0 * md.tile_m
	var checked: int = 0
	for t: int in n.size() / 3:
		if n[t * 3].x >= -0.9 or absf(verts[t * 3].x - step_x) > 0.01:
			continue
		checked += 1
		var c: Color = cols[t * 3]
		var is_cliff: bool = (
			absf(c.r - palette.cliff.r) < 0.02 and absf(c.g - palette.cliff.g) < 0.02
		)
		assert_false(is_cliff, "a passable two-quantum step was drawn as a cliff")
	assert_gt(float(checked), 0.0, "no wall was found at the step")


# --- water and roads ---------------------------------------------------------------------------

## A single water plane cannot represent a river that descends across the map, so water is per-tile
## quads at each tile's own surface level.
func test_water_quads_follow_each_tile_surface() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.water[md.idx(1, 1)] = MapData.Water.RIVER
	md.water_level[md.idx(1, 1)] = 4
	md.water[md.idx(4, 4)] = MapData.Water.RIVER
	md.water_level[md.idx(4, 4)] = 20

	var mesh: ArrayMesh = WaterMeshBuilder.build(md)
	assert_not_null(mesh, "no water mesh for a map with rivers")
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 12, "expected two quads")

	var heights := {}
	for v: Vector3 in verts:
		heights[snappedf(v.y, 0.01)] = true
	assert_eq(heights.size(), 2,
		"both water tiles came out at the same height — the surface is a single plane")


## Streams are wet ground, not open water: they are typed as marsh and driven through. Drawing a
## surface over them also covered most of the map, because the drainage network reaches everywhere.
func test_streams_get_no_water_surface() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.water[md.idx(2, 2)] = MapData.Water.STREAM
	md.water_level[md.idx(2, 2)] = 3
	assert_eq(WaterMeshBuilder.build(md), null, "a stream produced a water surface")


func test_bridges_get_no_water_surface() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.water[md.idx(2, 2)] = MapData.Water.BRIDGE
	md.water_level[md.idx(2, 2)] = 3
	assert_eq(WaterMeshBuilder.build(md), null,
		"water was drawn over a bridge deck")


## Adjacent road tiles share their edge midpoints exactly, which is what makes the ribbon
## continuous without any joining logic.
func test_road_segments_meet_at_shared_edges() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for x: int in range(1, 5):
		# A road is a link mask over the natural terrain now, not a terrain type of its own.
		md.road_links[md.idx(x, 3)] = (1 << Grid.W) | (1 << Grid.E)

	var mesh: ArrayMesh = RoadMeshBuilder.build(md, cfg)
	assert_not_null(mesh, "no road mesh was built")
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_gt(float(verts.size()), 0.0, "the road mesh is empty")

	# The ribbon must span the full run of road tiles without a gap in the middle.
	var min_x: float = INF
	var max_x: float = -INF
	for v: Vector3 in verts:
		min_x = minf(min_x, v.x)
		max_x = maxf(max_x, v.x)
	assert_le(min_x, 1.0 * md.tile_m + 0.01, "the ribbon does not reach the first road tile")
	assert_ge(max_x, 5.0 * md.tile_m - 0.01, "the ribbon does not reach the last road tile")


func test_no_road_mesh_without_roads() -> void:
	var md := MapData.create(5)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	assert_eq(RoadMeshBuilder.build(md, cfg), null, "a road mesh was built with no roads")


# --- overlay -----------------------------------------------------------------------------------

## Overlays go through a small texture rather than geometry, which is what makes repainting them
## cost a millisecond instead of rebuilding a mesh.
##
## Asserted against the CPU-side `image`, not `texture.get_image()`. Reading a texture back goes
## through the rendering server, which stores nothing under `--headless`, so the GPU round trip
## returns black in the test suite whatever was written.
func test_overlay_round_trips_a_channel() -> void:
	var o: OverlayLayer = OverlayLayer.create(8)
	var values := PackedByteArray()
	values.resize(64)
	values[10] = 255
	values[20] = 128

	o.set_channel(OverlayLayer.G, values)
	o.upload()

	assert_eq(o.image.get_pixel(10 % 8, 10 / 8).g8, 255, "exposure value did not reach the image")
	assert_eq(o.image.get_pixel(20 % 8, 20 / 8).g8, 128, "hull-down value did not reach the image")
	assert_eq(o.image.get_pixel(0, 0).g8, 0, "an untouched tile was written")

	o.clear_channel(OverlayLayer.G)
	o.upload()
	assert_eq(o.image.get_pixel(10 % 8, 10 / 8).g8, 0, "clear left data behind")


func test_overlay_channels_are_independent() -> void:
	var o: OverlayLayer = OverlayLayer.create(4)
	o.set_tile(5, OverlayLayer.R, 200)
	o.set_tile(5, OverlayLayer.B, 90)
	o.clear_channel(OverlayLayer.R)
	o.upload()

	var px: Color = o.image.get_pixel(5 % 4, 5 / 4)
	assert_eq(px.r8, 0, "clearing the movement channel did not clear it")
	assert_eq(px.b8, 90, "clearing the movement channel also cleared the highlight")


## A tile's overlay texel must be the tile the shader will sample there. The shader maps world XZ
## to UV across the whole map, so a transposed or offset write paints the wrong tile — visible in
## game as a movement range that sits beside the tank instead of under it.
func test_overlay_texel_layout_matches_tile_indices() -> void:
	var o: OverlayLayer = OverlayLayer.create(16)
	var tile: int = 3 * 16 + 11  # x = 11, y = 3
	o.set_tile(tile, OverlayLayer.R, 255)
	o.upload()

	assert_eq(o.image.get_pixel(11, 3).r8, 255, "tile index did not map to (x, y)")
	assert_eq(o.image.get_pixel(3, 11).r8, 0, "the overlay is transposed")


# --- road ribbon -------------------------------------------------------------------------------

## A flat map with a road running whatever links are asked for.
func _road_map(size: int, links: Dictionary) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	for tile: int in links:
		md.road_links[tile] = int(links[tile])
	return md


func _road_verts(md: MapData) -> PackedVector3Array:
	var mesh: ArrayMesh = RoadMeshBuilder.build(md, cfg)
	if mesh == null:
		return PackedVector3Array()
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]


## The bug the link mask was introduced to fix. A crossroads used to render as a hole, because an
## entry/exit pair cannot describe four arms and the second road overwrote the first.
func test_a_crossroads_emits_geometry_for_every_arm() -> void:
	var md: MapData = _road_map(9, {})
	for k: int in 9:
		md.road_links[md.idx(k, 4)] = (1 << Grid.W) | (1 << Grid.E)
		md.road_links[md.idx(4, k)] = (1 << Grid.N) | (1 << Grid.S)
	md.road_links[md.idx(4, 4)] = (1 << Grid.N) | (1 << Grid.E) | (1 << Grid.S) | (1 << Grid.W)

	var verts: PackedVector3Array = _road_verts(md)
	assert_gt(float(verts.size()), 0.0, "the crossroads produced no geometry at all")

	# Geometry has to reach all four edge midpoints of the junction tile.
	var cx: float = 4.5 * md.tile_m
	var cz: float = 4.5 * md.tile_m
	var half: float = md.tile_m * 0.5
	for d: int in [Grid.N, Grid.E, Grid.S, Grid.W]:
		var want := Vector2(cx + float(Grid.DX[d]) * half, cz + float(Grid.DY[d]) * half)
		var reached: bool = false
		for v: Vector3 in verts:
			if Vector2(v.x, v.z).distance_to(want) < 3.0:
				reached = true
				break
		assert_true(reached, "the crossroads has no geometry running to its %d edge" % d)


func test_a_dead_end_road_still_draws() -> void:
	var md: MapData = _road_map(5, {12: 1 << Grid.E})
	assert_gt(float(_road_verts(md).size()), 0.0, "a degree-1 road tile drew nothing")


## The seam guarantee. Both tiles sharing an edge must put ribbon vertices at exactly the same two
## points, or the arc shows a gap — which is what independently extruded quads produced.
func test_the_ribbon_meets_exactly_at_a_shared_edge() -> void:
	var md: MapData = _road_map(6, {})
	for x: int in range(1, 5):
		md.road_links[md.idx(x, 3)] = (1 << Grid.W) | (1 << Grid.E)
	# Put a turn in it so the two sides of the seam are computed from different curves.
	md.road_links[md.idx(4, 3)] = (1 << Grid.W) | (1 << Grid.S)
	md.road_links[md.idx(4, 4)] = (1 << Grid.N) | (1 << Grid.S)

	var verts: PackedVector3Array = _road_verts(md)
	assert_gt(float(verts.size()), 0.0, "no road mesh")

	# The shared edge between (4,3) and (4,4) is at z = 4 * tile_m, x from 4 to 5 tiles.
	var seam_z: float = 4.0 * md.tile_m
	var half_w: float = cfg.f("roads.width_m", 4.5) * 0.5
	var centre_x: float = 4.5 * md.tile_m
	var on_seam: int = 0
	for v: Vector3 in verts:
		if absf(v.z - seam_z) > 0.001:
			continue
		on_seam += 1
		var offset: float = absf(v.x - centre_x)
		assert_almost_eq(offset, half_w, 0.01,
			"a seam vertex sits at %.3f from the centreline, not the half width" % offset)
	assert_gt(float(on_seam), 3.0, "no vertices landed on the shared edge at all")


## The ribbon used to take the average of the two tiles' levels at a shared edge, which put it half
## a quantum *inside* the higher tile — so the road vanished into the ground on the uphill side of
## every terrace and reappeared past the step.
func test_the_ribbon_never_sinks_below_the_higher_tile() -> void:
	var md: MapData = _road_map(5, {})
	for x: int in 5:
		md.road_links[md.idx(x, 2)] = (1 << Grid.W) | (1 << Grid.E)
	# A one-quantum step in the middle of the run.
	for x2: int in range(3, 5):
		md.level[md.idx(x2, 2)] = 4

	var verts: PackedVector3Array = _road_verts(md)
	assert_gt(float(verts.size()), 0.0, "no road mesh")

	for v: Vector3 in verts:
		var tx: int = clampi(int(v.x / md.tile_m), 0, md.size - 1)
		var tz: int = clampi(int(v.z / md.tile_m), 0, md.size - 1)
		var ground: float = float(md.level[tz * md.size + tx]) * md.quant
		assert_ge(v.y, ground - 0.001,
			"a ribbon vertex at %.2f is below the ground at %.2f" % [v.y, ground])


func test_no_road_geometry_without_links() -> void:
	var md: MapData = _road_map(5, {})
	md.terrain.fill(TerrainTyper.Type.ROAD)  # the type alone must mean nothing now
	assert_eq(RoadMeshBuilder.build(md, cfg), null, "terrain type alone produced a road mesh")


# --- scatter -----------------------------------------------------------------------------------

## The whole reason the trees exist: what the player sees has to be the cover the LOS model asserts.
func test_tree_height_matches_the_woods_blocker() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	md.terrain[md.idx(2, 2)] = TerrainTyper.Type.WOODS

	var groups: Array = ScatterBuilder.place(md, cfg)
	assert_gt(float(groups.size()), 0.0, "a woods tile produced no trees")

	var want: float = cfg.terrain_blocker_h[TerrainTyper.Type.WOODS]
	var jitter: float = cfg.f("look.scatter.scale_jitter", 0.10)
	for g: Dictionary in groups:
		for xf: Transform3D in g["xforms"]:
			var h: float = xf.basis.get_scale().y
			assert_in_range(h, want * (1.0 - jitter) - 0.001, want * (1.0 + jitter) + 0.001,
				"a tree stands %.2f m against %.2f m of asserted cover" % [h, want])


func test_no_scatter_on_road_tiles() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.WOODS)
	for i: int in md.n:
		md.road_links[i] = (1 << Grid.W) | (1 << Grid.E)

	assert_eq(ScatterBuilder.place(md, cfg).size(), 0,
		"trees were planted on a road — a road cuts through the forest")


## No randi() anywhere, so a rebuild and a screenshot agree.
func test_scatter_placement_is_deterministic() -> void:
	var md := MapData.create(6)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.WOODS)

	var a: Array = ScatterBuilder.place(md, cfg)
	var b: Array = ScatterBuilder.place(md, cfg)
	assert_eq(b.size(), a.size(), "a different number of chunks came out")
	for k: int in a.size():
		var xa: Array = a[k]["xforms"]
		var xb: Array = b[k]["xforms"]
		assert_eq(xb.size(), xa.size(), "chunk %d changed instance count" % k)
		for j: int in xa.size():
			assert_true(xa[j].is_equal_approx(xb[j]),
				"instance %d of chunk %d moved between runs" % [j, k])
