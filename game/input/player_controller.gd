class_name PlayerController
extends Node

## Selection, hover, path preview, move orders, the turn controls, and the two overlays.
##
## The overlays are the whole point of iteration 1. The movement overlay says where the selected
## unit can get to, accounting for facing and turning; the visibility overlay says what a tank
## standing on each tile would look like to it. Both are painted into the same small texture and
## both are recomputed only when something actually changes — which now includes changing which
## unit is selected, not just moving one.
##
## What this class no longer does is decide what a move *is*. Legality, the route, the movement
## points it spends and whether it uses the unit up are all `ActionResolver`'s, and it hands back an
## ordered event list that `ActionPlayer` replays — docs/decisions/0022. The controller's remaining
## job is turning clicks into orders and simulation state into things on screen.

signal selection_changed(index: int)

enum Overlay { MOVEMENT, VISIBILITY, NONE }

var md: MapData
var cfg: Config
var view: TerrainView
var match_state: MatchState
var views: Array[TankView] = []
var camera: TacticalCamera
var director: CameraDirector
var hud: Hud

## Whose eyes the screen belongs to — docs/decisions/0034. Every unit on screen, every card, every
## readout and every replay is filtered through this side's `SideKnowledge`, and nothing in `game/`
## consults ground truth about an enemy without going through `ViewState` first.
##
## Hot-seat keeps it equal to the active side, so the board flips over at hand-over and each player
## sees only what their own side has earned. It is a separate variable rather than a call to
## `match_state.active_side` precisely because that is a hot-seat *policy* and not a fact: the moment a
## side is played by an AI, this stops tracking and stays on the human's side, and that is the whole
## change (docs/hull-down-v2.md 2e-i).
var viewing_side: int = 1

## Everything to do with what a move is and whether it is allowed lives behind this — the
## pathfinders, the occupancy overlay, legality, and the event stream a move resolves to.
## docs/decisions/0022.
var resolver: ActionResolver
## Owned here rather than passed in: `setup` already takes eight arguments and nothing else needs
## either of them. `main.gd` reaches the playback controls through this class, which keeps it as
## pure wiring.
var player: ActionPlayer
## One action at a time is all hot-seat ever needs; this is the seam an AI turn plays back through.
var queue: ActionQueue
var markers: PathMarkers
## The sound layer's markers — docs/decisions/0037. A sibling of `markers` rather than a mode of it:
## a route preview and a contact are answers to different questions and share no geometry.
var sounds: SoundMarkers
## The objective flags — docs/decisions/0044. Possession is public, so these repaint from ground
## truth in `_refresh_unit_visuals` while everything else there goes through `ViewState`.
var objectives: ObjectiveMarkers

var _reachable: PackedInt32Array
var _exposure: PackedByteArray
## How many of the viewing side's overwatch arcs cover each tile — docs/decisions/0036. A count, not a
## flag: overlap is the information.
var _arcs: PackedByteArray
## Scratch for one watcher's line of sight, reused across watchers rather than reallocated per unit.
var _arc_field: PackedByteArray
var _overlay: int = Overlay.MOVEMENT
var _hover_tile: int = -1
## The planned-but-uncommitted version of the order the cursor is currently proposing.
var _preview: ActionResult
## What the viewing side could see at the moment the order in flight was issued — see `_snapshot`.
var _mask: PackedByteArray = PackedByteArray()
## The action bar's overwatch button was pressed and the next click on the board is the bearing.
## Owned here because it changes what a click *is*; the bar only displays it.
var _aiming_overwatch: bool = false
## Whether this action's enemy movement has been announced yet — one ticker line per action, not
## one per step. Reset by `_on_playback_started`.
var _move_narrated: bool = false


func setup(
	map: MapData, config: Config, terrain: TerrainView, state: MatchState,
	tank_views: Array[TankView], tactical: TacticalCamera, camera_director: CameraDirector,
	heads_up: Hud
) -> void:
	md = map
	cfg = config
	view = terrain
	match_state = state
	views = tank_views
	camera = tactical
	director = camera_director
	hud = heads_up

	# The map carries the seed the whole match is reconstructible from — docs/decisions/0005. Reading
	# it here rather than taking it as an argument is what stops the combat rolls and the terrain
	# coming from two different numbers on a loaded map.
	resolver = ActionResolver.new(md, cfg, match_state, md.master_seed)

	player = ActionPlayer.new()
	add_child(player)
	player.setup(cfg, views, view, camera)
	player.started.connect(_on_playback_started)
	player.finished.connect(_on_playback_finished)
	player.event_reached.connect(_on_event_shown)

	queue = ActionQueue.new()
	add_child(queue)
	queue.setup(player)
	queue.drained.connect(_on_queue_drained)

	markers = PathMarkers.new()
	add_child(markers)
	markers.setup(cfg, view)

	sounds = SoundMarkers.new()
	add_child(sounds)
	sounds.setup(cfg, view)
	player.sounds = sounds

	objectives = ObjectiveMarkers.new()
	add_child(objectives)
	objectives.setup(cfg, view)
	# The starting holders are the baseline, not news — the dig-in defense deploys already holding
	# its flags, and a ticker announcing that would be noise.
	_held_last = Victory.held_by(md, cfg, match_state)

	_exposure = PackedByteArray()
	_exposure.resize(md.n)
	_arcs = PackedByteArray()
	_arcs.resize(md.n)
	_arc_field = PackedByteArray()
	_arc_field.resize(md.n)

	viewing_side = match_state.active_side

	_refresh_speed_line()
	refresh_all()


