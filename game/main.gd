extends Node3D

## Boot. Loads a cached map if one exists for the seed, otherwise generates and caches it.
##
## The cache is what makes iterating on anything visual bearable — full generation is minutes, and
## nobody should pay that to adjust a color.

const CACHE_DIR := "user://maps"

@export var master_seed: int = 12345
@export var use_small_map: bool = false
## A mission file to boot straight into, or empty for the sandbox. The M key toggles the dig-in
## mission at runtime either way.
@export var scenario_path: String = ""

var _scenario: Scenario = null
## The open-battlefield mode: no scenario, but side 2 is the machine. Hot-seat when false.
var _vs_ai: bool = false
var _menu: MainMenu = null

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

	_menu = MainMenu.new()
	_menu.name = "MainMenu"
	add_child(_menu)
	_menu.configure(cfg)
	_menu.mission_picked.connect(_on_menu_mission)
	_menu.open_battlefield_picked.connect(_on_menu_open_battlefield)
	_menu.hotseat_picked.connect(_on_menu_hotseat)
	_menu.quit_picked.connect(func() -> void: get_tree().quit())
	# Resume needs no handler — the pick already closed the menu, and the board is still there.

	# The export is a dev convenience: name a mission and skip the menu. Everyone else picks.
	if scenario_path != "":
		_scenario = Scenario.load_file(scenario_path)
		_load_or_generate()
	else:
		hud.set_line("00_status", "Hull Down")
		_menu.open(false)


func _on_menu_mission(path: String) -> void:
	_scenario = Scenario.load_file(path)
	_vs_ai = false
	md = null
	_load_or_generate()


func _on_menu_open_battlefield() -> void:
	# The current seed, not a fresh one — it is almost certainly cached, and the first pick of the
	# evening should not cost minutes of generation. R deals new ground.
	_scenario = null
	_vs_ai = true
	md = null
	_load_or_generate()


func _on_menu_hotseat() -> void:
	_scenario = null
	_vs_ai = false
	md = null
	_load_or_generate()


func _load_or_generate() -> void:
	# A mission names its map — the seed is part of the scenario, not a preference.
	if _scenario != null:
		master_seed = _scenario.map_seed
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


