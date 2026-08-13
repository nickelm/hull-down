class_name TankView
extends Node3D

## The tank on screen: a hull, a turret, a gun, and no opinions about time.
##
## Deliberately blocky. The art direction is flat-shaded low-poly and the tank has to read at a
## glance from a camera four hundred meters up — silhouette and facing matter, detail does not.
## What does matter is that the turret sits at the height the visibility rules use, because the
## gunner view in 4.14 mounts its camera there and the whole point of that view is to confirm the
## overlay is telling the truth.
##
## This used to own an animation loop and emit `move_finished` when it reached the end of a route,
## and the simulation used that signal to decide a unit had finished its turn. It does not any more:
## `ActionPlayer` owns all timing and drives `set_pose`, and this class has no completion signal for
## anything to listen to. That is what makes "the view follows the simulation" structural rather
## than conventional — docs/decisions/0022.
##
## **And it no longer holds a `UnitState` either** — docs/decisions/0034. It used to, and
## `snap_to_state()` read the tile, hull facing and turret bearing straight off it, which meant every
## enemy on the board was drawn from ground truth and the fog of war the simulation had maintained
## since 0024 was decoration. A reference kept "for the friendly case" would have left that one line
## away forever, so there is no reference: `setup` takes plain values, `apply` takes a pose somebody
## else was entitled to compute, and this class cannot find out anything it was not handed.

var cfg: Config

## Which side's color it wears, and what kind of tank it is. Both fixed at construction — identity is
## positional (0022) and a unit does not change type or side mid-match.
var side: int = 1
var unit_type: StringName = &""
## For the marker's movement bar. A per-type constant, copied once, not a live read.
var mp_max: int = 1

## The pose currently on screen, as **facing indices** rather than yaws. `ActionPlayer` seeds its
## interpolation from these; it used to read `state.turret` for that, which was the last sim read in
## the replayer.
var hull_facing: int = 0
var turret_facing: int = 0

## Which `ViewState.Kind` is being drawn. `HIDDEN` means this node is not visible at all.
var kind: int = ViewState.Kind.HIDDEN

var hull: MeshInstance3D
var turret: MeshInstance3D
var muzzle: Node3D
var marker: UnitMarker

var _view: TerrainView
var _panels: Array[MeshInstance3D] = []

var _body_mat: StandardMaterial3D
var _ghost_mat: StandardMaterial3D
var _wreck_mat: StandardMaterial3D

var _ghost_alpha: float = 0.55
var _ghost_min_alpha: float = 0.18
var _wreck_sink_m: float = 0.35
var _wreck_skew: float = 0.0


func setup(
	config: Config, terrain: TerrainView, for_side: int, type_name: StringName, max_mp: int
) -> void:
	cfg = config
	_view = terrain
	side = for_side
	unit_type = type_name
	mp_max = maxi(max_mp, 1)

	# Sides are told apart by color and nothing else — a silhouette difference would be decoration,
	# and iteration 2 has both sides fielding the same three chassis anyway. Side 1 keeps the olive.
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = (
		cfg.color("look.tank_color", Color(0.29, 0.32, 0.25)) if side <= 1
		else cfg.color("look.tank_color_side2", Color(0.42, 0.27, 0.24))
	)
	_body_mat.roughness = 1.0

	# A remembered tank is the same silhouette in a colder color at reduced alpha. Not a different
	# shape: what the player is being told is "a tank was here", and the shape is the sentence.
	_ghost_alpha = cfg.f("look.contact.ghost_alpha", 0.55)
	_ghost_min_alpha = cfg.f("look.contact.ghost_min_alpha", 0.18)
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.albedo_color = cfg.color("look.contact.ghost_color", Color(0.36, 0.39, 0.44))
	_ghost_mat.roughness = 1.0
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Unshaded, so a ghost does not pick up the sun's relief cues and read as a solid object at a
	# glance. It is a memory; it should look like one from the same distance the real thing is read at.
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_wreck_sink_m = cfg.f("look.contact.wreck_sink_m", 0.35)
	_wreck_skew = deg_to_rad(cfg.f("look.contact.wreck_turret_skew_deg", 28.0))
	_wreck_mat = StandardMaterial3D.new()
	_wreck_mat.albedo_color = cfg.color("look.contact.wreck_color", Color(0.17, 0.15, 0.14))
	_wreck_mat.roughness = 1.0

	hull = MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(4.2, 1.4, 7.0)
	hull.mesh = hull_mesh
	hull.position = Vector3(0.0, 0.7, 0.0)
	add_child(hull)

	turret = MeshInstance3D.new()
	var turret_mesh := BoxMesh.new()
	turret_mesh.size = Vector3(3.0, 1.1, 3.4)
	turret.mesh = turret_mesh
	turret.position = Vector3(0.0, 1.95, -0.3)
	add_child(turret)

	var gun := MeshInstance3D.new()
	var gun_mesh := BoxMesh.new()
	gun_mesh.size = Vector3(0.34, 0.34, 4.6)
	gun.mesh = gun_mesh
	gun.position = Vector3(0.0, 0.0, -3.4)
	turret.add_child(gun)

	# Every surface that takes a material, so the four render kinds are one assignment loop rather
	# than three names repeated in three places.
	_panels = [hull, turret, gun]

	# Where the gunner camera sits, and where the visibility rules put the observer's eye.
	muzzle = Node3D.new()
	muzzle.position = Vector3(0.0, 0.35, -1.8)
	turret.add_child(muzzle)

	# A child of the tank, so it follows every move for free — no update logic, no per-frame
	# position code, and correct during playback without the player knowing it exists.
	# docs/decisions/0023.
	marker = UnitMarker.new()
	add_child(marker)
	marker.setup(cfg, side)

	_wear(_body_mat)
	visible = false