## Freeze what the viewing side can see, **before** an order resolves.
##
## Resolving mutates knowledge — that is what `SPOT` events are the account of. A mask taken afterwards
## would say every unit this action revealed had been visible all along, and `ViewState.filter` would
## pass the whole stream through, steps before the reveal included. That is the precise leak the filter
## exists to stop, and it fails silently, so the ordering is pinned by `tests/test_replay_filter.gd`.
func _snapshot() -> void:
	_mask = ViewState.all(match_state, viewing_side)


## Replay an order through the viewing side's eyes, using the mask `_snapshot` froze.
##
## Filtered here, at resolve time, and handed to the queue already filtered — see `ActionQueue`'s
## docstring for why that cannot wait until playback.
func _replay(res: ActionResult) -> void:
	queue.submit(res, ViewState.filter(res.events, _mask, viewing_side))


## Whether the viewing side may be told anything at all about this unit.
func _knows(index: int) -> bool:
	return ViewState.is_drawn(ViewState.of(match_state, viewing_side, index))


## The unit standing on a tile **as far as the viewing side is concerned**, or -1.
##
## `MatchState.unit_at` is ground truth and stays that way — the pathfinder and the occupancy overlay
## need it to be. Everything that answers a *player's* question goes through this instead, because
## otherwise hovering blank ground pops an unspotted tank's card and the readout names its side.
func _visible_unit_at(tile: int) -> int:
	if tile < 0:
		return -1
	var who: int = match_state.unit_at(tile)
	return who if who >= 0 and _knows(who) else -1


## Bring both sides' contacts up to date before anything is ordered. Without this the first move of
## the match would emit a `SPOT` for every enemy that was already in plain view at deployment, and
## the reveal markers would all appear at once on an unrelated action.
func prime_knowledge() -> void:
	resolver.refresh_knowledge()
	# And redraw, because until this ran every side knew nothing and `refresh_all` in `setup` therefore
	# hid the entire board. The order is forced — `ActionResolver` is built inside `setup` — so the
	# repaint belongs here rather than being left for the first mouse move to trigger.
	refresh_all()


func active_unit() -> UnitState:
	return match_state.selected_unit()


func active_view() -> TankView:
	var i: int = match_state.selected
	return views[i] if i >= 0 and i < views.size() else null


## Whether an action is being replayed. Everything that could change the simulation underneath one
## is gated on this — the HUD buttons through `Hud.set_controls_enabled`, and every key in
## `main.gd`. Pressing End Turn mid-move used to refill the unit that was still animating.
func is_busy() -> bool:
	return player != null and (player.is_playing() or queue.is_busy())


func cycle_overlay() -> void:
	if is_busy():
		return
	_overlay = (_overlay + 1) % 3
	_repaint()
	hud.set_line("40_overlay", "overlay: %s" % ["movement", "visibility", "off"][_overlay])


func select_unit(index: int) -> void:
	if is_busy():
		return
	if index < 0 or not match_state.select(index):
		return
	_aiming_overwatch = false
	_clear_preview()
	refresh_all()
	selection_changed.emit(index)


## Arm (or stand down) the overwatch aim mode — the action bar's two-step version of the O key.
## While armed, the next click on the board lays the watch toward that tile instead of moving.
func toggle_overwatch_aim() -> void:
	if is_busy() or match_state.selected < 0:
		return
	_aiming_overwatch = not _aiming_overwatch
	if _aiming_overwatch:
		hud.notify("overwatch: click the ground to cover", "warn")
	_refresh_status()


## Traverse the gun one notch — docs/decisions/0035. Free, and legal at zero movement points, which is
## the whole point, so this is deliberately not gated on the unit being able to act.
##
## The key is relative and the action is absolute (0027): the bearing is resolved here, once, rather
## than teaching `TurretAction` about notches. `step` is +1 or -1.
func traverse_turret(step: int) -> void:
	if is_busy() or match_state.selected < 0:
		return
	var u: UnitState = match_state.selected_unit()
	if u == null:
		return

	var notches: int = maxi(cfg.i("turn.turret_step_steps", 1), 1)
	var bearing: int = posmod(u.turret + (notches if step > 0 else -notches), 8)

	var res: ActionResult = resolver.resolve_turret(match_state.selected, bearing)
	if not res.ok():
		hud.notify(_order_message(res.status), "warn")
		return
	hud.notify("turret bearing %s" % _COMPASS[bearing & 7])
	_clear_preview()
	refresh_all()
	_repaint()


## The second cycling key: every unit of the side in deployment order, including the ones that are
## finished. `cycle_unit` answers "what next", this answers "let me look at that one" — 0032.
## The tile the mouse is over, or -1. What the overwatch key aims along.
func hover_tile() -> int:
	return _hover_tile


func cycle_roster(step: int) -> void:
	if is_busy():
		return
	select_unit(match_state.cycle_all(step))


func cycle_unit(step: int) -> void:
	if is_busy():
		return
	select_unit(match_state.cycle(step))


