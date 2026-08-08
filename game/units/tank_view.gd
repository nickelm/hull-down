class_name TankView
extends Node3D

## The tank on screen: a hull, a turret, a gun, and a barrel of animation.
##
## Deliberately blocky. The art direction is flat-shaded low-poly and the tank has to read at a
## glance from a camera four hundred metres up — silhouette and facing matter, detail does not.
## What does matter is that the turret sits at the height the visibility rules use, because the
## gunner view in 4.14 mounts its camera there and the whole point of that view is to confirm the
## overlay is telling the truth.

var state: UnitState
var cfg: Config

var hull: MeshInstance3D
var turret: MeshInstance3D
var muzzle: Node3D

var _view: TerrainView
var _path: PathResult
var _leg: int = 0
var _leg_t: float = 0.0
var _moving: bool = false
var _speed: float = 26.0
var _turn_speed: float = 3.4

signal move_finished


func setup(unit: UnitState, config: Config, terrain: TerrainView) -> void:
	state = unit
	cfg = config
	_view = terrain

	# Sides are told apart by colour and nothing else in iteration 1 — there is no combat, so a
	# silhouette difference would be decoration. Side 1 keeps the original olive.
	var body := StandardMaterial3D.new()
	body.albedo_color = (
		cfg.colour("look.tank_colour", Color(0.29, 0.32, 0.25)) if unit.side <= 1
		else cfg.colour("look.tank_colour_side2", Color(0.42, 0.27, 0.24))
	)
	body.roughness = 1.0

	hull = MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(4.2, 1.4, 7.0)
	hull.mesh = hull_mesh
	hull.material_override = body
	hull.position = Vector3(0.0, 0.7, 0.0)
	add_child(hull)

	turret = MeshInstance3D.new()
	var turret_mesh := BoxMesh.new()
	turret_mesh.size = Vector3(3.0, 1.1, 3.4)
	turret.mesh = turret_mesh
	turret.material_override = body
	turret.position = Vector3(0.0, 1.95, -0.3)
	add_child(turret)

	var gun := MeshInstance3D.new()
	var gun_mesh := BoxMesh.new()
	gun_mesh.size = Vector3(0.34, 0.34, 4.6)
	gun.mesh = gun_mesh
	gun.material_override = body
	gun.position = Vector3(0.0, 0.0, -3.4)
	turret.add_child(gun)

	# Where the gunner camera sits, and where the visibility rules put the observer's eye.
	muzzle = Node3D.new()
	muzzle.position = Vector3(0.0, 0.35, -1.8)
	turret.add_child(muzzle)

	snap_to_state()


## Put the tank exactly where the simulation says it is, with no animation.
func snap_to_state() -> void:
	global_position = _view.tile_centre(state.tile)
	rotation.y = _facing_yaw(state.facing)
	_moving = false


func is_moving() -> bool:
	return _moving


## Drive the route. The simulation state has already been updated — this only catches the view up,
## so an interrupted animation can never desynchronise the two.
func play(path: PathResult) -> void:
	if not path.found or path.length() < 2:
		snap_to_state()
		move_finished.emit()
		return
	_path = path
	_leg = 0
	_leg_t = 0.0
	_moving = true


func _process(delta: float) -> void:
	if not _moving:
		return

	var from_tile: int = _path.tiles[_leg]
	var to_tile: int = _path.tiles[_leg + 1]
	var a: Vector3 = _view.tile_centre(from_tile)
	var b: Vector3 = _view.tile_centre(to_tile)

	var want_yaw: float = _facing_yaw(_path.facings[_leg + 1])
	# Reversing keeps the hull pointing the way it already faces; that is the whole difference
	# between reversing and turning round, and it has to be visible or the cost model looks
	# arbitrary.
	if _path.reversed.size() > _leg + 1 and _path.reversed[_leg + 1] == 1:
		want_yaw = _facing_yaw(_path.facings[_leg + 1])

	var turned: float = rotate_toward(rotation.y, want_yaw, _turn_speed * delta)
	rotation.y = turned

	# Only start rolling once roughly lined up, so the tank does not crab sideways across the map.
	if absf(angle_difference(rotation.y, want_yaw)) > 0.25:
		return

	var leg_len: float = maxf(a.distance_to(b), 0.001)
	_leg_t += (_speed * delta) / leg_len
	if _leg_t >= 1.0:
		_leg_t = 0.0
		_leg += 1
		if _leg >= _path.tiles.size() - 1:
			_moving = false
			snap_to_state()
			move_finished.emit()
			return
		global_position = b
		return

	global_position = a.lerp(b, _leg_t)


func _facing_yaw(facing: int) -> float:
	# Direction 0 is north, which is -Z. Yaw increases anticlockwise about +Y.
	return atan2(float(-Grid.DX[facing]), float(-Grid.DY[facing]))


## Turret-height eye position, in world space. What the gunner camera uses.
func eye_position() -> Vector3:
	return muzzle.global_position
