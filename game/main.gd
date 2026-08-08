extends Node3D

## Boot. Loads a cached map if one exists for the seed, otherwise generates and caches it.
##
## The cache is what makes iterating on anything visual bearable — full generation is minutes, and
## nobody should pay that to adjust a colour.

const CACHE_DIR := "user://maps"

@export var master_seed: int = 12345
@export var use_small_map: bool = false

var cfg: Config
var md: MapData
var view: TerrainView
var cam: TacticalCamera
var hud: Hud
var match_state: MatchState
var tank_views: Array[TankView] = []
var director: CameraDirector
var controller: PlayerController

var _sun: DirectionalLight3D
var _wireframe: bool = false


func _ready() -> void:
	cfg = Config.load_default()
	_build_environment()

	view = TerrainView.new()
	view.name = "TerrainView"
	add_child(view)

	cam = TacticalCamera.new()
	cam.name = "TacticalCamera"
	var camera3d := Camera3D.new()
	camera3d.current = true
	camera3d.far = 6000.0
	cam.add_child(camera3d)
	cam.camera = camera3d
	add_child(cam)

	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.configure(cfg)

	_load_or_generate()


func _load_or_generate() -> void:
	var path: String = "%s/seed_%d%s.hdmap" % [
		CACHE_DIR, master_seed, "_small" if use_small_map else ""
	]

	var t0: int = Time.get_ticks_usec()
	var cached: bool = FileAccess.file_exists(path)
	if cached:
		md = MapCodec.load_map(path)

	if md == null:
		cached = false
		hud.set_line("00_status", "Generating seed %d — this takes a while..." % master_seed)
		# Let the label actually paint before the main thread disappears into generation.
		await get_tree().process_frame
		await get_tree().process_frame

		var params: MapGenerator.Params = (
			MapGenerator.Params.small(cfg) if use_small_map
			else MapGenerator.Params.from_config(cfg)
		)
		md = MapGenerator.generate(cfg, master_seed, params)
		if md == null:
			hud.set_line("00_status", "Seed %d could not be repaired into a connected map." % master_seed)
			return
		MapCodec.save(md, path)

	var load_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var timings: Dictionary = view.build(md, cfg)
	cam.setup(cfg, view)

	hud.set_line("00_status", "Hull Down — seed %d  (%s in %.0f ms)" % [
		master_seed, "cached" if cached else "generated", load_ms
	])
	hud.set_line("10_map", "%d x %d tiles, %.1f%% drivable, %.1f%% escarpment edges" % [
		md.size, md.size, md.passable_fraction() * 100.0, md.escarpment_fraction() * 100.0
	])
	hud.set_line("20_mesh", "mesh %d chunks in %.0f ms (terrain %.0f, water %.0f, roads %.0f, %d props %.0f)" % [
		int(timings["chunks"]), float(timings["total_ms"]), float(timings["terrain_ms"]),
		float(timings["water_ms"]), float(timings["roads_ms"]),
		int(timings["scatter"]), float(timings["scatter_ms"]),
	])

	_spawn_units()


## Two units a side, deployed into their zones, facing across the map.
func _spawn_units() -> void:
	_clear_units()

	match_state = Deployment.deploy(md, cfg)
	if match_state.units.is_empty():
		hud.set_line("30_units", "no passable tile to deploy onto")
		return

	for k: int in match_state.units.size():
		var v := TankView.new()
		v.name = "Tank_%d" % k
		add_child(v)
		v.setup(match_state.units[k], cfg, view)
		tank_views.append(v)

	director = CameraDirector.new()
	director.name = "CameraDirector"
	add_child(director)
	director.setup(cam, cfg)

	controller = PlayerController.new()
	controller.name = "PlayerController"
	add_child(controller)
	controller.setup(md, cfg, view, match_state, tank_views, cam, hud)
	controller.selection_changed.connect(_on_selection_changed)

	hud.prev_unit_pressed.connect(_on_prev_unit)
	hud.next_unit_pressed.connect(_on_next_unit)
	hud.end_turn_pressed.connect(_on_end_turn)

	hud.set_line("30_units", "%d units a side — %s" % [
		cfg.i("turn.units_per_side", 2),
		cfg.unit(cfg.default_unit_name()).get("display_name", cfg.default_unit_name()),
	])

	# Open on the first unit rather than gliding in from the middle of the map.
	var first: UnitState = match_state.selected_unit()
	if first != null:
		cam.look_at_tile(first.tile, cam.focus_distance(), true)
		director.set_tank(tank_views[match_state.selected])


