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
signal center_pressed
signal end_turn_pressed
## A row of the roster panel was clicked. Forwarded rather than exposed, so nothing outside here has
## to know the panel exists.
signal roster_unit_picked(index: int)
## The action bar's buttons, forwarded for the same reason as the roster's rows.
signal turret_left_pressed
signal turret_right_pressed
signal overwatch_pressed

var _left: Label
var _right: Label
var _buttons: HBoxContainer
var _end_turn: Button
var _card: UnitCard
var _roster: RosterPanel
var _bar: ActionBar
var _log: EventLog
var _lines: Dictionary = {}

var _base_font: int = 13
var _outline: int = 4
var _ref_height: float = 900.0
var _max_scale: float = 2.0
var _text_color := Color(0.78, 0.82, 0.86)
var _ready_color := Color(0.55, 0.89, 0.60)
var _margin: int = 14
## The font size after viewport scaling — what `_log_strip_height` sizes the ticker strip from.
var _scaled_font: int = 13
var _log_lines: int = 6


func configure(cfg: Config) -> void:
	_base_font = cfg.i("look.hud.font_size", 13)
	_outline = cfg.i("look.hud.outline_size", 4)
	_ref_height = cfg.f("look.hud.reference_height", 900.0)
	_max_scale = cfg.f("look.hud.max_scale", 2.0)
	_text_color = cfg.color("look.hud.text_color", Color(0.78, 0.82, 0.86))
	_ready_color = cfg.color("look.hud.ready_color", Color(0.55, 0.89, 0.60))

	var margin: int = cfg.i("look.hud.margin_px", 14)
	_log_lines = maxi(cfg.i("look.hud.log.max_lines", 6), 1)
	var gap: int = cfg.i("look.hud.button_gap_px", 8)
	var bw: int = cfg.i("look.hud.button_min_w_px", 104)
	var bh: int = cfg.i("look.hud.button_min_h_px", 30)

	_buttons.add_theme_constant_override("separation", gap)
	for child: Node in _buttons.get_children():
		var b := child as Button
		if b != null:
			b.custom_minimum_size = Vector2(float(bw), float(bh))

	# The card is owned here rather than being its own CanvasLayer, so it inherits the one
	# viewport-resize connection and the one font-scale rule — docs/decisions/0023.
	if _card == null:
		_card = UnitCard.new()
		add_child(_card)
		_card.setup(cfg)

	# Left edge, opposite the card: the roster answers "which of mine still has something to do" and
	# the card answers "what is this one", and putting them on the same side would have each hiding the
	# other's context.
	if _roster == null:
		_roster = RosterPanel.new()
		add_child(_roster)
		_roster.setup(cfg)
		_roster.unit_picked.connect(func(index: int) -> void: roster_unit_picked.emit(index))

	# Bottom-center: what the selected unit can do. See `ActionBar` for why move and fire are not
	# buttons on it.
	if _bar == null:
		_bar = ActionBar.new()
		add_child(_bar)
		_bar.setup(cfg)
		_bar.turret_left_pressed.connect(func() -> void: turret_left_pressed.emit())
		_bar.turret_right_pressed.connect(func() -> void: turret_right_pressed.emit())
		_bar.overwatch_pressed.connect(func() -> void: overwatch_pressed.emit())

	# The event ticker sits above the bar — feedback lands where the ordering hand already is.
	if _log == null:
		_log = EventLog.new()
		add_child(_log)
		_log.setup(cfg)

	_margin = margin
	_apply_scale()
	_place_corners()


func _ready() -> void:
	_left = Label.new()
	_left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_left.position = Vector2(12, 10)
	_left.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_left)

	_right = Label.new()
	_right.add_theme_color_override("font_color", _text_color)
	_right.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_right.text = """[W A S D] pan   [shift] faster   [wheel] zoom   [right-drag] orbit   [Q E] orbit 45°
[left click] select unit / order move    [tab] next unit with orders left    [shift+tab] previous
[left click] a spotted enemy to fire at it    [O] lay overwatch down the bearing to the cursor
[`] cycle the whole roster    [Z X] traverse the turret 45° (free, even at 0 mp)
[enter/backspace] end turn    [F] center on unit    [V] cycle overlay    [G] gunner view
[1 2 3] playback 1x / 3x / instant    [space] skip the replay
[G] gunner view: [right-drag] turn the turret    [R] regenerate    [F3] wireframe    [esc] menu"""
	add_child(_right)

	# Anchored bottom-right and grown toward the origin, so the box keeps its corner whatever the
	# window size is. MOUSE_FILTER_IGNORE on the container means only the buttons themselves eat
	# clicks — its transparent padding does not swallow orders aimed at the terrain behind it.
	_buttons = HBoxContainer.new()
	_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_buttons)

	_buttons.add_child(_make_button("< Prev", func() -> void: prev_unit_pressed.emit()))
	_buttons.add_child(_make_button("Next >", func() -> void: next_unit_pressed.emit()))
	_buttons.add_child(_make_button("Center", func() -> void: center_pressed.emit()))
	_end_turn = _make_button("End Turn", func() -> void: end_turn_pressed.emit())
	_buttons.add_child(_end_turn)

	get_viewport().size_changed.connect(_on_viewport_resized)
	_apply_scale()
	_place_corners()


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
	_place_corners()


