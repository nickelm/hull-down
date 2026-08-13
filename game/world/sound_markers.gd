class_name SoundMarkers
extends Node3D

## The sound layer on screen — docs/decisions/0033 and 0037.
##
## One flat ring-quad per contact, lying in the ground plane, **sized to the contact's error radius**.
## That sizing is the whole presentation argument rather than a flourish: the marker covers the ground
## the tank could actually be on, so a noise close to your own troops is a small tight ripple and one
## far away is a large vague one, and the player reads the uncertainty off the picture instead of
## being told a number. 0033's requirement is that the marker "look like a guess and be drawn like
## one", and a symbol whose size is its own error bar is the most direct way to satisfy it.
##
## Not a `TankView` wearing a different material, and not an overlay channel. Not the former because a
## silhouette at any alpha reads as "a tank is there", which is precisely the confusion 0033 exists to
## prevent; not the latter because all four overlay channels are spoken for, and more importantly
## because an overlay texel is a tile and this marker is deliberately not tile-shaped.
##
## Pooled and reused. The contact list is short and changes only on a repaint or a replay step, so
## nodes are grown on demand and hidden rather than freed — the same trade `PathMarkers` makes for its
## labels, and for the same reason: churning `Sprite3D`s per frame is the one cost this could have.

var cfg: Config
var view: TerrainView

var _pool: Array[Sprite3D] = []
## How many of the pool are currently up. The pool is index-stable and reused, so this is what lets
## `place` append to a set `show_contacts` laid down without the two fighting over slots.
var _shown: int = 0
var _lift: float = 0.20
var _min_radius_m: float = 15.0
var _rings: int = 2
var _fire_color: Color = Color(0.84, 0.55, 0.91)
var _move_color: Color = Color(0.60, 0.50, 0.77)
var _alpha: float = 0.40


func setup(config: Config, terrain: TerrainView) -> void:
	cfg = config
	view = terrain

	# World coordinates go straight through, whatever this ends up parented to.
	top_level = true

	_lift = cfg.f("look.sound.lift_m", 0.20)
	_min_radius_m = cfg.f("look.sound.min_radius_m", 15.0)
	_rings = cfg.i("look.sound.ring_count", 2)
	_fire_color = cfg.color("look.sound.fire_color", Color(0.84, 0.55, 0.91))
	_move_color = cfg.color("look.sound.move_color", Color(0.60, 0.50, 0.77))
	_alpha = cfg.f("look.sound.alpha", 0.40)


## Draw exactly this list and nothing else. Takes `Array[SoundContact]` — the boundary type, which
## carries no unit index — so there is nothing here that *could* be posed from a `UnitState` even by
## accident. `tests/test_determinism` scans `game/` for a stored `UnitState`; this class has no
## reference to the simulation at all.
func show_contacts(contacts: Array[SoundContact]) -> void:
	_shown = 0
	for c: SoundContact in contacts:
		place(c.tile, c.source, c.error_m)
	for k: int in range(_shown, _pool.size()):
		_pool[k].visible = false


## Put one ripple down without disturbing the ones already up.
##
## This is what the replay calls as it walks a `HEARD` event, so the marker lands **when the round
## arrives** rather than after the stream finishes — the same treatment `SPOT` and `LOST` get, and for
## the same reason: an ambush whose evidence appears after the smoke clears is not an ambush.
##
## Takes loose values rather than a `SoundContact` because the replay has an `ActionEvent` and not a
## contact, and building one to pass here would be a second place that knows how an event becomes a
## marker. `PlayerController.refresh_all` reconciles against the simulation once playback ends.
func place(tile: int, source: int, error_m: float) -> void:
	if tile < 0:
		return
	while _pool.size() <= _shown:
		_pool.append(_make_ripple())

	var s: Sprite3D = _pool[_shown]
	# A floor on the *drawn* radius, not on the stored one. The error is honest arithmetic and may
	# legitimately be a few meters; a marker a few meters across on a map the camera views from 1400 m
	# is a marker nobody can see, and an invisible warning is worse than none.
	var radius: float = maxf(error_m, _min_radius_m)
	# The quad spans the **diameter**, so the outermost ring lands on the edge of the error circle.
	s.pixel_size = (radius * 2.0) / float(MarkerTextures.TEX_PX)
	var tint: Color = _move_color if source == SideSound.Source.MOVE else _fire_color
	tint.a = _alpha
	s.modulate = tint
	s.global_position = view.tile_center(tile) + Vector3.UP * _lift
	s.visible = true
	_shown += 1


func clear() -> void:
	_shown = 0
	for s: Sprite3D in _pool:
		s.visible = false


## A quad lying in the ground plane, like `PathMarkers`' ground arrow. Unlike that one it has no
## orientation to get wrong — a ripple is rotationally symmetric, which is the point of choosing it
## over a wedge and also means the `axis = AXIS_Y` texture-up question that arrow had cannot arise.
func _make_ripple() -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = MarkerTextures.ripple(_rings)
	s.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	s.axis = Vector3.AXIS_Y
	s.fixed_size = false
	s.shaded = false
	s.double_sided = true
	# Blended and mip-filtered, to match the coverage `MarkerTextures` rasterized. Discarding on alpha
	# would throw it away and put the staircase back.
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	s.render_priority = 1
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.top_level = true
	s.visible = false
	add_child(s)
	return s
