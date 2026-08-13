class_name UnitMarker
extends Node3D

## The bit of the unit readout that lives on the map: a selection arrow and a status bar.
##
## Everything with a numeral in it is in the corner card instead — docs/decisions/0023. What is here
## is what survives being read at four hundred meters over terraced flat-shaded ground: a shape, and
## the length of a bar.
##
## Added as a child of `TankView`, so it follows the tank through a move for free — no update logic,
## no per-frame position code, and correct during playback without the replayer knowing it exists.
## Billboarding cancels the sprite's own orientation while position is still inherited, which is
## exactly what is wanted under a parent that rotates.
##
## **Both sprites hang off one world anchor and are separated by `SpriteBase3D.offset`.** They are
## `fixed_size`, so they hold constant screen size; a world-space vertical gap between them would
## shrink with distance and they would sit on top of each other at nine hundred meters. Offset is in
## texture pixels, which is the same units their size is in, so the gap is distance-invariant too.
##
## At the "dozens of units a side" the spec eventually wants, the answer is a `CanvasLayer` driven by
## `Camera3D.unproject_position` rather than three nodes per unit. Noted, not built — this is fine
## into the hundreds.

var _arrow: Sprite3D
var _bar_back: Sprite3D
var _bar_fill: Sprite3D

var _bar_w: float = 34.0
var _bar_t: float = 4.0
var _mp_color: Color = Color(1.0, 0.71, 0.24)
var _acted_color: Color = Color(0.42, 0.44, 0.46)
var _bob_m: float = 0.35
var _bob_hz: float = 0.7
var _base_y: float = 5.6
var _phase: float = 0.0
var _selected: bool = false
var _acted: bool = false


func setup(cfg: Config, side: int) -> void:
	_base_y = cfg.f("look.marker.anchor_height_m", 5.6)
	_bar_w = cfg.f("look.marker.bar_width_px", 34.0)
	_bar_t = cfg.f("look.marker.bar_thickness_px", 4.0)
	_mp_color = cfg.color("look.marker.mp_color", Color(1.0, 0.71, 0.24))
	_acted_color = cfg.color("look.marker.acted_color", Color(0.42, 0.44, 0.46))
	_bob_m = cfg.f("look.marker.arrow_bob_m", 0.35)
	_bob_hz = cfg.f("look.marker.arrow_bob_hz", 0.7)

	var arrow_px: float = cfg.f("look.marker.arrow_px", 16.0)
	var arrow_offset: float = cfg.f("look.marker.arrow_offset_px", 12.0)
	var bar_offset: float = cfg.f("look.marker.bar_offset_px", 0.0)

	position = Vector3(0.0, _base_y, 0.0)

	# --- the bar: two sprites over one solid white texture, told apart by modulate --------------
	var bar_tex: ImageTexture = MarkerTextures.solid_rect(int(_bar_w), int(_bar_t))

	_bar_back = _make_sprite(bar_tex, false)
	_bar_back.modulate = cfg.color("look.marker.bar_back_color", Color(0.10, 0.11, 0.12))
	_bar_back.offset = Vector2(-_bar_w * 0.5, bar_offset)
	add_child(_bar_back)

	# The fill shortens by narrowing its region rather than by scaling, so it empties from the right
	# and stays pinned to the left edge. Scaling would shrink it about its center, and correcting
	# that means moving the offset by an amount that depends on the fraction — two things to keep in
	# step where one will do.
	_bar_fill = _make_sprite(bar_tex, false)
	_bar_fill.region_enabled = true
	_bar_fill.region_rect = Rect2(0.0, 0.0, _bar_w, _bar_t)
	_bar_fill.modulate = _mp_color
	_bar_fill.offset = Vector2(-_bar_w * 0.5, bar_offset)
	add_child(_bar_fill)

	# --- the arrow ------------------------------------------------------------------------------
	#
	# Blended rather than alpha-cut, and mip-filtered rather than nearest. The chevron is the one
	# curved-and-angled shape here, and `ALPHA_CUT_DISCARD` throws away exactly the coverage
	# `MarkerTextures` went to the trouble of computing — the two settings have to agree or the
	# antialiasing is not merely wasted, it is undone.
	_arrow = _make_sprite(MarkerTextures.chevron(), true)
	_arrow.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	_arrow.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# The texture is generated at a fixed resolution whatever size it is drawn at, so the configured
	# size is applied here rather than by rasterising a differently sized image.
	_arrow.pixel_size = arrow_px * SPRITE_UNIT / float(MarkerTextures.TEX_PX)
	_arrow.modulate = (
		cfg.color("look.marker.arrow_color", Color(1.0, 0.91, 0.66)) if side <= 1
		else cfg.color("look.marker.arrow_color_side2", Color(1.0, 0.70, 0.63))
	)
	# Offset is in texture pixels, so it scales with `pixel_size` and stays screen-stable — but it
	# is therefore in units of the 64 px source image, not of `arrow_px`.
	_arrow.offset = Vector2(0.0, arrow_offset * float(MarkerTextures.TEX_PX) / maxf(arrow_px, 1.0))
	# Depth testing off, so a selected unit stays findable behind a ridge. It does mean the arrow
	# shows through hills — the right trade for a *selection* marker specifically, which is why only
	# the arrow does it and the bar does not.
	_arrow.no_depth_test = true
	_arrow.visible = false
	add_child(_arrow)

	set_process(false)


## Apparent size of a `fixed_size` sprite goes as texture height times `pixel_size`. Keeping that
## product proportional to the configured size gives one knob per marker, whatever resolution its
## texture happens to be generated at.
const SPRITE_UNIT: float = 0.01


func _make_sprite(tex: ImageTexture, centered: bool) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = tex
	s.centered = centered
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.fixed_size = true
	s.shaded = false
	s.double_sided = true
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# An annotation that casts a shadow is never what anyone wanted. Same call the scatter builder
	# makes for trees, minus the config key, because there is no case for turning this on.
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return s


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	if _arrow != null:
		_arrow.visible = on
	# Only the selected unit bobs, so nothing is running a per-frame sine for the other three.
	set_process(on and _bob_m > 0.0)
	if not on:
		position.y = _base_y


func set_mp(mp_left: int, mp_max: int) -> void:
	if _bar_fill == null:
		return
	var frac: float = clampf(float(mp_left) / float(maxi(mp_max, 1)), 0.0, 1.0)
	_bar_fill.region_rect = Rect2(0.0, 0.0, maxf(_bar_w * frac, 0.001), _bar_t)
	_bar_fill.visible = frac > 0.0


func set_acted(acted: bool) -> void:
	if _acted == acted or _bar_fill == null:
		return
	_acted = acted
	_bar_fill.modulate = _acted_color if acted else _mp_color


## Whether this unit shows a bar at all. The idle side's are hidden by default — four bars on screen
## when only two of them can be acted on is noise.
func set_bar_visible(on: bool) -> void:
	if _bar_back != null:
		_bar_back.visible = on
	if _bar_fill != null:
		_bar_fill.visible = on


func _process(delta: float) -> void:
	_phase += delta * _bob_hz * TAU
	position.y = _base_y + sin(_phase) * _bob_m
