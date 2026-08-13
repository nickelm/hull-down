class_name ActionPlayer
extends Node

## Replays an action's event list on screen. Owns all animation timing, and nothing else.
##
## docs/decisions/0022. The simulation has already resolved the whole action by the time anything
## here runs — the unit is at the destination, its movement points are spent, and it is marked
## activated if that spent the last of them. This walks the account of how it got there.
##
## **Note what `setup` does not take: `MatchState`, `UnitState`, `ActionResolver`.** The guarantee
## that playback speed cannot change an outcome is structural, not a convention anyone has to
## remember: this object holds no reference it could write a simulation value through. Everything it
## draws comes out of the event list it was handed.
##
## That same emptiness is what makes fog of war work here — docs/decisions/0034. **The list handed to
## `play` has already been filtered by `ViewState.filter`**, so the one way this object could show the
## player a tank they have not spotted is by being given one. There is deliberately no visibility
## branch below: a rule spread across four `match` arms is a rule that has to stay right forever in
## four places, and this one is enforced upstream in pure code that a headless test can read.
##
## Durations are derived from the event's own data — a turn from `Grid.turn_steps`, a step from the
## distance between two tile centers — and never measured. 1x, 3x and instant are the same
## `_apply(event, t)` code path fed a differently scaled `delta`.

signal started(result: ActionResult)
signal finished(result: ActionResult)
## An event's turn on screen has come — emitted once per event, in stream order, at the moment its
## animation begins (skip and instant included, so a log built from this never loses lines to the
## skip key). This is the seam the event ticker narrates from; it carries the event and nothing
## else, so a listener can read but not steer.
signal event_reached(ev: ActionEvent)

enum Speed { NORMAL = 0, FAST = 1, INSTANT = 2 }

const SPEED_NAMES: Array[String] = ["1x", "3x", "instant"]

var cfg: Config
var views: Array[TankView] = []
var view: TerrainView
var camera: TacticalCamera
## Where a `HEARD` puts its ripple. A view node, like `views` and `view` — holding it does not weaken
## 0022's rule that this class has no reference it could write a *simulation* result through.
var sounds: SoundMarkers

var _result: ActionResult = null
## What is actually being replayed: the result's stream after `ViewState.filter`. Held separately from
## `_result.events` so that the unfiltered account stays intact for the caller's report, and so that a
## reader of this file cannot mistake one for the other.
var _events: Array[ActionEvent] = []
var _cursor: int = -1
var _elapsed: float = 0.0
var _duration: float = 0.0
var _from_pos: Vector3 = Vector3.ZERO
var _from_yaw: float = 0.0
var _to_pos: Vector3 = Vector3.ZERO
var _to_yaw: float = 0.0
var _from_turret_yaw: float = 0.0
var _to_turret_yaw: float = 0.0
var _facing: int = 0
var _turret: int = 0
var _tile: int = -1

var _speed: int = Speed.NORMAL
var _multiplier: float = 1.0

var _drive_speed: float = 26.0
var _reverse_speed: float = 16.0
var _turn_rate: float = 195.0
var _turret_rate: float = 320.0
var _min_event: float = 0.02
var _speed_normal: float = 1.0
var _speed_fast: float = 3.0
var _shot_flight: float = 0.28
var _shot_impact: float = 0.22
var _destroyed_beat: float = 0.7
var _spot_beat: float = 0.12