func end_turn() -> void:
	if is_busy() or _match_over:
		return
	_aiming_overwatch = false
	# Through the resolver, not straight into `MatchState`: handing over is also when every side's
	# contacts are brought up to date, and only the resolver can see the ground they are seen across.
	resolver.end_turn()

	# Against an AI, the screen never changes hands — the enemy's turns play out as filtered
	# replays and control comes back here. docs/decisions/0041.
	if not ai_policies.is_empty():
		_note_holder_changes()
		_advance_past_ai_turns()
		return

	# Hot-seat, so the screen changes hands with the turn — docs/decisions/0012 and 0034. The whole
	# board is redrawn from the incoming side's knowledge: what the last player had spotted goes away
	# unless this one has spotted it too, which is the point of two players sharing one screen.
	viewing_side = match_state.active_side

	# Noted after the flip, so "captured"/"lost" is phrased for the eyes about to read it.
	_note_holder_changes()
	_flush_capture_notes()

	_clear_preview()
	refresh_all()
	selection_changed.emit(match_state.selected)


# --- playing against the AI — 2f, docs/decisions/0038 and 0041 -------------------------------------


## side -> Policy for every side the machine plays; empty means hot-seat. The scenario, when there
## is one, owns the waves and the clock.
var ai_policies: Dictionary = {}
var scenario: Scenario = null
var _match_over: bool = false
## The hand-over UI work still owed once the queued replays finish playing.
var _handover_pending: bool = false

const _GRADE_NAMES: Dictionary = {
	Victory.Grade.DECISIVE_DEFEAT: "DECISIVE DEFEAT",
	Victory.Grade.MARGINAL_DEFEAT: "Marginal defeat",
	Victory.Grade.DRAW: "Draw",
	Victory.Grade.MARGINAL_VICTORY: "Marginal victory",
	Victory.Grade.DECISIVE_VICTORY: "DECISIVE VICTORY",
}


## Put the machine on some sides. `side` is the human's, and the screen stays that side's for the
## whole match.
func configure_opponents(policies: Dictionary, side: int, sc: Scenario) -> void:
	ai_policies = policies
	scenario = sc
	viewing_side = side


## Called once after `prime_knowledge`: if the mission opens on a machine side — the dig-in
## defender plays second — its turns run before the player ever holds the board.
func begin_match() -> void:
	if not ai_policies.is_empty() and ai_policies.has(match_state.active_side):
		_advance_past_ai_turns()


## Run machine turns until the board is the player's again or the match is decided. Every AI order
## is queued as a filtered replay; the hand-over UI work waits for the queue to drain.
func _advance_past_ai_turns() -> void:
	while not _check_match_over():
		var side: int = match_state.active_side
		if not ai_policies.has(side):
			break
		_spawn_waves()
		var watched: Array[Dictionary] = AiRunner.run_turn_watched(
			resolver, ai_policies[side], viewing_side
		)
		for entry: Dictionary in watched:
			queue.submit(entry["result"], entry["events"])
		resolver.end_turn()
		_note_holder_changes()

	# The player's own reinforcements arrive as their turn opens.
	if not _match_over and not ai_policies.has(match_state.active_side):
		_spawn_waves()

	if queue.is_busy():
		_handover_pending = true
	else:
		_finish_handover()


func _spawn_waves() -> void:
	if scenario == null:
		return
	if not scenario.spawn_due(md, cfg, match_state).is_empty():
		resolver.refresh_knowledge()


func _check_match_over() -> bool:
	if _match_over:
		return true
	var limit: int = scenario.turn_limit if scenario != null else 0
	if Victory.over(md, cfg, match_state, limit):
		_match_over = true
	return _match_over


func _finish_handover() -> void:
	_clear_preview()
	refresh_all()
	selection_changed.emit(match_state.selected)
	# The flag news lands with the hand-over, after the replays that explain it have played.
	_flush_capture_notes()
	if _match_over:
		var g: int = Victory.grade(md, cfg, match_state, viewing_side)
		var outcome: String = "Match over — %s (%d points against %d)" % [
			_GRADE_NAMES.get(g, "?"),
			Victory.points_held(md, cfg, match_state, viewing_side),
			Victory.points_held(md, cfg, match_state, 3 - viewing_side),
		]
		# The persistent line is the record; the ticker line is what makes it land the moment the
		# last replay finishes, when the player's eyes are on the board and not the corner.
		hud.set_line("85_outcome", outcome)
		hud.notify(outcome, "kill")


func _on_queue_drained() -> void:
	if _handover_pending:
		_handover_pending = false
		_finish_handover()


# --- terrain control on screen — docs/decisions/0040 and 0044 --------------------------------------


## Holders as of the last time anyone looked, parallel to `md.objectives`. The baseline is set at
## `setup`, so the flags a force starts on are state, not news.
var _held_last: PackedInt32Array = PackedInt32Array()
## Ticker lines owed for flag changes, held until the board is the player's again — the news should
## land after the replays that explain it, the way the outcome line does.
var _capture_notes: Array[Dictionary] = []


