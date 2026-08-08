class_name PlayerController
extends Node

## Selection, hover, path preview, move orders, the turn controls, and the two overlays.
##
## The overlays are the whole point of iteration 1. The movement overlay says where the selected
## unit can get to, accounting for facing and turning; the visibility overlay says what a tank
## standing on each tile would look like to it. Both are painted into the same small texture and
## both are recomputed only when something actually changes — which now includes changing which
## unit is selected, not just moving one.

signal selection_changed(index: int)

enum Overlay { MOVEMENT, VISIBILITY, NONE }

var md: MapData
var cfg: Config
var view: TerrainView
var match_state: MatchState
var views: Array[TankView] = []
var camera: TacticalCamera
var hud: Hud

var _pathfinder: TankPathfinder
var _reachable: PackedInt32Array
var _exposure: PackedByteArray
var _overlay: int = Overlay.MOVEMENT
var _hover_tile: int = -1
var _preview: PathResult


func setup(
	map: MapData, config: Config, terrain: TerrainView, state: MatchState,
	tank_views: Array[TankView], tactical: TacticalCamera, heads_up: Hud
) -> void:
	md = map
	cfg = config
	view = terrain
	match_state = state
	views = tank_views
	camera = tactical
	hud = heads_up

	_pathfinder = TankPathfinder.new(md, cfg)
	_exposure = PackedByteArray()
	_exposure.resize(md.n)
	for k: int in views.size():
		views[k].move_finished.connect(_on_move_finished.bind(k))
	refresh_all()


func active_unit() -> UnitState:
	return match_state.selected_unit()


func active_view() -> TankView:
	var i: int = match_state.selected
	return views[i] if i >= 0 and i < views.size() else null


func cycle_overlay() -> void:
	_overlay = (_overlay + 1) % 3
	_repaint()
	hud.set_line("40_overlay", "overlay: %s" % ["movement", "visibility", "off"][_overlay])


func select_unit(index: int) -> void:
	if index < 0 or not match_state.select(index):
		return
	_preview = null
	_hover_tile = -1
	refresh_all()
	selection_changed.emit(index)


func cycle_unit(step: int) -> void:
	select_unit(match_state.cycle(step))


func end_turn() -> void:
	match_state.end_turn()
	_preview = null
	_hover_tile = -1
	refresh_all()
	selection_changed.emit(match_state.selected)


func recentre() -> void:
	var u: UnitState = active_unit()
	if u != null:
		camera.recentre_on(u.tile)


func refresh_all() -> void:
	_recompute_movement()
	_recompute_visibility()
	_repaint()
	_refresh_status()


func _refresh_status() -> void:
	hud.set_line("05_turn", "turn %d — side %d — %d of %d units still to act" % [
		match_state.turn, match_state.active_side, match_state.remaining_on_side(),
		match_state.side_units(match_state.active_side).size(),
	])
	hud.set_end_turn_ready(match_state.all_activated())

	var u: UnitState = active_unit()
	if u == null:
		hud.clear_line("15_unit")
		return
	hud.set_line("15_unit", "unit %d of %d — %s — %d/%d mp%s" % [
		match_state.selected + 1, match_state.units.size(),
		cfg.unit(String(u.unit_type)).get("display_name", u.unit_type),
		u.mp_left, u.mp_max, "   (done)" if u.activated else "",
	])


func _recompute_movement() -> void:
	var u: UnitState = active_unit()
	if u == null:
		_reachable = PackedInt32Array()
		hud.clear_line("50_move")
		return

	_reachable = _pathfinder.reachable(u.tile, u.facing, u.mp_left)
	var reached: int = 0
	for i: int in md.n:
		if _reachable[i] >= 0:
			reached += 1
	hud.set_line("50_move", "move: %d tiles in %.1f ms (%d states) — budget 50 ms" % [
		reached, float(_pathfinder.last_elapsed_usec) / 1000.0,
		_pathfinder.last_states_expanded,
	])


func _recompute_visibility() -> void:
	var u: UnitState = active_unit()
	if u == null:
		_exposure.fill(0)
		hud.clear_line("60_vis")
		return

	var t0: int = Time.get_ticks_usec()
	VisionField.compute(md, cfg, u.tile, _exposure)
	var exposed: int = 0
	var hull_down: int = 0
	for i: int in md.n:
		match int(_exposure[i]):
			Los.Exposure.EXPOSED:
				exposed += 1
			Los.Exposure.HULL_DOWN:
				hull_down += 1
	hud.set_line("60_vis", "sight: %d exposed, %d hull-down in %.1f ms" % [
		exposed, hull_down, float(Time.get_ticks_usec() - t0) / 1000.0,
	])