func setup(
	config: Config, tank_views: Array[TankView], terrain: TerrainView, tactical: TacticalCamera
) -> void:
	cfg = config
	views = tank_views
	view = terrain
	camera = tactical

	_drive_speed = maxf(cfg.f("playback.drive_speed_m_s", 26.0), 0.01)
	_reverse_speed = maxf(cfg.f("playback.reverse_speed_m_s", 16.0), 0.01)
	_turn_rate = maxf(cfg.f("playback.turn_rate_deg_s", 195.0), 1.0)
	# Faster than the hull, because a turret is. This is the only visible difference between the two
	# rotations and it is what makes the split legible without a single label on screen.
	_turret_rate = maxf(cfg.f("playback.turret_rate_deg_s", 320.0), 1.0)
	_min_event = maxf(cfg.f("playback.min_event_seconds", 0.02), 0.0001)
	_speed_normal = cfg.f("playback.speed_normal", 1.0)
	_speed_fast = cfg.f("playback.speed_fast", 3.0)
	# Shot and reveal events used to be instants, which made a whole fire action resolve in a
	# single frame — no time for the eye to register the sequence or for the ticker's lines to
	# arrive as one. These keys sat authored-but-unread in rules.json until now. The beats are
	# pacing, not simulation: skip and instant collapse them like every other duration.
	_shot_flight = maxf(cfg.f("playback.shot_flight_seconds", 0.28), 0.0)
	_shot_impact = maxf(cfg.f("playback.shot_impact_seconds", 0.22), 0.0)
	_destroyed_beat = maxf(cfg.f("playback.destroyed_seconds", 0.7), 0.0)
	_spot_beat = maxf(cfg.f("playback.spot_seconds", 0.12), 0.0)

	set_speed(cfg.i("playback.default_speed_index", Speed.NORMAL))

	# Run before the camera eases, or a follow push lands a frame late and the camera trails by an
	# extra frame at every speed.
	process_priority = -10
	set_process(false)


func is_playing() -> bool:
	return _result != null


func speed() -> int:
	return _speed


func speed_name() -> String:
	return SPEED_NAMES[_speed] if _speed >= 0 and _speed < SPEED_NAMES.size() else "?"


func set_speed(s: int) -> void:
	_speed = clampi(s, 0, Speed.INSTANT)
	_multiplier = _speed_fast if _speed == Speed.FAST else _speed_normal


## Replay a resolved action, showing only `events`.
##
## `events` is the result's stream after `ViewState.filter` — the caller passes it explicitly rather
## than this class reaching for `result.events`, because the difference between the two *is* the fog of
## war and a defaulted argument is one a call site can forget. docs/decisions/0034.
##
## A refused result, or one filtered down to nothing, finishes immediately rather than being silently
## dropped, so the caller's unlock path runs exactly once either way. It used to plain `return` here —
## which was survivable while every stream was replayed in full, and became a hung UI the moment an
## enemy could move somewhere the player cannot see.
func play(result: ActionResult, events: Array[ActionEvent]) -> void:
	if is_playing():
		skip()
	if result == null or not result.ok() or events.is_empty():
		if result != null:
			started.emit(result)
			finished.emit(result)
		return

	_result = result
	_events = events
	_cursor = -1

	var first: ActionEvent = _events[0]
	_tile = first.tile
	_facing = first.facing
	_from_pos = view.tile_center(_tile)
	_to_pos = _from_pos
	_from_yaw = TankView.facing_yaw(_facing)
	_to_yaw = _from_yaw

	# The turret's starting bearing is read off the view, which was posed from knowledge when the last
	# replay finished. `BEGIN` does not carry it and should not: it carries the pose the *action*
	# starts from, and the turret has not been part of an action until one moves it.
	var actor: TankView = _view_for(result.unit)
	_turret = actor.turret_facing if actor != null else _facing
	_from_turret_yaw = actor.turret_world_yaw() if actor != null else _from_yaw
	_to_turret_yaw = _from_turret_yaw

	started.emit(result)

	if _speed == Speed.INSTANT:
		# No follow: there is nothing to watch. Put the camera where the action ended instead — the
		# last event *shown*, not the last one that happened, or the camera would pan to a tile the
		# stream was filtered to hide.
		var last: ActionEvent = _events[_events.size() - 1]
		_seek_to_end()
		if camera != null and last.tile >= 0:
			camera.look_at_tile(last.tile)
		return

	if camera != null:
		camera.begin_follow()
	_advance()
	set_process(true)


## Jump to the end of whatever is playing. What the skip key does, and what instant mode is.
func skip() -> void:
	if not is_playing():
		return
	_seek_to_end()


