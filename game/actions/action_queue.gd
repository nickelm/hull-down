class_name ActionQueue
extends Node

## Plays a series of resolved actions one after another.
##
## `ActionPlayer` replays exactly one stream and knows nothing about what comes next; that is correct
## and should stay that way, because the guarantee it carries — that it holds no simulation reference —
## is easiest to keep in an object with one job. This owns "and then the next one", and it is
## deliberately thin.
##
## Nothing in hot-seat needs it: a human's orders arrive one click at a time and the click handler can
## simply wait for each. It exists because **an AI turn is a list** (docs/hull-down-v2.md 2e-i), and
## building it now means the knowledge filter is already in the path the first time a side that is not
## the player's takes one. Retrofitting a queue underneath a working replay is how the filter gets
## forgotten on one of the two routes into it.
##
## **The stream is filtered by the caller, at resolve time, and travels with the result.** That is not
## a convenience — it is the only correct moment. A side resolves its whole turn before a frame of it
## is drawn, so `ViewState.all` read here, at playback, would already include everything the *later*
## actions revealed, and the first unit's move would replay as though the enemy it uncovered had been
## in plain view the whole time. The mask belongs to the moment the action happened; queueing it
## alongside the events is how it stays there.

signal drained

var player: ActionPlayer

var _results: Array[ActionResult] = []
## Parallel to `_results`. Each entry is the `Array[ActionEvent]` that result was filtered down to —
## untyped at this level because GDScript has no `Array[Array[ActionEvent]]`.
var _streams: Array = []
## Whether the action currently playing came off this queue. `ActionPlayer.finished` fires for
## everything, including a one-off the controller played directly, and an empty queue must not answer
## someone else's signal by announcing that it has drained.
var _driving: bool = false


func setup(action_player: ActionPlayer) -> void:
	player = action_player
	player.finished.connect(_on_finished)


func is_busy() -> bool:
	return _driving or not _results.is_empty()


func pending() -> int:
	return _results.size()


## Queue a resolved action together with the events the viewing side may watch of it. Starts playing
## immediately if nothing else is.
func submit(result: ActionResult, events: Array[ActionEvent]) -> void:
	if result == null:
		return
	_results.append(result)
	_streams.append(events)
	if not player.is_playing():
		_next()


## Cut to the end of everything queued. What a skip key means when more than one action is left: the
## player asked to stop watching, not to stop after this one.
func skip_all() -> void:
	# `skip` drives `finished`, which advances the queue, so this terminates as the list empties. The
	# bound is the queue's own length rather than a timer.
	var guard: int = _results.size() + 2
	while guard > 0 and (player.is_playing() or not _results.is_empty()):
		guard -= 1
		if player.is_playing():
			player.skip()
		else:
			_next()


func clear() -> void:
	_results.clear()
	_streams.clear()


func _next() -> void:
	if _results.is_empty():
		if _driving:
			_driving = false
			drained.emit()
		return
	_driving = true
	var result: ActionResult = _results.pop_front()
	var events: Array[ActionEvent] = _streams.pop_front()
	player.play(result, events)


func _on_finished(_result: ActionResult) -> void:
	if not _driving:
		return
	# Deferred, so a queue advanced from inside a `finished` handler cannot recurse through `play` on
	# an object still unwinding its own signal emission.
	call_deferred("_next")