## The sandbox deployment, or the scenario's — docs/decisions/0041.
func _spawn_units() -> void:
	_clear_units()
	# A fresh match must not inherit the last one's verdict.
	hud.clear_line("85_outcome")

	if _scenario != null:
		match_state = _scenario.build_state(md, cfg)
	else:
		match_state = Deployment.deploy(md, cfg)
	if match_state.units.is_empty():
		hud.set_line("30_units", "no passable tile to deploy onto")
		return

	# One view per unit, index-parallel to `match_state.units` — identity is positional (0022) and
	# `ActionPlayer._view_for` indexes straight into this array. A view is built for *every* unit,
	# including ones the player will never see: whether it is drawn is `ViewState`'s answer and it can
	# change on any tile of any move (0034), so the node has to exist and start hidden.
	#
	# It is handed values, never the `UnitState` — see the `TankView` docstring for why.
	for k: int in match_state.units.size():
		var u: UnitState = match_state.units[k]
		var v := TankView.new()
		v.name = "Tank_%d" % k
		add_child(v)
		v.setup(cfg, view, u.side, u.unit_type, u.mp_max)
		tank_views.append(v)

	director = CameraDirector.new()
	director.name = "CameraDirector"
	add_child(director)
	director.setup(cam, cfg)

	controller = PlayerController.new()
	controller.name = "PlayerController"
	add_child(controller)
	controller.setup(md, cfg, view, match_state, tank_views, cam, director, hud)

	# A mission puts the machine on every side but the player's. The human plays the force that
	# deploys on the objectives — the defender is what the dig-in mission is about — falling back
	# to side 1 for a scenario without one.
	if _scenario != null:
		var human: int = 1
		for f: Scenario.Force in _scenario.forces:
			if f.deploy == &"objectives":
				human = f.side
		var machines: Dictionary = {}
		for f2: Scenario.Force in _scenario.forces:
			if f2.side != human:
				machines[f2.side] = UtilityPolicy.new(md.master_seed + f2.side)
		controller.configure_opponents(machines, human, _scenario)
	elif _vs_ai:
		# The open battlefield: the symmetric sandbox deployment, but side 2 is the machine.
		controller.configure_opponents({2: UtilityPolicy.new(md.master_seed + 2)}, 1, null)

	controller.prime_knowledge()
	controller.selection_changed.connect(_on_selection_changed)

	hud.prev_unit_pressed.connect(_on_prev_unit)
	hud.next_unit_pressed.connect(_on_next_unit)
	hud.center_pressed.connect(_on_center)
	hud.end_turn_pressed.connect(_on_end_turn)
	hud.roster_unit_picked.connect(_on_roster_pick)
	hud.turret_left_pressed.connect(_on_turret_left)
	hud.turret_right_pressed.connect(_on_turret_right)
	hud.overwatch_pressed.connect(_on_overwatch_toggle)

	if _scenario != null:
		hud.set_line("30_units", "mission: %s — turn limit %d" % [
			_scenario.name, _scenario.turn_limit
		])
	else:
		hud.set_line("30_units", "%s — %d units a side — %s" % [
			"open battlefield" if _vs_ai else "hot-seat",
			cfg.i("turn.units_per_side", 2),
			cfg.unit(cfg.default_unit_name()).get("display_name", cfg.default_unit_name()),
		])

	# Open on the first unit rather than gliding in from the middle of the map.
	var first: UnitState = match_state.selected_unit()
	if first != null:
		cam.look_at_tile(first.tile, cam.focus_distance(), true)
		director.set_tank(tank_views[match_state.selected])

	# If the mission opens on a machine side, its turns play out before the player holds the board.
	controller.begin_match()


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
		if hud.center_pressed.is_connected(_on_center):
			hud.center_pressed.disconnect(_on_center)
		if hud.end_turn_pressed.is_connected(_on_end_turn):
			hud.end_turn_pressed.disconnect(_on_end_turn)
		if hud.roster_unit_picked.is_connected(_on_roster_pick):
			hud.roster_unit_picked.disconnect(_on_roster_pick)
		if hud.turret_left_pressed.is_connected(_on_turret_left):
			hud.turret_left_pressed.disconnect(_on_turret_left)
		if hud.turret_right_pressed.is_connected(_on_turret_right):
			hud.turret_right_pressed.disconnect(_on_turret_right)
		if hud.overwatch_pressed.is_connected(_on_overwatch_toggle):
			hud.overwatch_pressed.disconnect(_on_overwatch_toggle)
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


## Clicking a roster row. `select_unit` refuses anything that is not the active side's, so a row for a
## ghost, a wreck or an enemy is inert without this needing to know which it was.
func _on_roster_pick(index: int) -> void:
	if controller != null:
		controller.select_unit(index)


func _on_prev_unit() -> void:
	if controller != null:
		controller.cycle_unit(-1)


func _on_next_unit() -> void:
	if controller != null:
		controller.cycle_unit(1)


func _on_end_turn() -> void:
	if controller != null:
		controller.end_turn()


func _on_center() -> void:
	if controller != null:
		controller.recenter()


func _on_turret_left() -> void:
	if controller != null:
		controller.traverse_turret(-1)


func _on_turret_right() -> void:
	if controller != null:
		controller.traverse_turret(1)


func _on_overwatch_toggle() -> void:
	if controller != null:
		controller.toggle_overwatch_aim()


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = cfg.color("look.sky_top", Color(0.49, 0.62, 0.77))
	mat.sky_horizon_color = cfg.color("look.sky_horizon", Color(0.72, 0.77, 0.80))
	mat.ground_bottom_color = mat.sky_horizon_color.darkened(0.3)
	mat.ground_horizon_color = mat.sky_horizon_color
	sky.sky_material = mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = cfg.f("look.ambient_energy", 0.42)

	# A little depth fog. At two kilometers the far side of the map otherwise reads at exactly the
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


