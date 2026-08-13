class_name MainMenu
extends CanvasLayer

## The start menu — docs/decisions/0043.
##
## A full-screen gate over the board, not a scene switch: the project has exactly one scene and
## everything in it is built in code, so the menu is one more CanvasLayer, shown before any map
## generates and toggled with ESC in play. It enumerates missions from `data/scenarios/` through
## `Scenario.list_available` — the menu knows how to list missions, `main.gd` knows what picking
## one means.
##
## The scrim eats every mouse event so a click on a menu entry cannot double as an order to the
## board behind it, and every pick hides the menu before its signal fires so a double-click cannot
## fire twice into a boot sequence that awaits frames.

signal mission_picked(path: String)
signal open_battlefield_picked
signal hotseat_picked
signal resume_picked
signal quit_picked

var _scrim: ColorRect
var _center: CenterContainer
var _box: VBoxContainer
var _title: Label
var _resume: Button
var _buttons: Array[Button] = []

var _base_font: int = 16
var _title_font: int = 34
var _ref_height: float = 900.0
var _max_scale: float = 2.0
var _text_color := Color(0.78, 0.82, 0.86)
var _title_color := Color(0.90, 0.93, 0.95)


func _ready() -> void:
	layer = 10
	visible = false

	_scrim = ColorRect.new()
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scrim)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_box = VBoxContainer.new()
	_center.add_child(_box)

	get_viewport().size_changed.connect(_apply_scale)


func configure(cfg: Config) -> void:
	_base_font = cfg.i("look.menu.font_size", 16)
	_title_font = cfg.i("look.menu.title_font_size", 34)
	_ref_height = cfg.f("look.hud.reference_height", 900.0)
	_max_scale = cfg.f("look.hud.max_scale", 2.0)
	_text_color = cfg.color("look.menu.text_color", Color(0.78, 0.82, 0.86))
	_title_color = cfg.color("look.menu.title_color", Color(0.90, 0.93, 0.95))
	_scrim.color = cfg.color("look.menu.scrim_color", Color(0.04, 0.05, 0.07, 0.82))
	_box.add_theme_constant_override("separation", cfg.i("look.menu.gap_px", 10))

	var bw: int = cfg.i("look.menu.button_min_w_px", 260)
	var bh: int = cfg.i("look.menu.button_min_h_px", 36)

	for child: Node in _box.get_children():
		child.queue_free()
	_buttons.clear()

	_title = Label.new()
	_title.text = "HULL DOWN"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", _title_color)
	_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_box.add_child(_title)

	for entry: Dictionary in Scenario.list_available():
		var path: String = str(entry["path"])
		_add_button("Mission: %s" % str(entry["name"]),
			func() -> void: mission_picked.emit(path), bw, bh)
	_add_button("Open Battlefield", func() -> void: open_battlefield_picked.emit(), bw, bh)
	_add_button("Hot-Seat Sandbox", func() -> void: hotseat_picked.emit(), bw, bh)
	_resume = _add_button("Resume", func() -> void: resume_picked.emit(), bw, bh)
	_add_button("Quit", func() -> void: quit_picked.emit(), bw, bh)

	_apply_scale()


## Buttons take no keyboard focus — same rule as `Hud._make_button`, same reason: a focused
## Control swallows Tab into `ui_focus_next`, and Tab is the unit-cycling key.
func _add_button(text: String, on_press: Callable, bw: int, bh: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.custom_minimum_size = Vector2(float(bw), float(bh))
	b.pressed.connect(func() -> void:
		if not visible:
			return
		close()
		on_press.call())
	_box.add_child(b)
	_buttons.append(b)
	return b


## Show the menu. Resume only makes sense once a match exists to resume.
func open(in_match: bool) -> void:
	if _resume != null:
		_resume.visible = in_match
	visible = true


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _apply_scale() -> void:
	var h: float = float(get_viewport().get_visible_rect().size.y)
	var scale: float = clampf(h / maxf(_ref_height, 1.0), 1.0, _max_scale)
	var size: int = maxi(int(round(float(_base_font) * scale)), 1)

	if _title != null:
		_title.add_theme_font_size_override(
			"font_size", maxi(int(round(float(_title_font) * scale)), 1)
		)
	for b: Button in _buttons:
		if b != null:
			b.add_theme_font_size_override("font_size", size)
			b.add_theme_color_override("font_color", _text_color)