func _clear_units() -> void:
	for v: TankView in tank_views:
		v.queue_free()
	tank_views.clear()

	if controller != null:
		# The HUD outlives the controller across a regeneration, so its signals have to be let go
		# or the next controller inherits a connection to a freed object.
		if hud.prev_unit_pressed.is_connected(_on_prev_unit):
			hud.prev_unit_pressed.disconnect(_on_prev_unit)
		if hud.next_unit_pressed.is_connected(_on_next_unit):
			hud.next_unit_pressed.disconnect(_on_next_unit)
		if hud.end_turn_pressed.is_connected(_on_end_turn):
			hud.end_turn_pressed.disconnect(_on_end_turn)
		controller.queue_free()
		controller = null
	if director != null:
		director.queue_free()
		director = null


func _on_selection_changed(index: int) -> void:
	if index < 0 or index >= tank_views.size():
		return
	director.set_tank(tank_views[index])
	var u: UnitState = match_state.unit(index)
	if u != null:
		cam.look_at_tile(u.tile, cam.focus_distance())


func _on_prev_unit() -> void:
	if controller != null:
		controller.cycle_unit(-1)


func _on_next_unit() -> void:
	if controller != null:
		controller.cycle_unit(1)


func _on_end_turn() -> void:
	if controller != null:
		controller.end_turn()


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = cfg.colour("look.sky_top", Color(0.49, 0.62, 0.77))
	mat.sky_horizon_color = cfg.colour("look.sky_horizon", Color(0.72, 0.77, 0.80))
	mat.ground_bottom_color = mat.sky_horizon_color.darkened(0.3)
	mat.ground_horizon_color = mat.sky_horizon_color
	sky.sky_material = mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = cfg.f("look.ambient_energy", 0.42)

	# A little depth fog. At two kilometres the far side of the map otherwise reads at exactly the
	# same contrast as the near side and the relief flattens out.
	env.fog_enabled = true
	env.fog_density = cfg.f("look.fog_density", 0.0007)
	env.fog_light_color = mat.sky_horizon_color

	var world := WorldEnvironment.new()
	world.environment = env
	world.name = "WorldEnvironment"
	add_child(world)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.light_energy = cfg.f("look.sun_energy", 1.15)
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 900.0
	var az: float = deg_to_rad(cfg.f("look.sun_azimuth_deg", 305.0))
	var alt: float = deg_to_rad(cfg.f("look.sun_altitude_deg", 46.0))
	_sun.rotation = Vector3(-alt, az, 0.0)
	add_child(_sun)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey

	match key.keycode:
		KEY_F3:
			_wireframe = not _wireframe
			get_viewport().debug_draw = (
				Viewport.DEBUG_DRAW_WIREFRAME if _wireframe else Viewport.DEBUG_DRAW_DISABLED
			)
		KEY_TAB:
			# Reaches here only because every HUD button sets focus_mode = FOCUS_NONE. With a
			# focused Control anywhere, Godot's GUI eats Tab as ui_focus_next first.
			if controller != null:
				controller.cycle_unit(-1 if key.shift_pressed else 1)
		KEY_ENTER, KEY_KP_ENTER:
			if controller != null:
				controller.end_turn()
		KEY_F:
			if controller != null:
				controller.recentre()
		KEY_V:
			if controller != null:
				controller.cycle_overlay()
		KEY_G:
			if director != null:
				var on: bool = director.toggle()
				hud.set_line("35_view", "gunner view" if on else "")
				if not on:
					hud.clear_line("35_view")
		KEY_R:
			# Regenerate with the next seed, bypassing the cache for the new one only.
			master_seed += 1
			md = null
			_load_or_generate()
		KEY_ESCAPE:
			get_tree().quit()


func _process(_delta: float) -> void:
	hud.set_line("90_fps", "%d fps" % Engine.get_frames_per_second())