func _process(delta: float) -> void:
	if not is_playing():
		set_process(false)
		return

	# Time left over when an event completes carries into the next one. Without that, a frame can
	# only ever finish one event, so 3x over a route of short legs quantizes to one leg per frame
	# and looks exactly like 1x.
	var t: float = delta * _multiplier
	var guard: int = 0
	while t > 0.0 and _result != null:
		var remaining: float = _duration - _elapsed
		if t < remaining:
			_elapsed += t
			_apply(_elapsed / maxf(_duration, 0.0001))
			return
		t -= remaining
		_apply(1.0)
		if not _advance():
			return
		# The event list is finite and every duration is floored above zero, so this cannot spin.
		# The guard is for the case where that stops being true, which is cheaper to notice here
		# than as a hung frame.
		guard += 1
		if guard > 4096:
			push_error("ActionPlayer: runaway replay, %d events in one frame" % guard)
			_seek_to_end()
			return


## Move to the next event and set up the interpolation for it. False once the list is exhausted.
func _advance() -> bool:
	_cursor += 1
	if _result == null or _cursor >= _events.size():
		_finish()
		return false

	var ev: ActionEvent = _events[_cursor]
	_elapsed = 0.0
	_from_pos = _to_pos
	_from_yaw = _to_yaw
	_from_turret_yaw = _to_turret_yaw

	event_reached.emit(ev)

	match ev.kind:
		ActionEvent.Kind.TURN:
			_to_yaw = TankView.facing_yaw(ev.facing)
			var steps: int = Grid.turn_steps(_facing, ev.facing)
			_facing = ev.facing
			_duration = maxf(float(steps) * 45.0 / _turn_rate, _min_event)
			# `_to_turret_yaw` is deliberately untouched. The turret's bearing is absolute, so a hull
			# that turns underneath it leaves it pointing exactly where it was — which is the whole
			# visible consequence of the split, and it costs nothing here to get right.
		ActionEvent.Kind.TURRET:
			_to_turret_yaw = TankView.facing_yaw(ev.facing)
			var swing: int = Grid.turn_steps(_turret, ev.facing)
			_turret = ev.facing
			_duration = maxf(float(swing) * 45.0 / _turret_rate, _min_event)
		ActionEvent.Kind.STEP:
			_to_pos = view.tile_center(ev.tile)
			_tile = ev.tile
			# Reversing gets its own speed, which is the only thing that has ever made a reverse leg
			# look different from a forward one. The facing does not change — that is the point.
			var rate: float = _reverse_speed if ev.is_reversed() else _drive_speed
			_duration = maxf(_from_pos.distance_to(_to_pos) / rate, _min_event)
		ActionEvent.Kind.SPOT:
			# A reveal is a placement, not a movement — docs/decisions/0034. The tank appears at the
			# tile that earned it (0025) rather than sliding in from wherever it was last drawn, which
			# is what it would do if this were interpolated: the pose before a reveal is, by
			# construction, one the viewer was not entitled to.
			var seen: TankView = _view_for(ev.other)
			if seen != null:
				seen.apply(ViewState.Kind.SEEN, ev.tile, ev.facing, ev.facing, 0.0)
			# The placement is instant; the beat after it is what lets a reveal register before the
			# next leg of the move drags the eye away.
			_duration = _spot_beat
		ActionEvent.Kind.LOST:
			# Contact broken. The ghost goes down here, at the tile the `LOST` carries, so the marker
			# lands mid-replay on the step that lost it rather than appearing at the end.
			var gone: TankView = _view_for(ev.other)
			if gone != null:
				gone.apply(ViewState.Kind.GHOST, ev.tile, ev.facing, ev.facing, 0.0)
			_duration = 0.0
		ActionEvent.Kind.HEARD:
			# A noise is a placement too — docs/decisions/0037. It goes down here so the ripple lands
			# on the beat the round was fired rather than after the stream finishes; an ambush whose
			# only evidence appears once the smoke has cleared is not an ambush.
			#
			# Note there is no `_view_for` here and there is nothing to look one up *with*: a `HEARD`
			# carries `other = -1` by construction, so this arm cannot pose a tank even by mistake.
			# `ev.tile` is the errored tile and the true one is not in the stream at all.
			if sounds != null:
				sounds.place(ev.tile, ev.sound_source(), float(ev.sound_error_dm()) * 0.1)
			_duration = 0.0
		ActionEvent.Kind.FIRE:
			_duration = _shot_flight
		ActionEvent.Kind.MISS, ActionEvent.Kind.HIT:
			_duration = _shot_impact
		ActionEvent.Kind.DESTROYED:
			_duration = _destroyed_beat
		_:
			# BEGIN, ACTIVATED and END are instants. They exist to bracket the stream and to carry
			# the poses, not to take time.
			_duration = 0.0

	# Instantaneous events still need their effect applied and their bar update pushed.
	if _duration <= 0.0:
		_apply(1.0)
		return _advance()
	return true


