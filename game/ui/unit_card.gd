class_name UnitCard
extends PanelContainer

## The detailed unit readout, pinned to a screen corner.
##
## Not floating over the tank, and that is the decision rather than a default — docs/decisions/0023.
## The camera spans 25 m to 1400 m over terraced flat-shaded ground the terrain shader deliberately
## does not tint, and world-anchored text has to survive both ends of that against hard value steps.
## What goes over the tank is a shape and a bar length; everything with a numeral in it comes here.
##
## **The layout is final today.** Condition, ammo and criticals do not exist yet and are drawn now,
## as a placeholder glyph in a dimmed color, so that iteration 2 changes a value expression and
## nothing on screen moves. No corresponding fields are added to `UnitState` — the repo's standing
## position is that state nothing reads is worse than no state (docs/decisions/0014 on `ap_left`).
##
## The armor, gun and optics figures are real, and have been sitting unread in `data/units.json`
## since the roster was written. They are class data rather than per-unit state, and the card says so.

const COMPASS: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const EXPOSURE_NAMES: Array[String] = ["masked", "hull down", "exposed"]

## Rows in the order they are drawn. `""` is a spacer, `"#text"` a section heading.
const ROWS: Array[String] = [
	"side", "position", "facing",
	"", "#orders",
	"movement", "actions", "status", "cover here",
	"", "#this shot",
	"to hit", "penetration", "against", "range",
	"", "#condition",
	"hull", "crew", "ammo", "criticals",
	"", "#class data",
	"armor", "gun", "optics",
]

var _title: Label
var _role: Label
var _grid: GridContainer
var _keys: Dictionary = {}
var _headings: Array[Label] = []

var _placeholder: String = "—"
var _label_color: Color = Color(0.55, 0.58, 0.63)
var _value_color: Color = Color(0.78, 0.82, 0.85)
var _heading_color: Color = Color(1.0, 0.71, 0.24)
var _pending_color: Color = Color(0.37, 0.40, 0.43)
var _damaged_color: Color = Color(0.88, 0.44, 0.30)


func setup(cfg: Config) -> void:
	_placeholder = str(cfg.rules.get("look", {}).get("card", {}).get("placeholder", "—"))
	_label_color = cfg.color("look.card.label_color", _label_color)
	_value_color = cfg.color("look.card.value_color", _value_color)
	_heading_color = cfg.color("look.card.heading_color", _heading_color)
	_pending_color = cfg.color("look.card.pending_color", _pending_color)

	var pad: int = cfg.i("look.card.padding_px", 10)
	custom_minimum_size = Vector2(float(cfg.i("look.card.width_px", 258)), 0.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := StyleBoxFlat.new()
	var bg: Color = cfg.color("look.card.panel_color", Color(0.07, 0.08, 0.10))
	bg.a = cfg.f("look.card.panel_alpha", 0.74)
	panel.bg_color = bg
	panel.set_content_margin_all(float(pad))
	panel.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", cfg.i("look.card.row_gap_px", 2))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)

	_title = Label.new()
	_title.add_theme_color_override("font_color", _heading_color)
	box.add_child(_title)

	_role = Label.new()
	_role.add_theme_color_override("font_color", _label_color)
	box.add_child(_role)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", cfg.i("look.card.row_gap_px", 2))
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_grid)

	for row: String in ROWS:
		if row == "":
			_grid.add_child(_spacer())
			_grid.add_child(_spacer())
		elif row.begins_with("#"):
			var head := Label.new()
			head.text = row.substr(1)
			head.add_theme_color_override("font_color", _heading_color)
			_headings.append(head)
			_grid.add_child(head)
			_grid.add_child(_spacer())
		else:
			var key := Label.new()
			key.text = row
			key.add_theme_color_override("font_color", _label_color)
			_grid.add_child(key)

			var value := Label.new()
			value.text = _placeholder
			value.add_theme_color_override("font_color", _value_color)
			_grid.add_child(value)
			_keys[row] = value

	visible = false


