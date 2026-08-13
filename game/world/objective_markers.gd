class_name ObjectiveMarkers
extends Node3D

## The flags on the map — docs/decisions/0040 gave objectives holders and values, 0044 made
## possession public. One billboarded flag sprite per objective, tinted by who holds it right now:
## neutral, yours, or theirs, from ground-truth `Victory` state for both sides. The tint is the
## whole message — no tank is drawn here, and the units taking a flag stay under 0034's spotting
## rules.
##
## Fixed-size and drawn through terrain, like the selection arrow and for the same reason: a flag
## is a thing the player must always be able to find, and an objective behind a ridge is exactly
## the one being argued about. Pooled and reused like `SoundMarkers`, though the list never
## changes length mid-match — objectives are map features (0040).
##
## Takes `MapData` and a `PackedInt32Array` of side ids, never a `UnitState` — the determinism
## scan's rule for `game/`, satisfied by construction.

var cfg: Config
var view: TerrainView

var _pool: Array[Sprite3D] = []
var _flag_px: float = 22.0
var _lift: float = 2.0
var _alpha: float = 0.95
var _neutral := Color(0.81, 0.83, 0.80)
var _side1 := Color(0.56, 0.76, 0.47)
var _side2 := Color(0.82, 0.44, 0.37)

## Same constant as `UnitMarker.SPRITE_UNIT`: apparent size of a `fixed_size` sprite goes as
## texture height times `pixel_size`, and this keeps one knob per marker.
const SPRITE_UNIT: float = 0.01


func setup(config: Config, terrain: TerrainView) -> void:
	cfg = config
	view = terrain
	top_level = true

	_flag_px = cfg.f("look.objectives.flag_px", 22.0)
	_lift = cfg.f("look.objectives.lift_m", 2.0)
	_alpha = cfg.f("look.objectives.alpha", 0.95)
	_neutral = cfg.color("look.objectives.neutral_color", Color(0.81, 0.83, 0.80))
	_side1 = cfg.color("look.objectives.side1_color", Color(0.56, 0.76, 0.47))
	_side2 = cfg.color("look.objectives.side2_color", Color(0.82, 0.44, 0.37))


## Repaint every flag from the current holders — `holders` is parallel to `md.objectives`, 0 for
## nobody or contested. Sides beyond 2 tint as side 2, the same shorthand the tank albedo uses.
func show_objectives(md: MapData, holders: PackedInt32Array) -> void:
	for k: int in md.objectives.size():
		while _pool.size() <= k:
			_pool.append(_make_flag())
		var s: Sprite3D = _pool[k]
		var holder: int = int(holders[k]) if k < holders.size() else 0
		var tint: Color = _neutral
		if holder == 1:
			tint = _side1
		elif holder >= 2:
			tint = _side2
		tint.a = _alpha
		s.modulate = tint
		s.global_position = view.tile_center(md.objectives[k]) + Vector3.UP * _lift
		s.visible = true
	for k2: int in range(md.objectives.size(), _pool.size()):
		_pool[k2].visible = false


func clear() -> void:
	for s: Sprite3D in _pool:
		s.visible = false


func _make_flag() -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = MarkerTextures.flag()
	s.centered = true
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.fixed_size = true
	s.shaded = false
	s.double_sided = true
	# Blended and mip-filtered to keep the SDF's antialiasing — see `MarkerTextures`.
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	s.pixel_size = _flag_px * SPRITE_UNIT / float(MarkerTextures.TEX_PX)
	s.no_depth_test = true
	s.render_priority = 1
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.top_level = true
	s.visible = false
	add_child(s)
	return s
