class_name TacticalCamera
extends Node3D

## Free flying camera above the battlefield.
##
## WASD pans, the wheel zooms, right-drag orbits, and the screen edges scroll. Clamped to the map
## bounds and to a minimum height above the terrain, because the two ways a free camera goes wrong
## are ending up inside a hill and ending up somewhere with no map in view.
##
## The acceptance check is "you can inspect any part of the map in under three seconds", which is
## really a statement about pan speed and zoom range rather than about features.

@export var camera: Camera3D

var cfg: Config
var view: TerrainView

# Target versus rendered. Input writes the targets; `_process` eases the rendered values toward
# them and rebuilds the transform. Splitting the two is what lets selecting a unit glide instead of
# teleporting — and it makes the camera ride over a terrace rather than stepping across it, because
# it is the *target* height that snaps to the ground and the eased value that the player sees.
var _focus: Vector3 = Vector3.ZERO
var _target_focus: Vector3 = Vector3.ZERO
var _distance: float = 420.0
var _target_distance: float = 420.0
var _yaw: float = 0.0
var _pitch: float = -46.0
var _orbiting: bool = false
var _edge_scroll_enabled: bool = true

var _pan_speed: float
var _fast_mult: float
var _zoom_step: float
var _min_above: float
var _max_height: float
var _orbit_sens: float
var _edge_margin: float
var _edge_speed: float
var _min_pitch: float
var _max_pitch: float
var _bounds_margin: float
var _min_distance: float
var _focus_distance: float
var _focus_lerp: float
var _zoom_lerp: float
var _focus_only_zooms_in: bool


func setup(config: Config, terrain: TerrainView) -> void:
	cfg = config
	view = terrain

	_pan_speed = cfg.f("camera.pan_speed_m", 260.0)
	_fast_mult = cfg.f("camera.fast_multiplier", 3.0)
	_zoom_step = cfg.f("camera.zoom_step", 0.12)
	_min_above = cfg.f("camera.min_height_above_ground_m", 12.0)
	_max_height = cfg.f("camera.max_height_m", 1400.0)
	_orbit_sens = cfg.f("camera.orbit_sensitivity", 0.32)
	_edge_margin = cfg.f("camera.edge_scroll_margin_px", 6.0)
	_edge_speed = cfg.f("camera.edge_scroll_speed_m", 220.0)
	_min_pitch = cfg.f("camera.min_pitch_deg", -85.0)
	_max_pitch = cfg.f("camera.max_pitch_deg", -12.0)
	_bounds_margin = cfg.f("camera.bounds_margin_m", 200.0)
	_min_distance = cfg.f("camera.min_distance_m", 25.0)
	_focus_distance = cfg.f("camera.focus_distance_m", 130.0)
	_focus_lerp = cfg.f("camera.focus_lerp_rate", 6.0)
	_zoom_lerp = cfg.f("camera.zoom_lerp_rate", 12.0)
	_focus_only_zooms_in = cfg.b("camera.focus_only_zooms_in", true)

	_distance = cfg.f("camera.start_height_m", 420.0)
	_target_distance = _distance
	_pitch = cfg.f("camera.start_pitch_deg", -46.0)

	var extent: float = view.extent_m()
	_target_focus = Vector3(extent * 0.5, 0.0, extent * 0.5)
	_clamp_target()
	_focus = _target_focus
	_apply()


func focus_distance() -> float:
	return _focus_distance


func set_edge_scroll(enabled: bool) -> void:
	_edge_scroll_enabled = enabled


## Put the camera over a tile without changing the viewing angle.
##
## A positive `distance` also sets the zoom; -1 leaves it alone. With `camera.focus_only_zooms_in`
## the distance is only ever tightened, so selecting a unit pulls you in when you were looking at
## the whole map but does not yank you back out when you had deliberately zoomed closer.
## `instant` skips the glide, which is what boot and a map regeneration want.
func look_at_tile(tile: int, distance: float = -1.0, instant: bool = false) -> void:
	_target_focus = view.tile_centre(tile)
	if distance > 0.0:
		_target_distance = minf(_target_distance, distance) if _focus_only_zooms_in else distance
	_clamp_target()
	if instant:
		_focus = _target_focus
		_distance = _target_distance
		_apply()


