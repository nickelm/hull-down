class_name FireForecast
extends RefCounted

## The numbers a percentage-based game has to show before the player commits.
##
## The exact analogue of `plan_move` being pure, and for the same reason: this may be recomputed on
## every mouse move and it cannot advance a stream or touch a roll. `FireAction.preview` produces it;
## `FireAction.resolve` produces the shot. A test asserts the two agree field by field, because a
## preview that can silently disagree with what the shot actually charged is the worst bug this game
## can have — it does not look like a bug, it looks like bad luck.
##
## A typed object rather than a `Dictionary`, for the reason `PathResult` is one: a field-by-field
## comparison is only writable against named fields.

var status: int = ActionResult.Status.NO_UNIT
var exposure: int = Los.Exposure.MASKED
var range_m: float = 0.0
var hit_chance: float = 0.0
## The plate this shot would strike, as an `Armor.Facing`.
var facing_struck: int = -1
## What is left of that plate, after everything already shot off it.
var plate_mm: int = 0
## What this gun still goes through at this range.
var pen_mm: float = 0.0
var pen_chance: float = 0.0
## Rounds this action would fire. `gun.shots_per_action`, capped by what is in the racks.
var shots: int = 0


func ok() -> bool:
	return status == ActionResult.Status.OK


## The chance a single round both connects and gets through. What the player is actually deciding
## against — the two percentages separately are a physics lesson, their product is the question.
func kill_chance() -> float:
	return hit_chance * pen_chance


func describe() -> String:
	return "s%d e%d r%.0f h%.3f p%d/%d %.0fmm pc%.3f x%d" % [
		status, exposure, range_m, hit_chance, facing_struck, plate_mm, pen_mm, pen_chance, shots
	]