## Draw this unit the way `ViewState` says it may be drawn — docs/decisions/0034.
##
## The one entry point for "what is this unit doing on screen", and it takes the answer rather than
## working it out. `tile`, `hull_f` and `turret_f` come from `ViewState.pose`, which is the class that
## owns the choice between a live tile and a remembered one; `fade` from `ViewState.fade`.
##
## `HIDDEN` hides the node outright. Not dimmed, not a marker at low alpha — absent. A faded tank here
## would still be handing over the position, which is the whole of what 0034 exists to stop.
func apply(new_kind: int, tile: int, hull_f: int, turret_f: int, fade: float) -> void:
	kind = new_kind
	if kind == ViewState.Kind.HIDDEN or tile < 0:
		visible = false
		return

	visible = true
	var world: Vector3 = _view.tile_center(tile)
	var turret_yaw: float = facing_yaw(turret_f)

	match kind:
		ViewState.Kind.GHOST:
			_wear(_ghost_mat)
			# Fades towards `ghost_min_alpha`, never to nothing: a marker that reaches zero alpha is
			# one the player stops trusting a turn before it actually expires.
			_ghost_mat.albedo_color.a = lerpf(_ghost_alpha, _ghost_min_alpha, clampf(fade, 0.0, 1.0))
		ViewState.Kind.WRECK:
			_wear(_wreck_mat)
			# Settled into the ground with the turret knocked off its bearing. The skew is what says
			# "wreck" from a camera too high to see the color, and it is why a wreck does not read as
			# a tank that merely stopped.
			world.y -= _wreck_sink_m
			turret_yaw += _wreck_skew
		_:
			_wear(_body_mat)

	set_pose(world, facing_yaw(hull_f), turret_yaw)
	hull_facing = hull_f
	turret_facing = turret_f

	# Only a unit that can still be given an order carries a status bar. A ghost has no movement points
	# anyone knows about, and a wreck has none at all.
	if marker != null:
		marker.visible = kind == ViewState.Kind.OWN or kind == ViewState.Kind.SEEN


func _wear(mat: StandardMaterial3D) -> void:
	for m: MeshInstance3D in _panels:
		m.material_override = mat


## Put the tank at an exact pose. The only thing that moves it.
##
## `ActionPlayer` owns when and how fast; this owns nothing. Deliberately not `_process`-driven —
## see the class docstring.
##
## Both yaws are **world** bearings, because that is what the simulation stores — the turret's
## bearing is absolute, not relative to the hull (docs/decisions/0027). The turret node is a child of
## this one, so holding a world bearing means subtracting the hull's, and that subtraction happens
## here and in exactly one place. Doing it at the call sites is how the two drift.
func set_pose(world: Vector3, hull_yaw: float, turret_yaw: float) -> void:
	global_position = world
	rotation.y = hull_yaw
	if turret != null:
		turret.rotation.y = turret_yaw - hull_yaw


## The turret's bearing in world space, which is the axis the simulation stores.
##
## `ActionPlayer` seeds its interpolation from this rather than from a `UnitState`, and that is not
## fastidiousness: it is the same reason `setup` takes no `MatchState`. The view has just been posed
## from knowledge, so reading the pose back is reading what the viewer is allowed to know —
## continuously, and without holding a reference it could write through.
func turret_world_yaw() -> float:
	return rotation.y + (turret.rotation.y if turret != null else 0.0)


## Push the over-tank status bar. Pushed, never pulled: the caller is the one holding the state, and
## the values it passes are ones it has already established this side may see.
func set_bar(mp_left: int, activated: bool, selected: bool) -> void:
	if marker == null:
		return
	marker.set_mp(mp_left, mp_max)
	marker.set_acted(activated)
	marker.set_selected(selected)


static func facing_yaw(facing: int) -> float:
	if facing < 0:
		return 0.0
	# Direction 0 is north, which is -Z. Yaw increases anticlockwise about +Y.
	return atan2(float(-Grid.DX[facing]), float(-Grid.DY[facing]))


## Where the visibility rules put this unit's eye, in world space. What the gunner view sits at.
##
## Read straight from the same config key `Los` and `VisionField` read — not from a mesh landmark.
## It used to return the `muzzle` marker, which sits at 2.3 m: inside the turret box, 30 cm below
## the 2.6 m the rules actually use, and far enough forward that the turret and gun filled half the
## view when you looked behind. The whole point of the gunner view is to check the overlay's claims
## by standing where the claim says the observer is, so a camera at a hand-picked offset from a box
## mesh was quietly not evidence at all.
##
## At 2.6 m the eye clears the turret's top face by 10 cm, which is a commander's head out of the
## cupola and is why looking backwards now works.
func eye_position() -> Vector3:
	return global_position + Vector3.UP * cfg.f("visibility.turret_h_m", 2.6)
