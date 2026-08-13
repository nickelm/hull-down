class_name RosterPanel
extends PanelContainer

## The force list: everything on the board the viewing side knows about, in one column.
##
## Two things the map cannot do. A unit behind a ridge, off the bottom of the screen, or standing
## where a wreck hides it is still a unit with orders left, and the only affordance for finding it was
## a cycling key that gives no overview. And a ghost two turns old is easy to miss entirely at the zoom
## a tank is legible at.
##
## Owned by `Hud`, like the unit card, so it inherits the one viewport-resize connection and the one
## font-scale rule — docs/decisions/0023, which puts anything carrying a numeral in a screen-anchored
## panel rather than over the tank.
##
## **Built from `MatchState.contacts`, never from the units array** — docs/decisions/0034. That is the
## whole reason the enemy half of this list is short at the start of a match and grows: it lists what
## has been seen, and a roster assembled from ground truth would be an order of battle handed over for
## free. The friendly half is `side_roster`, wrecks included, because losses are yours to count.

signal unit_picked(index: int)

const COMPASS: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

var _box: VBoxContainer
var _rows: Array[Button] = []

var _label_color := Color(0.55, 0.58, 0.63)
var _value_color := Color(0.78, 0.82, 0.85)
var _heading_color := Color(1.0, 0.71, 0.24)
var _pending_color := Color(0.37, 0.40, 0.43)
var _damaged_color := Color(0.88, 0.44, 0.30)
var _selected_color := Color(1.0, 0.94, 0.82)
var _font_size: int = 12


func setup(cfg: Config) -> void:
	_label_color = cfg.color("look.card.label_color", _label_color)
	_value_color = cfg.color("look.card.value_color", _value_color)
	_heading_color = cfg.color("look.card.heading_color", _heading_color)
	_pending_color = cfg.color("look.card.pending_color", _pending_color)
	_selected_color = cfg.color("look.roster.selected_color", _selected_color)

	custom_minimum_size = Vector2(float(cfg.i("look.roster.width_px", 180)), 0.0)
	# The container ignores the mouse so its transparent padding does not swallow orders aimed at the
	# terrain behind it; the row buttons take clicks themselves. Same rule as the button row in `Hud`.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := StyleBoxFlat.new()
	var bg: Color = cfg.color("look.card.panel_color", Color(0.07, 0.08, 0.10))
	bg.a = cfg.f("look.card.panel_alpha", 0.74)
	panel.bg_color = bg
	panel.set_content_margin_all(float(cfg.i("look.card.padding_px", 10)))
	panel.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", panel)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", cfg.i("look.card.row_gap_px", 2))
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)

	visible = false


## Rebuild the list for one side's point of view.
##
## Rows are rebuilt rather than recycled. A roster changes length whenever a contact is gained or goes
## cold, which is often, and the alternative is a pool plus a visibility rule per row for a list that
## is never more than a couple of dozen entries long.
func refresh(state: MatchState, cfg: Config, viewing_side: int, selected: int) -> void:
	# Removed from the tree *and* freed. `queue_free` alone leaves the node a child until the end of
	# the frame, so two refreshes in one frame — which is what a click that both selects and repaints
	# produces — would stack the old list underneath the new one.
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	_rows.clear()

	var ghost_turns: int = cfg.i("spotting.ghost_turns", 2)

	_heading("your force")
	for index: int in state.side_roster(viewing_side):
		_row(state, cfg, viewing_side, index, selected, ghost_turns)

	_heading("contacts")
	var contacts: Array[Contact] = state.contacts(viewing_side)
	if contacts.is_empty():
		# Said out loud rather than left as an empty gap. "Nothing spotted" is a fact about the board
		# the player is entitled to, and a blank space reads as a panel that has not loaded.
		var none := Label.new()
		none.text = "nothing spotted"
		none.add_theme_color_override("font_color", _pending_color)
		none.add_theme_font_size_override("font_size", _font_size)
		_box.add_child(none)
	else:
		for c: Contact in contacts:
			_row(state, cfg, viewing_side, c.unit, selected, ghost_turns)

	# The sound layer, as a **count and not as rows** — docs/decisions/0033 and 0037. Every other line
	# in this panel is keyed on a unit index and clicking it selects that unit; a sound contact has no
	# unit index and nothing to select, and giving it a row would imply an enumerable identity that
	# 0033 says it must never appear to have. So it is stated as a number, and the ripples on the map
	# are where the player reads *where*.
	var noises: int = state.sound_contacts(viewing_side).size()
	if noises > 0:
		var heard := Label.new()
		heard.text = "%d sound contact%s" % [noises, "" if noises == 1 else "s"]
		heard.add_theme_color_override("font_color",
			cfg.color("look.roster.sound_color", Color(0.79, 0.56, 0.88)))
		heard.add_theme_font_size_override("font_size", _font_size)
		_box.add_child(heard)

	visible = true


func _heading(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", _heading_color)
	l.add_theme_font_size_override("font_size", _font_size)
	_box.add_child(l)


## One line. A button rather than a label because clicking it selects, and `MatchState.select` is what
## decides whether that is allowed — a row for the idle side, a ghost or a wreck simply does nothing.
func _row(
	state: MatchState, cfg: Config, viewing_side: int, index: int, selected: int, ghost_turns: int
) -> void:
	var kind: int = ViewState.of(state, viewing_side, index)
	if kind == ViewState.Kind.HIDDEN:
		return

	var u: UnitState = state.unit(index)
	var name: String = str(cfg.unit(String(u.unit_type)).get("display_name", u.unit_type))
	var color: Color = _value_color
	var text: String = name

	match kind:
		ViewState.Kind.OWN:
			# The two figures that decide what to do next: what it has left, and whether it is done.
			text = "%s   %d mp%s" % [
				name, u.mp_left, "   ·   done" if u.activated else ""
			]
			if u.activated:
				color = _label_color
			if index == selected:
				color = _selected_color
		ViewState.Kind.SEEN:
			text = "%s   %s" % [name, COMPASS[u.facing & 7]]
		ViewState.Kind.GHOST:
			# Age, not position — the panel says how stale the information is and the marker on the map
			# says where it was. A number of turns is what a player can plan against.
			var left: int = state.contact(viewing_side, index).ghost_turns_left
			text = "%s   last seen %d turn%s ago" % [
				name, ghost_turns - left + 1, "" if ghost_turns - left + 1 == 1 else "s"
			]
			color = _pending_color
		ViewState.Kind.WRECK:
			text = "%s   wreck" % name
			color = _damaged_color

	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# Same reason as every other button in the HUD: a Control holding focus swallows Tab into
	# `ui_focus_next`, and Tab is the unit cycling key.
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_color_override("font_color", color)
	b.add_theme_font_size_override("font_size", _font_size)
	b.pressed.connect(func() -> void: unit_picked.emit(index))
	_box.add_child(b)
	_rows.append(b)


## Driven by `Hud`, which owns the one viewport-resize connection and the one reference height.
func apply_font_scale(size: int) -> void:
	_font_size = maxi(size - 1, 1)
	for child: Node in _box.get_children():
		if child is Control:
			(child as Control).add_theme_font_size_override("font_size", _font_size)