## Explicitly take me to this tile, at the focus distance, whatever the zoom was. The F key is not
## a side effect of something else, so it overrides the only-zooms-in rule.
func recentre_on(tile: int) -> void:
	_target_focus = view.tile_centre(tile)
	_target_distance = _focus_distance
	_clamp_target()


func focus_point() -> Vector3:
	return _focus


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_target_distance *= 1.0 - _zoom_step
					_clamp_target()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_target_distance *= 1.0 + _zoom_step
					_clamp_target()
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
				Input.set_mouse_mode(
					Input.MOUSE_MODE_CAPTURED if _orbiting else Input.MOUSE_MODE_VISIBLE
				)

	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * _orbit_sens
		_pitch = clampf(_pitch - mm.relative.y * _orbit_sens, _min_pitch, _max_pitch)
		_apply()


func _process(delta: float) -> void:
	_ease(delta)

	var move := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		move.y += 1.0
	if Input.is_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move.x += 1.0

	var speed: float = _pan_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= _fast_mult

	if _edge_scroll_enabled and not _orbiting:
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var mouse: Vector2 = get_viewport().get_mouse_position()
		if mouse.x >= 0.0 and mouse.y >= 0.0 and mouse.x < vp.x and mouse.y < vp.y:
			if mouse.x < _edge_margin:
				move.x -= _edge_speed / speed
			elif mouse.x > vp.x - _edge_margin:
				move.x += _edge_speed / speed
			if mouse.y < _edge_margin:
				move.y -= _edge_speed / speed
			elif mouse.y > vp.y - _edge_margin:
				move.y += _edge_speed / speed

	if move == Vector2.ZERO:
		return

	# Pan across the ground in the direction the camera faces, not along the world axes — dragging
	# right should move the view right whatever the orbit angle happens to be.
	var yaw_rad: float = deg_to_rad(_yaw)
	var forward := Vector3(-sin(yaw_rad), 0.0, -cos(yaw_rad))
	var right := Vector3(cos(yaw_rad), 0.0, -sin(yaw_rad))

	# Pan faster when zoomed out. Otherwise crossing the map from altitude takes as long as
	# crossing one tile from ground level, and the three-second inspection target is unreachable.
	var scaled: float = speed * delta * clampf(_distance / 300.0, 0.35, 3.5)
	_target_focus += (right * move.x + forward * -move.y) * scaled
	_clamp_target()


## Ease the rendered focus and distance toward their targets. Frame-rate independent: the
## exponential form gives the same settling time whatever the frame took.
func _ease(delta: float) -> void:
	var kf: float = 1.0 - exp(-_focus_lerp * delta)
	var kz: float = 1.0 - exp(-_zoom_lerp * delta)
	var next_focus: Vector3 = _focus.lerp(_target_focus, kf)
	var next_distance: float = lerpf(_distance, _target_distance, kz)

	if (
		next_focus.distance_squared_to(_focus) < 1e-6
		and absf(next_distance - _distance) < 1e-4
	):
		return

	_focus = next_focus
	_distance = next_distance
	_apply()


## Keep the target inside the map and on the ground. Separate from `_apply` because it operates on
## where the camera is going, not on where it is.
func _clamp_target() -> void:
	var extent: float = view.extent_m()
	_target_distance = clampf(_target_distance, _min_distance, _max_height)
	_target_focus.x = clampf(_target_focus.x, -_bounds_margin, extent + _bounds_margin)
	_target_focus.z = clampf(_target_focus.z, -_bounds_margin, extent + _bounds_margin)

	# Keep the focus on the ground so orbiting pivots about the terrain rather than about a point
	# floating in the air.
	var tile: int = view.tile_at(_target_focus)
	_target_focus.y = view.md.height_m(tile) if tile >= 0 else 0.0


func _apply() -> void:
	var pitch_rad: float = deg_to_rad(_pitch)
	var yaw_rad: float = deg_to_rad(_yaw)
	var offset := Vector3(
		cos(pitch_rad) * sin(yaw_rad),
		-sin(pitch_rad),
		cos(pitch_rad) * cos(yaw_rad)
	) * _distance

	var pos: Vector3 = _focus + offset

	# Never inside a hill. The clamp is against the terrain under the camera, not under the focus.
	var over: int = view.tile_at(pos)
	if over >= 0:
		var floor_y: float = view.md.height_m(over) + _min_above
		if pos.y < floor_y:
			pos.y = floor_y

	global_position = pos
	look_at(_focus, Vector3.UP)