func _spacer() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, 4.0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Fill the card in for a unit. `orderable` dims the title for a unit belonging to the idle side, so
## a hovered enemy reads as information rather than as something that can be told what to do.
func show_unit(
	u: UnitState, cfg: Config, md: MapData, index: int, total: int,
	exposure: int, orderable: bool, forecast: FireForecast = null
) -> void:
	if u == null:
		clear_unit()
		return

	var data: Dictionary = cfg.unit(String(u.unit_type))
	_title.text = str(data.get("display_name", u.unit_type))
	_title.add_theme_color_override("font_color", _heading_color if orderable else _label_color)
	_role.text = str(data.get("role", ""))

	_row("side", "%d   ·   unit %d of %d" % [u.side, index + 1, total])
	_row("position", "(%d, %d)   %.1f m" % [md.tx(u.tile), md.ty(u.tile), md.height_m(u.tile)])
	_row("facing", COMPASS[u.facing & 7])

	# Real, and the only two numbers on the card that change during a turn.
	_row("movement", "%d / %d mp" % [u.mp_left, u.mp_max])

	# Derived, never stored — docs/decisions/0014 refuses an `ap_left` counter, and the card is not
	# the place to quietly reintroduce one. Labelled so the number is not mistaken for state.
	var per_action: int = maxi(u.action_mp(cfg), 1)
	_row("actions", "%d of %d left  (derived)" % [
		mini(u.mp_left / per_action, cfg.i("movement.actions_per_turn", 2)),
		cfg.i("movement.actions_per_turn", 2),
	])
	var status: String = "has acted" if u.activated else "ready"
	if not u.alive:
		status = "destroyed"
	elif u.overwatch_dir >= 0:
		status = "watching %s" % COMPASS[u.overwatch_dir & 7]
	_row("status", status)
	_row("cover here", EXPOSURE_NAMES[clampi(exposure, 0, EXPOSURE_NAMES.size() - 1)])

	_show_forecast(forecast)

	# The four rows 0023 reserved, now that there is something to put in them. The layout does not
	# move: these were drawn as placeholders from the day the card was written precisely so that this
	# change would be a value expression and nothing else.
	var lost: int = Armor.total_shred(u)
	if lost <= 0:
		_row("hull", "intact")
	else:
		_damaged("hull", "%d mm shot away" % lost)

	if u.shaken_turns > 0:
		_damaged("crew", "shaken (%d turn%s)" % [u.shaken_turns, "" if u.shaken_turns == 1 else "s"])
	else:
		_row("crew", "steady")

	_row("ammo", "%d round%s" % [u.ammo, "" if u.ammo == 1 else "s"])

	var criticals := PackedStringArray()
	if u.immobilised:
		criticals.append("immobilised")
	if u.gun_damaged:
		criticals.append("gun damaged")
	if criticals.is_empty():
		_row("criticals", "none")
	else:
		_damaged("criticals", ", ".join(criticals))

	# Class data, straight out of data/units.json. Static per tank type, not per unit.
	var armor: Dictionary = data.get("armor", {})
	if armor.is_empty():
		_pending("armor")
	else:
		# Five facings — docs/decisions/0004. Left and right carry the same number for the whole
		# iteration-2 roster, so they are collapsed into one column here and the row only grows a
		# fourth number on the day a unit is actually asymmetric.
		var left: int = int(armor.get("left", 0))
		var right: int = int(armor.get("right", 0))
		var flank: String = str(left) if left == right else "%d / %d" % [left, right]
		_row("armor", "%d / %s / %d / %d" % [
			int(armor.get("front", 0)), flank,
			int(armor.get("rear", 0)), int(armor.get("top", 0)),
		])

	var gun: Dictionary = data.get("gun", {})
	if gun.is_empty():
		_pending("gun")
	else:
		var shots: int = int(gun.get("shots_per_action", 1))
		_row("gun", "%d mm · %d pen · %d shot%s" % [
			int(gun.get("calibre_mm", 0)), int(gun.get("penetration_mm", 0)),
			shots, "" if shots == 1 else "s",
		])

	var optics: Dictionary = data.get("optics", {})
	if optics.is_empty():
		_pending("optics")
	else:
		_row("optics", "%d m" % int(optics.get("base_range_m", 0)))

	visible = true


## The odds, while the cursor is over something the selected unit could shoot at.
##
## The numbers a percentage game owes the player *before* they commit, which is the whole argument of
## `FireForecast`'s docstring — and which, until now, nothing on screen had ever shown. The commit path
## carried a comment claiming this had already been on display while the player hovered; it had not,
## and a comment describing behavior that does not exist is worse than no comment.
##
## The two percentages are given separately and then multiplied, because that is the decision: hit and
## penetration failing for different reasons is what tells the player whether to move closer or to find
## a flank, and only their product says whether to take the shot at all.
##
## Rows are filled with the placeholder rather than hidden when there is no shot. The layout does not
## move — 0023, and the same reason the condition rows were drawn empty for a whole iteration.
func _show_forecast(f: FireForecast) -> void:
	if f == null or not f.ok():
		for key: String in ["to hit", "penetration", "against", "range"]:
			_pending(key)
		return

	_row("to hit", "%.0f%%" % (f.hit_chance * 100.0))
	_row("penetration", "%.0f%%   →   %.0f%% net" % [
		f.pen_chance * 100.0, f.kill_chance() * 100.0,
	])

	# `plate_mm` is what is *left* of that plate after everything already shot off it (0004), so the
	# comparison is against the armor as it stands now, not as it left the factory.
	var plate: String = PLATES[f.facing_struck % PLATES.size()] if f.facing_struck >= 0 else "?"
	_row("against", "%s — %d mm vs %.0f" % [plate, f.plate_mm, f.pen_mm])
	_row("range", "%.0f m   ·   %d shot%s" % [f.range_m, f.shots, "" if f.shots == 1 else "s"])


const PLATES: Array[String] = ["front", "left side", "right side", "rear", "roof"]


func clear_unit() -> void:
	visible = false


func _row(key: String, text: String) -> void:
	var l: Label = _keys.get(key) as Label
	if l == null:
		return
	l.text = text
	l.add_theme_color_override("font_color", _value_color)


func _pending(key: String) -> void:
	var l: Label = _keys.get(key) as Label
	if l == null:
		return
	l.text = _placeholder
	l.add_theme_color_override("font_color", _pending_color)


## A row whose value is something that has gone wrong. Color is the only difference — the row is in
## the same place, saying the same kind of thing, so nothing reflows when a tank takes a hit.
func _damaged(key: String, text: String) -> void:
	var l: Label = _keys.get(key) as Label
	if l == null:
		return
	l.text = text
	l.add_theme_color_override("font_color", _damaged_color)


## Driven by `Hud`, which owns the one viewport-resize connection and the one reference height. A
## second copy of that machinery here is how the two drift apart at 4K.
func apply_font_scale(size: int) -> void:
	for node: Node in [_title, _role]:
		var l := node as Label
		if l != null:
			l.add_theme_font_size_override("font_size", size)
	if _grid == null:
		return
	for child: Node in _grid.get_children():
		var l2 := child as Label
		if l2 != null:
			l2.add_theme_font_size_override("font_size", maxi(size - 1, 1))
