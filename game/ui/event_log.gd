class_name EventLog
extends VBoxContainer

## The event ticker: a short stack of fading lines above the action bar.
##
## This is where the game answers "what just happened" — a contact spotted, a shot fired, a hit
## taken, a noise heard. The lines are pushed by `PlayerController` in time with the replay (it
## translates `ActionEvent`s into English there; `sim/` carries none — docs/decisions/0022), so a
## reveal is announced on the beat the marker appears and not when the stream finishes.
##
## Ephemeral by design. Anything the player needs to *keep* lives in a panel — the card, the roster —
## and a line here is a nudge to look at the board, not a record. Lines hold for a few seconds, fade,
## and go; the stack is capped so a busy turn cannot wallpaper the screen.

var _max_lines: int = 6
var _hold_s: float = 6.0
var _fade_s: float = 1.5
var _outline: int = 4
var _font_size: int = 13
var _colors: Dictionary = {}


func setup(cfg: Config) -> void:
	_max_lines = maxi(cfg.i("look.hud.log.max_lines", 6), 1)
	_hold_s = maxf(cfg.f("look.hud.log.hold_seconds", 6.0), 0.1)
	_fade_s = maxf(cfg.f("look.hud.log.fade_seconds", 1.5), 0.1)
	_outline = cfg.i("look.hud.outline_size", 4)
	add_theme_constant_override("separation", cfg.i("look.hud.log.gap_px", 2))

	# Category -> color, read once. An unknown category falls back to "info" at push time.
	for cat: String in ["info", "warn", "contact", "damage", "kill", "good", "sound"]:
		_colors[cat] = cfg.color("look.hud.log.%s_color" % cat, Color(0.78, 0.82, 0.85))

	# Children stack at the bottom of the strip, so the newest line sits just above the action bar
	# and the stack grows upward.
	alignment = BoxContainer.ALIGNMENT_END
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Add a line. `category` picks the color: info, warn, contact, damage, kill, good, sound.
func push_entry(text: String, category: String = "info") -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override(
		"font_color", _colors.get(category, _colors.get("info", Color.WHITE))
	)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", _outline)
	l.add_theme_font_size_override("font_size", _font_size)
	l.set_meta("age", 0.0)
	add_child(l)

	while get_child_count() > _max_lines:
		var oldest: Node = get_child(0)
		remove_child(oldest)
		oldest.queue_free()


func _process(delta: float) -> void:
	# Walked backwards because a fully faded line is removed mid-loop.
	for k: int in range(get_child_count() - 1, -1, -1):
		var l := get_child(k) as Label
		if l == null:
			continue
		var age: float = float(l.get_meta("age", 0.0)) + delta
		l.set_meta("age", age)
		if age <= _hold_s:
			continue
		var alpha: float = 1.0 - (age - _hold_s) / _fade_s
		if alpha <= 0.0:
			remove_child(l)
			l.queue_free()
		else:
			l.modulate = Color(1, 1, 1, alpha)


## Driven by `Hud`, which owns the one viewport-resize connection and the one reference height.
func apply_font_scale(size: int) -> void:
	_font_size = size
	for child: Node in get_children():
		var l := child as Label
		if l != null:
			l.add_theme_font_size_override("font_size", size)
