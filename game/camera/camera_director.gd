class_name CameraDirector
extends Node3D

## Switches between the tactical camera and the gunner view.
##
## The gunner view is not a cosmetic flourish. The visibility overlay is a claim — "a tank here
## would be hull down to you" — and the only honest way to check a claim like that is to put the
## camera exactly where the rules say the observer's eye is and look. Where the two disagree, the
## overlay is wrong.

var tactical: TacticalCamera
var gunner: Camera3D
var cfg: Config

var _tank: TankView
var _in_gunner: bool = false

# Free look, relative to the hull's facing. Turret direction carries no rules weight in iteration 1
# — nothing reads it, and LOS is computed from the tile — so looking around costs nothing and is
# the only way to use this view for what it is for, which is checking the overlay against what a
# commander would actually see.
var _look_yaw: float = 0.0
var _look_pitch: float = 0.0
var _looking: bool = false
var _sens: float
var _min_pitch: float
var _max_pitch: float

## Optic magnification, as a field of view. Narrower is more magnified.
var _fov: float = 28.0
var _base_fov: float = 28.0
var _min_fov: float
var _max_fov: float
var _zoom_step: float
var _sens_scaling: float


func setup(tactical_camera: TacticalCamera, config: Config) -> void:
	tactical = tactical_camera
	cfg = config

	_base_fov = cfg.f("camera.gunner_fov_deg", 28.0)
	_fov = _base_fov
	_min_fov = cfg.f("camera.gunner_fov_min_deg", 6.0)
	_max_fov = cfg.f("camera.gunner_fov_max_deg", 45.0)
	_zoom_step = cfg.f("camera.gunner_zoom_step", 0.12)
	_sens_scaling = cfg.f("camera.gunner_zoom_sens_scaling", 1.0)

	gunner = Camera3D.new()
	gunner.name = "GunnerCamera"
	gunner.fov = _fov
	gunner.far = 6000.0
	gunner.current = false
	add_child(gunner)

	_sens = cfg.f("camera.gunner_look_sensitivity", 0.18)
	_min_pitch = cfg.f("camera.gunner_min_pitch_deg", -35.0)
	_max_pitch = cfg.f("camera.gunner_max_pitch_deg", 20.0)


func set_tank(tank: TankView) -> void:
	_tank = tank


func is_gunner_view() -> bool:
	return _in_gunner


func toggle() -> bool:
	if _tank == null:
		return false
	_in_gunner = not _in_gunner
	# Start each visit looking straight ahead over the hull, then let the player look around.
	_look_yaw = 0.0
	_look_pitch = cfg.f("camera.gunner_start_pitch_deg", -1.7)
	_apply()
	return _in_gunner


func _apply() -> void:
	if _in_gunner:
		gunner.current = true
		tactical.set_input_enabled(false)
		_follow()
	else:
		tactical.camera.current = true
		gunner.current = false
		tactical.set_input_enabled(true)
		_release_mouse()


## Right-drag looks around. The tactical camera orbits on the same button, so it is switched off
## outright while the gunner view owns the screen (`set_input_enabled`) rather than relying on
## `_unhandled_input` dispatch order to decide which camera reacts.
func _unhandled_input(event: InputEvent) -> void:
	if not _in_gunner:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_looking = mb.pressed
				Input.set_mouse_mode(
					Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
				)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom(-1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom(1)
	elif event is InputEventMouseMotion and _looking:
		var mm := event as InputEventMouseMotion
		var sens: float = _sens * look_scale(_fov, _base_fov, _sens_scaling)
		_look_yaw = wrapf(_look_yaw - mm.relative.x * sens, -180.0, 180.0)
		_look_pitch = clampf(_look_pitch - mm.relative.y * sens, _min_pitch, _max_pitch)
		get_viewport().set_input_as_handled()


## How much to slow the look down at the current magnification.
##
## Degrees per pixel of mouse travel is scaled **linearly with the field of view**, which is the
## only factor that keeps a given mouse movement pushing the image across the same number of screen
## pixels whatever the zoom. Without it, magnifying makes the view proportionally more violent: at
## 7 degrees the optic covers a quarter of the angle it does at 28, so an unscaled flick throws the
## picture four times as far across the screen and the view is unusable exactly where it is most
## wanted.
##
## Referenced against the *starting* field of view, so `gunner_look_sensitivity` keeps meaning what
## it meant at the default zoom and nothing needs retuning. `strength` at 1 is the full linear law
## above; at 0 the sensitivity is flat, for anyone who prefers it that way.
static func look_scale(fov: float, base_fov: float, strength: float) -> float:
	if base_fov <= 0.0:
		return 1.0
	return lerpf(1.0, fov / base_fov, clampf(strength, 0.0, 1.0))


## The wheel works the optic. `dir` is -1 to magnify, +1 to pull back.
##
## Multiplicative, like the tactical camera's zoom, so a step feels the same at 40 degrees as at 8 —
## a fixed number of degrees per notch is imperceptible at the wide end and jumps at the narrow one.
##
## Deliberately not reset when the view is toggled, unlike the look direction. The direction is
## reset because the hull may have turned underneath you while you were away; magnification is not
## about where the tank is pointing, and a player who zoomed in to settle a sightline argument
## should not have to do it again on the way back.
func _zoom(dir: int) -> void:
	_fov = clampf(_fov * (1.0 + float(dir) * _zoom_step), _min_fov, _max_fov)
	gunner.fov = _fov
	get_viewport().set_input_as_handled()


func _release_mouse() -> void:
	if _looking:
		_looking = false
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _process(_delta: float) -> void:
	if _in_gunner:
		_follow()


## Sit at turret height and look where the player has turned the turret, measured from the hull's
## facing.
##
## The height comes from the same place the LOS code reads it, so the two cannot drift apart. If
## this used a hand-picked camera offset instead, the gunner view would stop being evidence.
##
## The hull yaw is taken from the **view**, and there is no longer anything else to take it from —
## `TankView` holds no `UnitState` at all since 0034. The reason it had to be the view even when the
## alternative existed is worth keeping: an action resolves in full before a frame of it is drawn, so
## from the moment an order is given the simulation's facing is already the heading the tank will
## *finish* on. Reading it here pointed the camera at the destination heading while the hull underneath
## was still turning, which is the one thing this view exists not to do — it is evidence, and evidence
## has to show what is actually on screen.
func _follow() -> void:
	if _tank == null:
		return
	var eye: Vector3 = _tank.eye_position()
	gunner.global_position = eye

	var hull_yaw: float = _tank.global_rotation.y
	# Rotation order matters: yaw about the world's up axis, then pitch about the camera's own right,
	# or looking up while turned sideways rolls the horizon.
	gunner.global_transform = Transform3D(
		Basis(Vector3.UP, hull_yaw + deg_to_rad(_look_yaw))
			* Basis(Vector3.RIGHT, deg_to_rad(_look_pitch)),
		eye
	)