## Compare the holders now against `_held_last` and queue a ticker line per change. Called at turn
## boundaries rather than per action: a flag "changes hands" when a turn ends with it held, which
## is also when `Victory.tick` counts it.
func _note_holder_changes() -> void:
	var now: PackedInt32Array = Victory.held_by(md, cfg, match_state)
	for k: int in now.size():
		var was: int = int(_held_last[k]) if k < _held_last.size() else 0
		var is_now: int = int(now[k])
		if was == is_now:
			continue
		var what: String = "Objective %d (%d pts)" % [k + 1, md.objective_worth(k)]
		if is_now == viewing_side:
			_capture_notes.append({"text": "%s captured" % what, "category": "good"})
		elif is_now == 0:
			_capture_notes.append({
				"text": "%s %s" % [what, "lost" if was == viewing_side else "cleared"],
				"category": "warn" if was == viewing_side else "good",
			})
		else:
			_capture_notes.append({"text": "%s taken by the enemy" % what, "category": "warn"})
	_held_last = now


func _flush_capture_notes() -> void:
	for note: Dictionary in _capture_notes:
		hud.notify(str(note["text"]), str(note["category"]))
	_capture_notes.clear()


func recenter() -> void:
	if is_busy():
		return
	var u: UnitState = active_unit()
	if u != null:
		camera.recenter_on(u.tile)


func set_playback_speed(s: int) -> void:
	if player == null:
		return
	player.set_speed(s)
	_refresh_speed_line()


## Cut to the end of a replay. Always available, which is what makes locking the controls for the
## duration cost the player nothing.
##
## Everything queued, not just the action on screen: a player who presses skip during someone else's
## turn has asked to stop watching, not to stop after this one.
func skip_playback() -> void:
	if queue != null:
		queue.skip_all()
	elif player != null:
		player.skip()


## Re-read the tile under the cursor. For whoever has just stopped suppressing hover — leaving the
## gunner view, or the end of a replay — because the mouse has very likely not moved since, and
## nothing else would refresh the readout until it does.
func refresh_hover() -> void:
	_hover_tile = -1
	_update_hover(get_viewport().get_mouse_position())


func _refresh_speed_line() -> void:
	if player != null:
		hud.set_line("45_speed", "playback: %s" % player.speed_name())


func refresh_all() -> void:
	_recompute_movement()
	_recompute_visibility()
	_recompute_overwatch()
	_repaint()
	_refresh_status()
	_refresh_unit_visuals()


## The ground the viewing side's own overwatch covers, counted per tile — docs/decisions/0036.
##
## **Own arcs only.** An enemy's watch bearing is precisely the information the ambush mechanic exists
## to withhold (0030); drawing it would undo the rule. Where the overlap shading earns its keep is six
## of your own tanks covering one valley, which is a question about your own dispositions anyway.
##
## Three clipping rules, in the order that makes them cheapest: line of sight, then range, then the
## arc. `VisionField.compute` is the expensive one and runs once per watcher rather than once per tile,
## which is what keeps this off the frame budget — it is the same call `_recompute_visibility` already
## makes for the selected unit, and it is measured in milliseconds.
func _recompute_overwatch() -> void:
	_arcs.fill(0)
	var arc_steps: int = cfg.i("combat.overwatch_arc_steps", 1)

	for index: int in match_state.side_roster(viewing_side):
		var u: UnitState = match_state.unit(index)
		if u == null or not u.alive or u.overwatch_dir < 0:
			continue

		VisionField.compute(md, cfg, u.tile, _arc_field)
		# Optics rather than a separate weapon range, because `Overwatch.triggers` will not fire at
		# something the side has not spotted — so what the gun could theoretically reach past that is
		# ground it cannot actually engage, and drawing it would promise cover that is not there.
		var reach: float = Spotting.optics_m(cfg, u)

		for t: int in md.n:
			if t == u.tile or _arc_field[t] == Los.Exposure.MASKED:
				continue
			if md.dist_m(u.tile, t) > reach:
				continue
			if Grid.turn_steps(u.overwatch_dir, Armor.bearing(md, u.tile, t)) > arc_steps:
				continue
			if _arcs[t] < 255:
				_arcs[t] += 1


func _clear_preview() -> void:
	_preview = null
	_hover_tile = -1
	if markers != null:
		markers.clear()


func _refresh_status() -> void:
	hud.set_line("05_turn", "turn %d — side %d — %d of %d units still to act" % [
		match_state.turn, match_state.active_side, match_state.remaining_on_side(),
		match_state.side_units(match_state.active_side).size(),
	])
	hud.set_end_turn_ready(match_state.all_activated())

	# The score in play — 0044. `3 - viewing_side` is the file's two-side shorthand, as at the
	# outcome line.
	if md.objectives.is_empty():
		hud.clear_line("80_vp")
	else:
		var held: PackedInt32Array = Victory.held_by(md, cfg, match_state)
		var mine: int = 0
		var theirs: int = 0
		for k: int in held.size():
			if held[k] == viewing_side:
				mine += 1
			elif held[k] != 0:
				theirs += 1
		hud.set_line("80_vp", "objectives: yours %d (%d pts) — enemy %d (%d pts) — %d open" % [
			mine, Victory.points_held(md, cfg, match_state, viewing_side),
			theirs, Victory.points_held(md, cfg, match_state, 3 - viewing_side),
			held.size() - mine - theirs,
		])

	var u: UnitState = active_unit()
	hud.set_action_bar(
		u, u != null and u.side == match_state.active_side and u.side == viewing_side,
		_aiming_overwatch
	)
	if u == null:
		hud.clear_line("15_unit")
		return
	hud.set_line("15_unit", "unit %d of %d — %s — %d/%d mp%s" % [
		match_state.selected + 1, match_state.units.size(),
		cfg.unit(String(u.unit_type)).get("display_name", u.unit_type),
		u.mp_left, u.mp_max, "   (done)" if u.activated else "",
	])