func _repaint() -> void:
	var o: OverlayLayer = view.overlay
	o.clear_all()

	if _overlay == Overlay.MOVEMENT and _reachable.size() == md.n:
		var move := PackedByteArray()
		move.resize(md.n)
		for i: int in md.n:
			if _reachable[i] >= 0:
				move[i] = 255
		o.set_channel(OverlayLayer.R, move)
	elif _overlay == Overlay.VISIBILITY:
		o.set_channel(OverlayLayer.G, VisionField.to_channel(_exposure))

	# Hover and path preview go in the highlight channel. The shader outlines the hover tile and
	# fills the path, so the two need to stay in separate value bands.
	if _preview != null and _preview.found:
		for k: int in _preview.tiles.size():
			o.set_tile(_preview.tiles[k], OverlayLayer.B, 128)
	if _hover_tile >= 0:
		o.set_tile(_hover_tile, OverlayLayer.B, 255)

	o.upload()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover(event.position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_on_click(mb.position)


func _busy() -> bool:
	for k: int in views.size():
		if views[k].is_moving():
			return true
	return false


func _update_hover(screen_pos: Vector2) -> void:
	if _busy():
		return
	var tile: int = TilePicker.pick(md, camera.camera, screen_pos)
	if tile == _hover_tile:
		return
	_hover_tile = tile
	_preview = null

	var u: UnitState = active_unit()
	if tile >= 0:
		var cost: int = _reachable[tile] if _reachable.size() == md.n else -1
		if cost >= 0 and u != null:
			_preview = _pathfinder.find_path(u.tile, u.facing, tile, u.mp_left)
		hud.set_line("70_tile", _describe(tile, cost))
	else:
		hud.clear_line("70_tile")

	_repaint()


func _describe(tile: int, cost: int) -> String:
	# The terrain name is the natural ground now that a road is a layer over it rather than a type
	# of it, so a road has to be named separately or it disappears from the readout.
	var name: String = cfg.terrain_names[int(md.terrain[tile])]
	if md.has_road(tile):
		name += " + road"
	var exposure: String = ["masked", "hull down", "exposed"][int(_exposure[tile])]
	var reach: String = "unreachable" if cost < 0 else "%d mp" % cost
	var extra: String = ""
	if _preview != null and _preview.found and _preview.blocks_firing:
		extra = "  (rough going — could not fire this turn)"
	var who: int = match_state.unit_at(tile)
	if who >= 0:
		extra += "  [side %d unit]" % match_state.units[who].side
	return "tile (%d,%d)  %s  %.1f m  %s  %s%s" % [
		md.tx(tile), md.ty(tile), name, md.height_m(tile), reach, exposure, extra,
	]


func _on_click(screen_pos: Vector2) -> void:
	if _busy():
		return
	var tile: int = TilePicker.pick(md, camera.camera, screen_pos)
	if tile < 0:
		return

	# Clicking a unit selects it, if it is on the side whose turn it is. Clicking anywhere else is
	# an order for whoever is already selected.
	var who: int = match_state.unit_at(tile)
	if who >= 0:
		if match_state.is_selectable(who):
			select_unit(who)
		else:
			hud.set_line("80_order", "that unit belongs to side %d — it is side %d's turn" % [
				match_state.units[who].side, match_state.active_side,
			])
		return

	var u: UnitState = active_unit()
	if u == null:
		return
	if u.activated:
		hud.set_line("80_order", "that unit has already acted this turn")
		return
	if _reachable.size() != md.n or _reachable[tile] < 0:
		hud.set_line("80_order", "that tile is out of range")
		return

	var path: PathResult = _pathfinder.find_path(u.tile, u.facing, tile, u.mp_left)
	if not path.found:
		hud.set_line("80_order", "no route to that tile")
		return

	hud.set_line("80_order", "moving %d tiles, %d mp%s" % [
		path.length() - 1, path.cost, "  (rough going)" if path.blocks_firing else "",
	])
	# The simulation moves first and the view catches up, so an interrupted animation can never
	# leave the two disagreeing about where the tank is.
	u.apply(path)
	var v: TankView = active_view()
	if v != null:
		v.play(path)
	_preview = null
	_hover_tile = -1


func _on_move_finished(index: int) -> void:
	# A unit that cannot afford even the cheapest step has nothing left to do, so it stops being
	# somewhere Tab lands and the End Turn button lights up when the last of them is spent.
	var u: UnitState = match_state.unit(index)
	if u != null and not u.can_act(cfg):
		match_state.mark_activated(index)

	if index != match_state.selected:
		return
	refresh_all()

	if cfg.b("turn.auto_advance_on_exhausted", true) and u != null and u.activated:
		if not match_state.all_activated():
			cycle_unit(1)
			selection_changed.emit(match_state.selected)