## Put the view where the current event says it is, `t` of the way through it.
func _apply(t: float) -> void:
	if _result == null or _cursor < 0 or _cursor >= _events.size():
		return
	var ev: ActionEvent = _events[_cursor]

	# Reveals, losses and noises are placements, applied once by `_advance` when the cursor reached
	# them. There is nothing to ease and nothing here that should overwrite them — and a `HEARD`'s
	# `unit` is the noisemaker, so without this it would fall through to the pose code below and drag
	# an invisible enemy's view onto the errored tile.
	if (
		ev.kind == ActionEvent.Kind.SPOT
		or ev.kind == ActionEvent.Kind.LOST
		or ev.kind == ActionEvent.Kind.HEARD
	):
		return

	# A woven stream carries **other units'** reactions — an ambusher's shot spliced between two of the
	# mover's steps (0030). The interpolation state below belongs to the unit that is acting, so
	# applying it to a watcher drew the watcher standing on the mover's tile. Reactions keep the pose
	# knowledge gave them; `refresh_all` on `finished` reconciles every unit the stream touched.
	if ev.unit != _result.unit:
		return

	var v: TankView = _view_for(ev.unit)
	if v == null:
		return

	var pos: Vector3 = _to_pos
	var yaw: float = _to_yaw
	var turret_yaw: float = _to_turret_yaw
	match ev.kind:
		ActionEvent.Kind.TURN:
			yaw = lerp_angle(_from_yaw, _to_yaw, t)
			pos = _from_pos
		ActionEvent.Kind.TURRET:
			turret_yaw = lerp_angle(_from_turret_yaw, _to_turret_yaw, t)
		ActionEvent.Kind.STEP:
			pos = _from_pos.lerp(_to_pos, t)
		_:
			pass

	v.set_pose(pos, yaw, turret_yaw)
	v.hull_facing = _facing
	v.turret_facing = _turret

	# The status bar drains straight out of the event stream. No simulation read anywhere in here —
	# see the class docstring. `v.mp_max` is a per-type constant the view was handed at construction,
	# not a live read of anything.
	if v.marker != null:
		v.marker.set_mp(ev.mp_left, v.mp_max)
		if ev.kind == ActionEvent.Kind.ACTIVATED:
			v.marker.set_acted(true)

	if camera != null:
		camera.follow_world(pos)


## Apply every remaining event at once, in order, and stop. Instant playback and skip are the same
## thing, and both are the same `_apply` the eased path uses.
func _seek_to_end() -> void:
	if _result == null:
		return
	while _result != null and _cursor < _events.size():
		if _cursor >= 0:
			_apply(1.0)
		if not _advance():
			return
	_finish()


## Stop, and hand the board back to whoever knows what is on it.
##
## This used to end by snapping every unit the stream named straight from `UnitState`, which was the
## reconcile that made a skipped replay unable to desynchronise view and simulation. It cannot do that
## any more and should not want to: reading `UnitState` here is exactly the leak 0034 closes, and the
## `finished` handler already runs `PlayerController.refresh_all()`, which poses every unit from
## `ViewState`. The reconcile still happens, one layer up, from the only source entitled to answer.
##
## What that buys is that this class now holds **no** simulation reference of any kind — the 0022
## guarantee, which was a convention about `setup`'s arguments, is now true of the whole file.
func _finish() -> void:
	var done: ActionResult = _result
	_result = null
	_events = []
	_cursor = -1
	set_process(false)

	if camera != null:
		camera.end_follow()

	if done != null:
		finished.emit(done)


func _view_for(unit_index: int) -> TankView:
	if unit_index < 0 or unit_index >= views.size():
		return null
	return views[unit_index]
