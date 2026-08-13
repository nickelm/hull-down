class_name TerrainView
extends Node3D

## Owns the rendered map: terrain chunks, water, roads, and the overlay texture they all share.
##
## This is the boundary the directory contract draws. Everything above it is Nodes and rendering;
## everything it reads — `MapData`, `Config` — is plain data from `sim/`, and nothing here is
## visible to the simulation.

var md: MapData
var cfg: Config
var palette: Palette
var overlay: OverlayLayer

var _terrain_material: ShaderMaterial
var _chunks: Array[MeshInstance3D] = []
var _water: MeshInstance3D
var _roads: MeshInstance3D
var _scatter: Array[MultiMeshInstance3D] = []


func build(map: MapData, config: Config) -> Dictionary:
	md = map
	cfg = config
	palette = Palette.from_config(cfg)
	overlay = OverlayLayer.create(md.size)

	var timings: Dictionary = {}
	_clear()

	var t0: int = Time.get_ticks_usec()
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load("res://game/shaders/terrain.gdshader")
	_apply_overlay_uniforms(_terrain_material)
	_terrain_material.set_shader_parameter(
		"grid_strength", cfg.f("look.grid_strength", 0.16)
	)

	var built: Array = TerrainMeshBuilder.build_chunks(md, cfg, palette)
	for entry: Dictionary in built:
		var mi := MeshInstance3D.new()
		mi.mesh = entry["mesh"]
		mi.material_override = _terrain_material
		mi.name = "Chunk_%d_%d" % [int(entry["cx"]), int(entry["cy"])]
		add_child(mi)
		_chunks.append(mi)
	timings["terrain_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0

	var t1: int = Time.get_ticks_usec()
	var water_mesh: ArrayMesh = WaterMeshBuilder.build(md)
	if water_mesh != null:
		var wm := ShaderMaterial.new()
		wm.shader = load("res://game/shaders/water.gdshader")
		_water = MeshInstance3D.new()
		_water.mesh = water_mesh
		_water.material_override = wm
		_water.name = "Water"
		add_child(_water)
	timings["water_ms"] = float(Time.get_ticks_usec() - t1) / 1000.0

	var t2: int = Time.get_ticks_usec()
	var road_mesh: ArrayMesh = RoadMeshBuilder.build(md, cfg)
	if road_mesh != null:
		# The same shader as the terrain, not a StandardMaterial3D. Roads carry vertex colors and
		# up normals like the ground does, and putting them on the terrain shader is what makes the
		# overlays tint them — on their own material a movement region had a gray hole down the
		# middle of every road. Grid lines are off: they belong to tile boundaries, not to a ribbon
		# that crosses them.
		var rm := ShaderMaterial.new()
		rm.shader = _terrain_material.shader
		_apply_overlay_uniforms(rm)
		rm.set_shader_parameter("grid_strength", 0.0)
		_roads = MeshInstance3D.new()
		_roads.mesh = road_mesh
		_roads.material_override = rm
		_roads.name = "Roads"
		add_child(_roads)
	timings["roads_ms"] = float(Time.get_ticks_usec() - t2) / 1000.0

	# Trees and buildings. Their own unshaded-by-overlay material: an outline drawn across a canopy
	# would say the tree is in the movement region, and the region is a property of the ground.
	var t3: int = Time.get_ticks_usec()
	var instances: int = 0
	var sm := StandardMaterial3D.new()
	sm.vertex_color_use_as_albedo = true
	sm.roughness = 1.0
	sm.metallic = 0.0
	for mi: MultiMeshInstance3D in ScatterBuilder.build(md, cfg, palette):
		mi.material_override = sm
		instances += mi.multimesh.instance_count
		add_child(mi)
		_scatter.append(mi)
	timings["scatter_ms"] = float(Time.get_ticks_usec() - t3) / 1000.0
	timings["scatter"] = instances

	overlay.upload()
	timings["total_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	timings["chunks"] = _chunks.size()
	return timings


## Everything both the terrain and the road material need to agree on. Factored out so the two
## cannot drift — a road whose `map_extent_m` disagreed with the ground's would sample the overlay
## a tile off and outline the wrong region.
func _apply_overlay_uniforms(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("overlay_tex", overlay.texture)
	mat.set_shader_parameter("map_extent_m", float(md.size) * md.tile_m)
	mat.set_shader_parameter("tile_m", md.tile_m)

	mat.set_shader_parameter("border_width_m", cfg.f("overlay.border_width_m", 1.4))
	mat.set_shader_parameter("glow_width_m", cfg.f("overlay.glow_width_m", 3.5))
	mat.set_shader_parameter("fill_strength", cfg.f("overlay.fill_strength", 0.10))
	mat.set_shader_parameter("emission_strength", cfg.f("overlay.emission_strength", 1.6))
	mat.set_shader_parameter("glow_strength", cfg.f("overlay.glow_strength", 0.30))
	mat.set_shader_parameter("path_fill_strength", cfg.f("overlay.path_fill_strength", 0.30))

	mat.set_shader_parameter("move_color", cfg.color("overlay.move_color", Color(1, 0.7, 0.24)))
	mat.set_shader_parameter(
		"move_far_color", cfg.color("overlay.move_far_color", Color(0.69, 0.46, 0.23))
	)
	mat.set_shader_parameter(
		"exposed_color", cfg.color("overlay.exposed_color", Color(1, 0.33, 0.21))
	)
	mat.set_shader_parameter(
		"hull_down_color", cfg.color("overlay.hull_down_color", Color(0.37, 0.84, 0.41))
	)
	mat.set_shader_parameter("hover_color", cfg.color("overlay.hover_color", Color(1, 1, 1)))
	mat.set_shader_parameter(
		"path_color", cfg.color("overlay.path_color", Color(1, 0.94, 0.82))
	)

	mat.set_shader_parameter(
		"overwatch_color", cfg.color("overlay.overwatch_color", Color(1, 0.54, 0.30))
	)
	mat.set_shader_parameter(
		"overwatch_fill_strength", cfg.f("overlay.overwatch_fill_strength", 0.16)
	)
	mat.set_shader_parameter(
		"overwatch_max_overlaps", float(cfg.i("overlay.overwatch_max_overlaps", 3))
	)


func extent_m() -> float:
	return float(md.size) * md.tile_m


## World position of a tile's center, on its surface.
func tile_center(tile: int) -> Vector3:
	return Vector3(
		(float(md.tx(tile)) + 0.5) * md.tile_m,
		float(md.level[tile]) * md.quant,
		(float(md.ty(tile)) + 0.5) * md.tile_m
	)


## Tile under a world position, or -1 off the map.
func tile_at(world: Vector3) -> int:
	var x: int = int(floor(world.x / md.tile_m))
	var y: int = int(floor(world.z / md.tile_m))
	if x < 0 or x >= md.size or y < 0 or y >= md.size:
		return -1
	return y * md.size + x


func _clear() -> void:
	for c: MeshInstance3D in _chunks:
		c.queue_free()
	_chunks.clear()
	if _water != null:
		_water.queue_free()
		_water = null
	if _roads != null:
		_roads.queue_free()
		_roads = null
	for s2: MultiMeshInstance3D in _scatter:
		s2.queue_free()
	_scatter.clear()
