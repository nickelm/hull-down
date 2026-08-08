class_name Hud
extends CanvasLayer

## Status readout and the turn controls.
##
## Still deliberately plain — what a developer needs while building terrain is numbers, not chrome —
## but iteration 1 now has more than one unit and a turn to end, so it has buttons too
## (docs/decisions/0012).
##
## The window does not stretch its canvas (see project.godot), which keeps the 3D view sharp and
## mouse picking honest at any window size but leaves the HUD in raw pixels. Font sizes are
## therefore scaled against the real viewport height, so a 4K window does not get half-size text.

signal prev_unit_pressed
signal next_unit_pressed
signal end_turn_pressed

var _left: Label
var _right: Label
var _buttons: HBoxContainer
var _end_turn: Button
var _lines: Dictionary = {}

var _base_font: int = 13
var _outline: int = 4
var _ref_height: float = 900.0
var _max_scale: float = 2.0
var _text_colour := Color(0.78, 0.82, 0.86)
var _ready_colour := Color(0.55, 0.89, 0.60)
var _margin: int = 14


func configure(cfg: Config) -> void:
	_base_font = cfg.i("look.hud.font_size", 13)
	_outline = cfg.i("look.hud.outline_size", 4)
	_ref_height = cfg.f("look.hud.reference_height", 900.0)
	_max_scale = cfg.f("look.hud.max_scale", 2.0)
	_text_colour = cfg.colour("look.hud.text_colour", Color(0.78, 0.82, 0.86))
	_ready_colour = cfg.colour("look.hud.ready_colour", Color(0.55, 0.89, 0.60))

	var margin: int = cfg.i("look.hud.margin_px", 14)
	var gap: int = cfg.i("look.hud.button_gap_px", 8)
	var bw: int = cfg.i("look.hud.button_min_w_px", 104)
	var bh: int = cfg.i("look.hud.button_min_h_px", 30)

	_buttons.add_theme_constant_override("separation", gap)
	for child: Node in _buttons.get_children():
		var b := child as Button
		if b != null:
			b.custom_minimum_size = Vector2(float(bw), float(bh))

	_margin = margin
	_apply_scale()
	_place_buttons()


func _ready() -> void:
	_left = Label.new()
	_left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_left.position = Vector2(12, 10)
	_left.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_left)

	_right = Label.new()
	_right.add_theme_color_override("font_color", _text_colour)
	_right.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_right.text = """[W A S D] pan   [shift] faster   [wheel] zoom   [right-drag] orbit
[left click] select unit / order move    [tab] next unit    [shift+tab] previous
[enter] end turn    [F] centre on unit    [V] cycle overlay    [G] gunner view
[R] regenerate    [F3] wireframe"""
	add_child(_right)

	# Anchored bottom-right and grown toward the origin, so the box keeps its corner whatever the
	# window size is. MOUSE_FILTER_IGNORE on the container means only the buttons themselves eat
	# clicks — its transparent padding does not swallow orders aimed at the terrain behind it.
	_buttons = HBoxContainer.new()
	_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_buttons)

	_buttons.add_child(_make_button("< Prev", func() -> void: prev_unit_pressed.emit()))
	_buttons.add_child(_make_button("Next >", func() -> void: next_unit_pressed.emit()))
	_end_turn = _make_button("End Turn", func() -> void: end_turn_pressed.emit())
	_buttons.add_child(_end_turn)

	get_viewport().size_changed.connect(_on_viewport_resized)
	_apply_scale()
	_place_buttons()


## Buttons take no keyboard focus.
##
## This is not cosmetic. Godot's GUI dispatches Tab to `ui_focus_next` whenever any Control holds
## focus, and it never reaches `_unhandled_input` — so the moment the player clicked End Turn, the
## Tab key would stop cycling units and start walking the button row instead.
func _make_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.pressed.connect(on_press)
	return b


func _on_viewport_resized() -> void:
	_apply_scale()
	_place_buttons()


## Pin the button row to the bottom-right corner and the keybind legend to the bottom-left.
##
## Both use PRESET_MODE_MINSIZE, which sizes the control from `get_combined_minimum_size()` — so
## this has to run *after* the buttons have their minimum sizes and both have their font. Setting
## anchors first and nudging `position` afterwards — the obvious way — leaves the offsets describing
## a box of zero size, which put the button row in the top-left corner half off the screen and
## clipped the last line of the legend off the bottom.
func _place_buttons() -> void:
	if _buttons != null:
		_buttons.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, _margin
		)
	if _right != null:
		_right.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, _margin
		)


func _apply_scale() -> void:
	var h: float = float(get_viewport().get_visible_rect().size.y)
	var scale: float = clampf(h / maxf(_ref_height, 1.0), 1.0, _max_scale)
	var size: int = maxi(int(round(float(_base_font) * scale)), 1)

	for label: Label in [_left, _right]:
		if label == null:
			continue
		label.add_theme_font_size_override("font_size", size)
		label.add_theme_constant_override("outline_size", _outline)

	if _buttons != null:
		for child: Node in _buttons.get_children():
			var b := child as Button
			if b != null:
				b.add_theme_font_size_override("font_size", size)


## Tint End Turn once every unit on the active side has acted — the "who has not acted" affordance
## docs/decisions/0003 asked for, at no layout cost.
func set_end_turn_ready(ready: bool) -> void:
	if _end_turn == null:
		return
	_end_turn.add_theme_color_override("font_color", _ready_colour if ready else _text_colour)


## Status lines are keyed so callers can update one without knowing about the others. Sorted on
## render, so the panel does not reshuffle itself as different systems report in.
func set_line(key: String, text: String) -> void:
	_lines[key] = text
	_refresh()


func clear_line(key: String) -> void:
	_lines.erase(key)
	_refresh()


func _refresh() -> void:
	var keys: Array = _lines.keys()
	keys.sort()
	var out := PackedStringArray()
	for k: Variant in keys:
		out.append(str(_lines[k]))
	_left.text = "\n".join(out)
