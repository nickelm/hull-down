extends SceneTree

## Render the map from a few fixed viewpoints and save PNGs.
##
##   godot --path . --script res://tools/screenshot.gd -- --seed 12345 --out dumps/shots
##
## Not headless: --headless has no renderer, so this opens a window, waits for the frames to
## actually draw, and grabs the viewport. It exists so reviewing 4.9, 4.10 and 4.14 is one command
## instead of a manual fly-around, and so a visual regression is something that can be looked at
## side by side rather than remembered.

const CACHE_DIR := "user://maps"


## Frames to let the renderer settle before the first grab, and between grabs. The first frame runs
## before the meshes are in the tree, and shadow atlases and the sky take another one or two.
const SETTLE_FRAMES := 4

var _shots: Array = []
var _camera: Camera3D
var _out_dir: String
var _seed: int
var _index: int = -1
var _wait: int = SETTLE_FRAMES


func _initialize() -> void:
	var cli := Cli.from_os()
	_seed = cli.int_opt("seed", 12345)
	_out_dir = cli.str_opt("out", "res://dumps/shots")
	var small: bool = cli.flag("small")

	var cfg := Config.load_default()
	var md: MapData = _load_or_generate(cfg, _seed, small)
	if md == null:
		print("could not produce a map for seed %d" % _seed)
		quit(1)
		return

	var root: Node3D = _build_world(cfg, md)
	get_root().add_child(root)

	Cli.ensure_dir(_out_dir + "/x")
	_shots = _viewpoints(md)
	_camera = root.get_node("Camera3D")


## Driven from _process rather than by awaiting inside _initialize. `_initialize` runs before the
## main loop starts iterating, so an await there never resumes and the process exits with the
## screenshots untaken.
func _process(_delta: float) -> bool:
	if _camera == null:
		return true

	if _wait > 0:
		_wait -= 1
		return false

	# Grab the frame that was rendered for the pose set last time round.
	if _index >= 0 and _index < _shots.size():
		var name: String = str(_shots[_index]["name"])
		var img: Image = get_root().get_texture().get_image()
		var path: String = "%s/seed_%d_%s.png" % [_out_dir, _seed, name]
		print("  %s" % path if img.save_png(path) == OK else "  FAILED to write %s" % path)

	_index += 1
	if _index >= _shots.size():
		return true

	var shot: Dictionary = _shots[_index]
	_camera.global_position = shot["pos"]
	_camera.look_at(shot["look"], Vector3.UP)
	_camera.fov = float(shot.get("fov", 60.0))
	_wait = 2
	return false


func _load_or_generate(cfg: Config, master_seed: int, small: bool) -> MapData:
	var path: String = "%s/seed_%d%s.hdmap" % [CACHE_DIR, master_seed, "_small" if small else ""]
	if FileAccess.file_exists(path):
		var cached: MapData = MapCodec.load_map(path)
		if cached != null:
			print("loaded %s" % path)
			return cached

	print("generating seed %d..." % master_seed)
	var params: MapGenerator.Params = (
		MapGenerator.Params.small(cfg) if small else MapGenerator.Params.from_config(cfg)
	)
	var md: MapData = MapGenerator.generate(cfg, master_seed, params, Cli.printer())
	if md != null:
		MapCodec.save(md, path)
	return md


func _build_world(cfg: Config, md: MapData) -> Node3D:
	var root := Node3D.new()

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = cfg.color("look.sky_top", Color(0.49, 0.62, 0.77))
	sky_mat.sky_horizon_color = cfg.color("look.sky_horizon", Color(0.72, 0.77, 0.80))
	sky_mat.ground_bottom_color = sky_mat.sky_horizon_color.darkened(0.3)
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = cfg.f("look.ambient_energy", 0.42)
	env.fog_enabled = true
	env.fog_density = cfg.f("look.fog_density", 0.0007)
	env.fog_light_color = sky_mat.sky_horizon_color

	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = cfg.f("look.sun_energy", 1.15)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1200.0
	sun.rotation = Vector3(
		-deg_to_rad(cfg.f("look.sun_altitude_deg", 46.0)),
		deg_to_rad(cfg.f("look.sun_azimuth_deg", 305.0)),
		0.0
	)
	root.add_child(sun)

	var view := TerrainView.new()
	root.add_child(view)
	var timings: Dictionary = view.build(md, cfg)
	print("mesh: %d chunks in %.0f ms" % [int(timings["chunks"]), float(timings["total_ms"])])

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.current = true
	cam.far = 8000.0
	root.add_child(cam)

	return root


## Fixed viewpoints, so two runs of the same seed are comparable and two seeds are comparable to
## each other.
##
## Every camera height is measured from the map's highest ground rather than from zero. Anchoring
## to zero puts the low viewpoints inside a hill on any map with relief, which is how the first
## pass produced a "ground level" shot looking at the underside of a ridge.
func _viewpoints(md: MapData) -> Array:
	var extent: float = float(md.size) * md.tile_m
	var top: float = 0.0
	for i: int in md.n:
		top = maxf(top, float(md.level[i]) * md.quant)

	var mid := Vector3(extent * 0.5, 0.0, extent * 0.5)
	var mid_tile: int = md.idx(md.size / 2, md.size / 2)
	mid.y = md.height_m(mid_tile)

	# A low oblique across an objective is the shot that answers "can you read the terrain". The
	# top-down view flatters relief the player never sees from that angle.
	var obj: int = md.objectives[0] if md.objectives.size() > 0 else mid_tile
	var obj_pos := Vector3(
		(float(md.tx(obj)) + 0.5) * md.tile_m,
		md.height_m(obj),
		(float(md.ty(obj)) + 0.5) * md.tile_m
	)

	return [
		{
			"name": "overview",
			"pos": Vector3(mid.x, top + extent * 0.58, mid.z + extent * 0.48),
			"look": mid,
		},
		{
			"name": "oblique",
			"pos": Vector3(mid.x - extent * 0.32, top + extent * 0.17, mid.z + extent * 0.32),
			"look": mid,
		},
		{
			"name": "objective",
			"pos": obj_pos + Vector3(-190.0, 120.0, 190.0),
			"look": obj_pos,
			"fov": 50.0,
		},
		{
			# Turret height above the objective, looking out across the ground beyond it. This is
			# the view a tank commander has, and the one hull-down positions have to read in.
			"name": "gunner",
			"pos": obj_pos + Vector3(0.0, 2.6, 0.0),
			"look": obj_pos + Vector3(320.0, -6.0, -320.0),
			"fov": 32.0,
		},
	]