## Put every unit on screen where the viewing side believes it to be — docs/decisions/0034.
##
## **The one place the simulation reaches the renderer.** It walks `ViewState`, which decides both
## whether a unit may be drawn and which of `UnitState` and `Contact` its pose comes from; this
## function makes no such choice and must never acquire one. Everything else in `game/` that wants to
## know where an enemy is asks `_visible_unit_at`.
##
## The arrow marks the selected unit. Bars belong to your own units only — an enemy's remaining
## movement points are not something a sighting tells you, and four bars on screen when only two can be
## ordered was noise even when it was free (docs/decisions/0023).
func _refresh_unit_visuals() -> void:
	var ghost_turns: int = cfg.i("spotting.ghost_turns", 2)
	var kinds: PackedByteArray = ViewState.all(match_state, viewing_side)

	for k: int in views.size():
		var kind: int = int(kinds[k]) if k < kinds.size() else ViewState.Kind.HIDDEN
		var p: Vector3i = ViewState.pose(match_state, viewing_side, k)
		views[k].apply(
			kind, p.x, p.y, p.z, ViewState.fade(match_state, viewing_side, k, ghost_turns)
		)

		if views[k].marker == null:
			continue
		if kind == ViewState.Kind.OWN:
			var u: UnitState = match_state.unit(k)
			views[k].set_bar(u.mp_left, u.activated, k == match_state.selected)
			views[k].marker.set_bar_visible(true)
		else:
			views[k].marker.set_bar_visible(false)

	# The sound layer, from the same viewing side and through the same one door. `sound_contacts`
	# returns the boundary type, which carries no unit index at all, so this call cannot hand the
	# renderer an identity even if a later edit wanted one — docs/decisions/0033.
	sounds.show_contacts(match_state.sound_contacts(viewing_side))

	# The flags, from ground truth — the one deliberate exception to the eyes-of rule here, and
	# it hands the renderer side ids only. docs/decisions/0044.
	objectives.show_objectives(md, Victory.held_by(md, cfg, match_state))

	_show_card_for(match_state.selected)
	hud.set_roster(match_state, cfg, viewing_side, match_state.selected)


## The corner card, for a unit the viewing side is entitled to read.
##
## An unknown unit clears the card rather than filling it, and that check is not belt-and-braces: the
## card carries armor by facing, ammunition remaining and criticals taken, which is the single richest
## payload in the UI and exactly what an unspotted enemy must not hand over.
func _show_card_for(index: int) -> void:
	var u: UnitState = match_state.unit(index)
	if u == null or not _knows(index):
		hud.clear_unit_card()
		return
	hud.set_unit_card(
		u, cfg, md, index, match_state.units.size(),
		int(_exposure[u.tile]) if _exposure.size() == md.n else 0,
		u.side == match_state.active_side,
		_forecast_against(index)
	)


## The odds of shooting `target` with whatever is selected, or null when that is not a shot.
##
## `preview_fire` is pure, in the same way and for the same reason `plan_move` is — it may be asked on
## every mouse move and it advances no roll. That purity is what makes showing this on hover possible
## at all, and it has been available since the combat batch; nothing had ever called it outside the
## commit path, where the odds arrive one click too late to inform anything.
func _forecast_against(target: int) -> FireForecast:
	if match_state.selected < 0 or target < 0 or target == match_state.selected:
		return null
	if ViewState.of(match_state, viewing_side, target) != ViewState.Kind.SEEN:
		return null
	if match_state.unit(target).side == viewing_side:
		return null
	return resolver.preview_fire(match_state.selected, target)


## Movement points the near band is drawn at: what is left of the action already in progress.
##
## Not a fresh action's worth measured from where the tank now stands — that hands back the movement
## it just spent. See `UnitState.near_mp` and docs/decisions/0021.
func _near_budget() -> int:
	var u: UnitState = active_unit()
	if u == null:
		return 0
	return u.near_mp(cfg)