## An action is being replayed on screen. Nothing that could change the simulation underneath one is
## allowed through — the controller guards its own entry points, and this guards the two keys that
## do not go through it. docs/decisions/0022.
func _busy() -> bool:
	return controller != null and controller.is_busy()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey

	# While the menu is up it owns the keyboard: ESC resumes (or quits, if there is nothing to
	# resume yet), everything else is inert. The scrim already keeps the mouse to itself.
	if _menu != null and _menu.is_open():
		if key.keycode == KEY_ESCAPE:
			if controller != null:
				_menu.close()
			else:
				get_tree().quit()
		return

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
		KEY_ENTER, KEY_KP_ENTER, KEY_BACKSPACE:
			if controller != null:
				controller.end_turn()
		KEY_O:
			# Lay overwatch down the bearing to whatever the mouse is over. Costs the whole turn.
			if controller != null:
				controller.set_overwatch(controller.hover_tile())
		KEY_QUOTELEFT:
			# The second cycling key: the whole roster in fixed order, spent units included.
			# Tab stays "what should I do next" — docs/decisions/0032.
			if controller != null:
				controller.cycle_roster(-1 if key.shift_pressed else 1)
		KEY_Z:
			# Traverse the gun 45° either way. Free and legal at zero movement points — the hull is
			# what costs, and that is the trade (docs/decisions/0035).
			if controller != null:
				controller.traverse_turret(-1)
		KEY_X:
			if controller != null:
				controller.traverse_turret(1)
		KEY_F:
			if controller != null:
				controller.recenter()
		KEY_V:
			if controller != null:
				controller.cycle_overlay()
		KEY_Q:
			if cam != null:
				cam.orbit_step(-1)
		KEY_E:
			if cam != null:
				cam.orbit_step(1)
		KEY_1:
			if controller != null:
				controller.set_playback_speed(ActionPlayer.Speed.NORMAL)
		KEY_2:
			if controller != null:
				controller.set_playback_speed(ActionPlayer.Speed.FAST)
		KEY_3:
			if controller != null:
				controller.set_playback_speed(ActionPlayer.Speed.INSTANT)
		KEY_SPACE:
			if controller != null:
				controller.skip_playback()
		KEY_G:
			# Deliberately *not* gated on `_busy()`, unlike everything else here. Watching your own
			# tank drive from the turret is the best thing this view does, and it cannot desynchronise
			# anything: the gunner camera reads the tank's pose off the view every frame and writes
			# nothing back. Orders and hover stay suspended while it is up, as they always were.
			if director != null:
				var on: bool = director.toggle()
				hud.set_line("35_view", "gunner view" if on else "")
				if not on:
					hud.clear_line("35_view")
					# Hover was suspended for the whole visit, so the tile readout under the cursor
					# is whatever it was before. Nothing else refreshes it until the mouse moves.
					if controller != null:
						controller.refresh_hover()
		KEY_M:
			# Toggle the dig-in mission — 2f. Into it: the scenario names the map and the machine
			# takes the attacker. Out of it: back to the hot-seat sandbox on the same map.
			if _busy():
				return
			if _scenario == null:
				_scenario = Scenario.load_file("res://data/scenarios/dig_in.json")
			else:
				_scenario = null
			md = null
			_load_or_generate()
		KEY_R:
			# Regenerate with the next seed, bypassing the cache for the new one only.
			if _busy():
				return
			if _scenario != null:
				return   # a mission's map is part of the mission; leave it with M first
			master_seed += 1
			md = null
			_load_or_generate()
		KEY_ESCAPE:
			# The menu, not the exit — quitting lives on the menu's own button. Not gated on
			# `_busy()`: opening a purely visual layer over a replay changes nothing underneath.
			if _menu != null:
				_menu.open(controller != null)


func _process(_delta: float) -> void:
	hud.set_line("90_fps", "%d fps" % Engine.get_frames_per_second())
