class_name ActionBar
extends PanelContainer

## The action toolbar, pinned bottom-center: what the selected unit can do, as buttons.
##
## Move and fire stay click-driven on the board — the overlay and the forecast are their affordance —
## so the bar carries the orders that had been keyboard-only: turret traverse and overwatch. Each
## button's enabled state mirrors the legality checks in `TurretAction` and `Overwatch`, so a grayed
## button is the resolver's refusal shown *before* the click instead of after it.
##
## Overwatch is a two-step order — it needs a bearing — so its button arms an aiming mode owned by
## `PlayerController`: the next click on the board lays the watch toward that tile instead of moving.
## The hint line above the buttons says which mode the next click is in, which is the one piece of
## state a click-driven scheme cannot show any other way.

signal turret_left_pressed
signal turret_right_pressed
signal overwatch_pressed

var _hint: Label
var _turret_left: Button
var _turret_right: Button
var _overwatch: Button
## The busy gate, held separately from legality: while a replay runs everything is off whatever the
## unit could legally do, same as the corner buttons.
var _controls_enabled: bool = true

var _hint_color := Color(0.55, 0.58, 0.63)
var _aim_color := Color(1.0, 0.82, 0.48)
var _text_color := Color(0.78, 0.82, 0.86)


func setup(cfg: Config) -> void:
	_hint_color = cfg.color("look.hud.bar.hint_color", _hint_color)
	_aim_color = cfg.color("look.hud.bar.aim_color", _aim_color)
	_text_color = cfg.color("look.hud.text_color", _text_color)

	# Same dress as the card and the roster, so the HUD reads as one family of panels.
	var panel := StyleBoxFlat.new()
	var bg: Color = cfg.color("look.card.panel_color", Color(0.07, 0.08, 0.10))
	bg.a = cfg.f("look.card.panel_alpha", 0.74)
	panel.bg_color = bg
	panel.set_content_margin_all(float(cfg.i("look.hud.bar.padding_px", 8)))
	panel.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", panel)
	# The panel itself swallows no clicks; only the buttons do. Same rule as every other HUD surface.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_color", _hint_color)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_hint)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", cfg.i("look.hud.bar.button_gap_px", 8))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)

	var bw: int = cfg.i("look.hud.bar.button_min_w_px", 96)
	var bh: int = cfg.i("look.hud.button_min_h_px", 30)

	_turret_left = _make_button(
		"< Turret", "Traverse the turret 45° left — free, even at 0 mp  (Z)",
		func() -> void: turret_left_pressed.emit()
	)
	_turret_right = _make_button(
		"Turret >", "Traverse the turret 45° right — free, even at 0 mp  (X)",
		func() -> void: turret_right_pressed.emit()
	)
	_overwatch = _make_button(
		"Overwatch", "Lay the gun on a bearing and fire at whatever crosses it. Ends this unit's turn  (O)",
		func() -> void: overwatch_pressed.emit()
	)
	_overwatch.toggle_mode = true

	for b: Button in [_turret_left, _turret_right, _overwatch]:
		b.custom_minimum_size = Vector2(float(bw), float(bh))
		row.add_child(b)

	refresh(null, false, false)


## Buttons take no keyboard focus — the same non-cosmetic rule as `Hud._make_button`: a focused
## Control anywhere swallows Tab into `ui_focus_next`, and Tab is the unit-cycling key.
func _make_button(text: String, tip: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.pressed.connect(on_press)
	return b


## Mirror the unit's legality onto the buttons and say what the next click will do.
##
## The conditions restate `TurretAction.legality` and `Overwatch.legality` rather than calling them —
## those want a unit *index* and run the full refusal ladder; this wants "would it be worth clicking"
## from state the card already reads. If the two ever disagree the click still gets the resolver's
## answer, so a drifted mirror is a cosmetic bug, not a rules one.
func refresh(u: UnitState, is_active_side: bool, aiming: bool) -> void:
	var selected: bool = u != null and u.alive and is_active_side

	# Traverse is free and legal at zero movement points, even after acting — 0035.
	_turret_left.disabled = not (_controls_enabled and selected)
	_turret_right.disabled = not (_controls_enabled and selected)

	var can_watch: bool = (
		selected and not u.activated and not u.gun_damaged
		and u.ammo > 0 and not u.fire_blocked
	)
	_overwatch.disabled = not (_controls_enabled and can_watch)
	_overwatch.set_pressed_no_signal(aiming)

	if u == null or not is_active_side:
		_set_hint("select one of your units — [Tab] cycles", false)
	elif aiming:
		_set_hint("aiming overwatch — click the ground to cover it", true)
	elif not u.alive:
		_set_hint("that unit is gone", false)
	elif u.activated:
		_set_hint("this unit has acted — [Tab] for the next", false)
	else:
		_set_hint("click: move   ·   click a spotted enemy: fire", false)


func _set_hint(text: String, aiming: bool) -> void:
	_hint.text = text
	_hint.add_theme_color_override("font_color", _aim_color if aiming else _hint_color)


## The busy gate, driven by `Hud.set_controls_enabled`. `refresh` runs on every repaint and restores
## the legality-based states once the replay is over.
func set_enabled(enabled: bool) -> void:
	_controls_enabled = enabled
	if not enabled:
		for b: Button in [_turret_left, _turret_right, _overwatch]:
			b.disabled = true


## Driven by `Hud`, which owns the one viewport-resize connection and the one reference height.
func apply_font_scale(size: int) -> void:
	for b: Button in [_turret_left, _turret_right, _overwatch]:
		if b != null:
			b.add_theme_font_size_override("font_size", size)
	if _hint != null:
		_hint.add_theme_font_size_override("font_size", maxi(size - 1, 1))