func _recompute_movement() -> void:
	var u: UnitState = active_unit()
	if u == null:
		_reachable = PackedInt32Array()
		hud.clear_line("50_move")
		return

	_reachable = resolver.reachable(match_state.selected)
	var pf: TankPathfinder = resolver.pathfinder_for(u)
	var near_budget: int = u.near_mp(cfg)
	var reached: int = 0
	var near: int = 0
	for i: int in md.n:
		var cost: int = _reachable[i]
		if cost < 0:
			continue
		reached += 1
		if cost <= near_budget:
			near += 1

	# Says which band is which rather than "one action, two actions", because after a part-move the
	# near band is the remainder of an action already begun, not a whole one.
	if near == reached:
		hud.set_line("50_move", "move: %d tiles, all on this action, in %.1f ms (%d states)" % [
			reached, float(pf.last_elapsed_usec) / 1000.0, pf.last_states_expanded,
		])
	else:
		hud.set_line("50_move", "move: %d tiles on this action, %d spending both, in %.1f ms (%d states)" % [
			near, reached, float(pf.last_elapsed_usec) / 1000.0, pf.last_states_expanded,
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
		# Two bands in one channel: 255 is reachable on what remains of the action in progress, 128
		# needs the next one too. Disjoint, so the shader outlines the boundary from both sides.
		# docs/decisions/0014, as amended by 0021.
		var near: int = _near_budget()
		var move := PackedByteArray()
		move.resize(md.n)
		for i: int in md.n:
			var cost: int = _reachable[i]
			if cost < 0:
				continue
			move[i] = 255 if cost <= near else 128
		o.set_channel(OverlayLayer.R, move)
	elif _overlay == Overlay.VISIBILITY:
		o.set_channel(OverlayLayer.G, VisionField.to_channel(_exposure))

	# Only the hover tile goes in the highlight channel now. The route used to be painted here too,
	# as a flat tint over every tile it entered, and a ten-meter staircase turned out to be a poor
	# description of a line — `PathMarkers` draws it as real geometry instead. The shader's path
	# band is left in place and simply unfed.
	if _hover_tile >= 0:
		o.set_tile(_hover_tile, OverlayLayer.B, 255)

	# Overwatch arcs are drawn under every overlay mode rather than being one of the things `V` cycles
	# between. They are not a query the player ran — they are standing orders their own tanks are
	# under, and a wedge that vanishes when you switch to the movement overlay is one you forget about
	# at exactly the moment it matters.
	o.set_channel(OverlayLayer.A, _arcs)

	o.upload()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover(event.position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_on_click(mb.position)


## Pick against the camera that is actually rendering, not against the tactical one.
##
## `TilePicker` turns a screen position into a world ray via `Camera3D.project_ray_origin`, so
## asking the overhead camera where the mouse points while the gunner view is on screen produces a
## ray from somewhere the player is not looking — which is why hovering in the gunner view lit up
## unrelated tiles across the map.
func _active_camera() -> Camera3D:
	var cam: Camera3D = get_viewport().get_camera_3d()
	return cam if cam != null else camera.camera


## The gunner view exists to look, not to order. Hover and orders are suspended while it is up, so
## a right-drag to turn the turret cannot also become a move order and the highlight does not chase
## the crosshair.
func _in_gunner() -> bool:
	return director != null and director.is_gunner_view()


func _update_hover(screen_pos: Vector2) -> void:
	if is_busy() or _in_gunner():
		return
	var tile: int = TilePicker.pick(md, _active_camera(), screen_pos)
	if tile == _hover_tile:
		return
	_hover_tile = tile
	_preview = null
	markers.clear()

	if tile >= 0:
		var cost: int = _reachable[tile] if _reachable.size() == md.n else -1
		if cost >= 0 and match_state.selected >= 0:
			# Pure — plans the whole move, including its event list, and changes nothing. Safe to
			# run on every hover-tile change, which is the point of the plan/resolve split.
			_preview = resolver.plan_move(match_state.selected, tile, _reachable)
			markers.show_path(_preview, _near_budget())
		hud.set_line("70_tile", _describe(tile, cost))

		# Hovering a unit reads its card, which is the only way to inspect one that cannot be selected
		# because it is not that side's turn. A unit this side has not spotted is not on the tile as far
		# as this is concerned — 0034.
		var who: int = _visible_unit_at(tile)
		_show_card_for(who if who >= 0 else match_state.selected)
	else:
		hud.clear_line("70_tile")
		_show_card_for(match_state.selected)

	_repaint()


func _describe(tile: int, cost: int) -> String:
	# The terrain name is the natural ground now that a road is a layer over it rather than a type
	# of it, so a road has to be named separately or it disappears from the readout.
	var name: String = cfg.terrain_names[int(md.terrain[tile])]
	if md.has_road(tile):
		name += " + road"
	var exposure: String = ["masked", "hull down", "exposed"][int(_exposure[tile])]
	var reach: String = "unreachable"
	if cost >= 0:
		# "1 action / 2 actions" was wrong once the near band became the remainder of an action
		# already begun: a tile inside it might be the last tile of the first action rather than a
		# whole action away. What the player wants to know is whether reaching it leaves an action.
		var near: int = _near_budget()
		reach = "%d mp (%s)" % [
			cost, "this action" if cost <= near else "spends both actions",
		]
	var extra: String = ""
	if _preview != null and _preview.path != null and _preview.path.found:
		# Now that the cost is attributed per tile, the split between driving and turning can be
		# shown — which is what explains an expensive-looking route on open ground.
		var turning: int = 0
		for k: int in _preview.path.turn_cost.size():
			turning += _preview.path.turn_cost[k]
		if turning > 0:
			extra += "  (%d driving, %d turning)" % [_preview.path.cost - turning, turning]
		if _preview.path.blocks_firing:
			extra += "  (rough going — could not fire this turn)"
	var who: int = _visible_unit_at(tile)
	if who >= 0:
		var kind: int = ViewState.of(match_state, viewing_side, who)
		extra += "  [%s]" % [
			"wreck" if kind == ViewState.Kind.WRECK
			else "last seen here" if kind == ViewState.Kind.GHOST
			else "side %d unit" % match_state.units[who].side
		]
	return "tile (%d,%d)  %s  %.1f m  %s  %s%s" % [
		md.tx(tile), md.ty(tile), name, md.height_m(tile), reach, exposure, extra,
	]


## Turn a refusal into something the player reads. The simulation deals in a `Status` enum and
## carries no English at all — docs/decisions/0022.
func _order_message(status: int) -> String:
	match status:
		ActionResult.Status.ALREADY_ACTED:
			return "that unit has already acted this turn"
		ActionResult.Status.NO_MOVEMENT:
			return "that unit has no movement left"
		ActionResult.Status.UNREACHABLE:
			return "that tile is out of range"
		ActionResult.Status.NO_ROUTE:
			return "no route to that tile"
		ActionResult.Status.OCCUPIED:
			return "another unit is standing there"
		ActionResult.Status.WRONG_SIDE:
			return "it is side %d's turn" % match_state.active_side
		ActionResult.Status.RETIRED_9:
			return ""
		ActionResult.Status.NO_AMMO:
			return "that unit is out of ammunition"
		ActionResult.Status.GUN_DAMAGED:
			return "that unit's gun has been knocked out"
		ActionResult.Status.OUT_OF_ARC:
			return "the turret cannot come round that far — turn the hull"
		ActionResult.Status.NOT_VISIBLE:
			return "nothing of yours can see that"
		ActionResult.Status.FIRE_BLOCKED:
			return "that unit crossed rough going this turn and cannot fire"
		ActionResult.Status.FRIENDLY:
			return "that is one of yours"
		ActionResult.Status.TARGET_GONE:
			return "that is already a wreck"
		ActionResult.Status.IMMOBILISED:
			return "that unit has thrown a track and cannot move"
		ActionResult.Status.SAME_TILE:
			return ""
		_:
			return ""


func _on_click(screen_pos: Vector2) -> void:
	if is_busy() or _in_gunner():
		return
	var tile: int = TilePicker.pick(md, _active_camera(), screen_pos)
	if tile < 0:
		return

	# The action bar armed overwatch, so this click is the bearing and nothing else — not a move,
	# not a selection, not a shot. The mode is one click deep by construction.
	if _aiming_overwatch:
		_aiming_overwatch = false
		set_overwatch(tile)
		_refresh_status()
		return

	# Clicking a unit selects it, if it is on the side whose turn it is. Clicking a *spotted enemy*
	# with one of yours selected is an order to shoot at it — the gesture is the same one that would
	# have merely inspected it before there was anything to shoot with.
	#
	# `_visible_unit_at`, not `MatchState.unit_at`: an unspotted tank is not on that tile as far as the
	# player is concerned, and the click falls through to a move order rather than to a refusal that
	# would have announced it. A ghost and a wreck fall through too — a memory is not a target, and
	# driving at where something was last seen is a perfectly ordinary order.
	var who: int = _visible_unit_at(tile)
	if who >= 0:
		if match_state.is_selectable(who):
			select_unit(who)
			return
		if match_state.selected >= 0 \
				and ViewState.of(match_state, viewing_side, who) == ViewState.Kind.SEEN:
			_fire_at(who)
			return
		if ViewState.of(match_state, viewing_side, who) == ViewState.Kind.SEEN:
			hud.notify("that unit belongs to side %d — it is side %d's turn" % [
				match_state.units[who].side, match_state.active_side,
			], "warn")
			return

	if match_state.selected < 0:
		return

	# The simulation resolves the whole move here and now — the unit is at the destination, its
	# points are spent, and it is marked done if that used it up — before anything is drawn. What
	# `play` gets is an account of how it happened, and nothing it does can change any of it.
	_snapshot()
	var res: ActionResult = resolver.resolve_move(match_state.selected, tile, _reachable)
	if not res.ok():
		var message: String = _order_message(res.status)
		# An `OCCUPIED` refusal on a tile the player can see nothing standing on would announce the
		# unspotted tank that is standing there. It becomes the generic wording instead — 0034.
		#
		# This is the shallow half of the problem and it is worth saying which half: the *route* is
		# still planned against ground-truth occupancy, so a path that bends around an empty-looking
		# tile is still a tell. Fixing that means giving the pathfinder a per-side occupancy overlay,
		# which is a rule change and wants its own record.
		if res.status == ActionResult.Status.OCCUPIED and who < 0:
			message = _order_message(ActionResult.Status.NO_ROUTE)
		hud.notify(message, "warn")
		return

	hud.notify("moving %d tiles, %d mp%s" % [
		res.path.length() - 1, res.cost(), "  (rough going)" if res.path.blocks_firing else "",
	])
	_clear_preview()
	_repaint()
	_replay(res)


## Shoot at a spotted enemy. The forecast has been on screen since the cursor arrived over it — see
## `_forecast_against` — so this is the commitment rather than the first the player hears of the odds.
func _fire_at(target: int) -> void:
	var forecast: FireForecast = resolver.preview_fire(match_state.selected, target)
	if not forecast.ok():
		hud.notify(_order_message(forecast.status), "warn")
		return

	_snapshot()
	var res: ActionResult = resolver.resolve_fire(match_state.selected, target)
	if not res.ok():
		hud.notify(_order_message(res.status), "warn")
		return

	# No summary line: the ticker narrates the shots one by one as the replay reaches them, which
	# is the same account in the same words, on the beats the rounds actually land.
	_clear_preview()
	_repaint()
	_replay(res)


## Lay overwatch down the bearing from the selected unit to a clicked tile. Costs the whole turn.
func set_overwatch(tile: int) -> void:
	if is_busy() or match_state.selected < 0 or tile < 0:
		return
	var u: UnitState = match_state.selected_unit()
	if u == null:
		return

	var aim: int = Armor.bearing(md, u.tile, tile)
	var res: ActionResult = resolver.resolve_overwatch(match_state.selected, aim)
	if not res.ok():
		hud.notify(_order_message(res.status), "warn")
		return

	_aiming_overwatch = false
	hud.notify("watching %s — its turn is over" % _COMPASS[aim & 7], "good")
	_clear_preview()
	refresh_all()
	_repaint()


const _COMPASS: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


## "your Panzer IV" or "enemy Panzer IV" — how the ticker names a unit. Safe on anything the
## filtered stream carries: an event that survived `ViewState.filter` is one the viewing side is
## entitled to watch, type and all (the roster already names every SEEN contact).
func _unit_label(index: int) -> String:
	var u: UnitState = match_state.unit(index)
	if u == null:
		return "a unit"
	var name: String = str(cfg.unit(String(u.unit_type)).get("display_name", u.unit_type))
	return ("your %s" if u.side == viewing_side else "enemy %s") % name


## Turn one replayed event into a ticker line, on the beat `ActionPlayer` shows it — which is what
## makes "you spotted something" land when the marker appears and not when the dust settles.
##
## English lives here and not in `sim/` (0022), and the stream arriving through `event_reached` has
## already been filtered, so nothing narrated below can say more than the board is showing. The
## quiet kinds — BEGIN, TURN, TURRET, WATCH, ACTIVATED, END — narrate nothing: the ones that are
## your own orders were confirmed when they were given, and an enemy's are already visible as motion.
func _on_event_shown(ev: ActionEvent) -> void:
	match ev.kind:
		ActionEvent.Kind.STEP:
			# One line per action, on its first visible step. Your own moves are not news.
			if not _move_narrated and match_state.unit(ev.unit) != null \
					and match_state.unit(ev.unit).side != viewing_side:
				_move_narrated = true
				hud.notify("%s on the move" % _unit_label(ev.unit), "contact")
		ActionEvent.Kind.SPOT:
			hud.notify("contact — %s spotted" % _unit_label(ev.other), "contact")
		ActionEvent.Kind.LOST:
			hud.notify("contact lost — %s" % _unit_label(ev.other))
		ActionEvent.Kind.HEARD:
			hud.notify(
				"engine noise heard" if ev.is_sound_move() else "gunfire heard", "sound"
			)
		ActionEvent.Kind.FIRE:
			var line: String = "%s fires" % _unit_label(ev.unit)
			if ev.is_overwatch():
				line = "overwatch — " + line
			hud.notify(line, "info" if _ours(ev.unit) else "damage")
		ActionEvent.Kind.MISS:
			hud.notify("the shot misses")
		ActionEvent.Kind.HIT:
			var plate: String = _PLATES[ev.plate() % _PLATES.size()]
			if ev.penetrated():
				hud.notify(
					"penetrating hit — %s, %s" % [_unit_label(ev.other), plate],
					"damage" if _ours(ev.other) else "good"
				)
			else:
				hud.notify("hit bounces off %s's %s" % [_unit_label(ev.other), plate])
		ActionEvent.Kind.SHRED:
			hud.notify(
				"%d mm shot off %s's %s" % [
					ev.value, _unit_label(ev.other), _PLATES[ev.plate() % _PLATES.size()]
				],
				"damage" if _ours(ev.other) else "good"
			)
		ActionEvent.Kind.SHAKEN:
			hud.notify("%s's crew is shaken" % _unit_label(ev.other),
				"damage" if _ours(ev.other) else "good")
		ActionEvent.Kind.CRITICAL:
			hud.notify(
				"%s %s" % [
					_unit_label(ev.other),
					"is immobilised" if ev.component() == HitResolver.Component.IMMOBILISED
					else "has its gun knocked out",
				],
				"damage" if _ours(ev.other) else "good"
			)
		ActionEvent.Kind.DESTROYED:
			hud.notify("%s destroyed" % _unit_label(ev.other), "kill")
		_:
			pass


func _ours(index: int) -> bool:
	var u: UnitState = match_state.unit(index)
	return u != null and u.side == viewing_side


const _PLATES: Array[String] = ["front", "left side", "right side", "rear", "roof"]


func _on_playback_started(_result: ActionResult) -> void:
	_move_narrated = false
	hud.set_controls_enabled(false)


func _on_playback_finished(result: ActionResult) -> void:
	hud.set_controls_enabled(true)
	refresh_all()

	# Reading `activated`, never writing it. The resolver already decided this before any of the
	# above was drawn; auto-advancing the selection is a convenience for the player and stays here.
	var u: UnitState = match_state.unit(result.unit)
	if cfg.b("turn.auto_advance_on_exhausted", true) and u != null and u.activated:
		if not match_state.all_activated():
			cycle_unit(1)

	# The tile readout and the preview went stale while the controls were locked.
	refresh_hover()