## Pin the button row to the bottom-right corner, the keybind legend to the bottom-left, and the
## unit card to the top-right.
##
## All use PRESET_MODE_MINSIZE, which sizes the control from `get_combined_minimum_size()` — so
## this has to run *after* the buttons have their minimum sizes and all of them have their font.
## Setting anchors first and nudging `position` afterwards — the obvious way — leaves the offsets
## describing a box of zero size, which put the button row in the top-left corner half off the
## screen and clipped the last line of the legend off the bottom.
func _place_corners() -> void:
	if _buttons != null:
		_buttons.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, _margin
		)
	if _right != null:
		_right.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, _margin
		)
	if _card != null:
		_card.set_anchors_and_offsets_preset(
			Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, _margin
		)
	if _roster != null:
		# Center-left rather than top-left: the status lines own the top-left corner and the legend the
		# bottom-left, and the roster grows in both directions as contacts come and go.
		_roster.set_anchors_and_offsets_preset(
			Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, _margin
		)
	if _bar != null:
		_bar.set_anchors_and_offsets_preset(
			Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, _margin
		)
		# The hint line changes width as the mode changes; growing from the center keeps the bar
		# centered without re-running this on every refresh.
		_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	if _log != null and _bar != null:
		# A fixed full-width strip above the bar, inside which the lines stack bottom-up. A strip
		# rather than a MINSIZE box because the log changes height every few seconds, and re-anchoring
		# a shrinking box is exactly the churn a fire-and-forget ticker should not cause.
		_log.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		var above: float = _bar.get_combined_minimum_size().y + float(_margin) * 2.0
		_log.offset_left = 0.0
		_log.offset_right = 0.0
		_log.offset_bottom = -above
		_log.offset_top = -(above + _log_strip_height())


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

	if _card != null:
		_card.apply_font_scale(size)

	if _roster != null:
		_roster.apply_font_scale(size)

	if _bar != null:
		_bar.apply_font_scale(size)

	if _log != null:
		_log.apply_font_scale(size)

	_scaled_font = size


## Room for the ticker's full stack plus the line-spacing slack a Label carries around its glyphs.
func _log_strip_height() -> float:
	return float(_log_lines + 1) * float(_scaled_font) * 1.6


## Tint End Turn once every unit on the active side has acted — the "who has not acted" affordance
## docs/decisions/0003 asked for, at no layout cost.
func set_end_turn_ready(ready: bool) -> void:
	if _end_turn == null:
		return
	_end_turn.add_theme_color_override("font_color", _ready_color if ready else _text_color)


## Fill in the corner card. See `UnitCard` for why it is a corner and not a floating panel.
func set_unit_card(
	u: UnitState, cfg: Config, md: MapData, index: int, total: int,
	exposure: int, orderable: bool, forecast: FireForecast = null
) -> void:
	if _card != null:
		_card.show_unit(u, cfg, md, index, total, exposure, orderable, forecast)
		_place_corners()


func clear_unit_card() -> void:
	if _card != null:
		_card.clear_unit()


## Rebuild the force list. See `RosterPanel` for why it is built from contacts and not from units.
func set_roster(state: MatchState, cfg: Config, viewing_side: int, selected: int) -> void:
	if _roster != null:
		_roster.refresh(state, cfg, viewing_side, selected)
		_place_corners()


## Gray out and disarm the turn controls while an action is being replayed.
##
## Not cosmetic. End Turn pressed mid-move used to call `begin_turn()` on the unit still animating,
## and the completion handler then evaluated `can_act()` against a refilled unit and marked the
## wrong thing done — docs/decisions/0022. Every key that could do the same is gated in `main.gd`
## against `PlayerController.is_busy()`.
func set_controls_enabled(enabled: bool) -> void:
	if _bar != null:
		_bar.set_enabled(enabled)
	if _buttons == null:
		return
	for child: Node in _buttons.get_children():
		var b := child as Button
		if b != null:
			b.disabled = not enabled


## Refresh the action bar for the selected unit. `is_active_side` is whether that unit can be
## ordered at all; `aiming` is the controller's overwatch-aim mode, which the bar shows but does
## not own.
func set_action_bar(u: UnitState, is_active_side: bool, aiming: bool) -> void:
	if _bar != null:
		_bar.refresh(u, is_active_side, aiming)


## Push a line onto the event ticker. `category` picks the color — see `EventLog`.
func notify(text: String, category: String = "info") -> void:
	if _log != null and text != "":
		_log.push_entry(text, category)


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
