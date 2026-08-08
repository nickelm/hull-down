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


func setup(tactical_camera: TacticalCamera, config: Config) -> void:
	tactical = tactical_camera
	cfg = config

	gunner = Camera3D.new()
	gunner.name = "GunnerCamera"
	gunner.fov = cfg.f("camera.gunner_fov_deg", 28.0)
	gunner.far = 6000.0
	gunner.current = false
	add_child(gunner)


func set_tank(tank: TankView) -> void:
	_tank = tank


func is_gunner_view() -> bool:
	return _in_gunner


func toggle() -> bool:
	if _tank == null:
		return false
	_in_gunner = not _in_gunner
	_apply()
	return _in_gunner


func _apply() -> void:
	if _in_gunner:
		gunner.current = true
		tactical.set_edge_scroll(false)
		_follow()
	else:
		tactical.camera.current = true
		gunner.current = false
		tactical.set_edge_scroll(true)


func _process(_delta: float) -> void:
	if _in_gunner:
		_follow()


## Sit at turret height, look along the hull's facing with a slight downward tilt.
##
## The height comes from the same place the LOS code reads it, so the two cannot drift apart. If
## this used a hand-picked camera offset instead, the gunner view would stop being evidence.
func _follow() -> void:
	if _tank == null:
		return
	var eye: Vector3 = _tank.eye_position()
	gunner.global_position = eye

	var facing: int = _tank.state.facing
	var ahead := Vector3(float(Grid.DX[facing]), 0.0, float(Grid.DY[facing]))
	if ahead.length_squared() < 0.001:
		ahead = Vector3.FORWARD
	gunner.look_at(eye + ahead.normalized() * 200.0 + Vector3(0.0, -6.0, 0.0), Vector3.UP)
