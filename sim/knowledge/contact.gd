class_name Contact
extends RefCounted

## One thing a side knows about, flattened into something the view can draw without asking four
## questions to find out which of them it was allowed to ask.
##
## This owns nothing. `SideKnowledge` is the authority; this is a boundary value type, built a
## handful of times per repaint and never in a loop that matters — which is the only reason it is
## allowed to be an object at all in a codebase whose bulk data is all `Packed*Array`.
##
## What it buys is that the caller stops having to know the rule. A live contact's position is the
## unit's own tile and a ghost's is a frozen memory (0024); reading that correctly means branching on
## the state at every call site, and a call site that forgets draws a ghost that follows its unit
## around. Here it is one branch, in one place.

var unit: int = -1
var state: int = SideKnowledge.State.UNKNOWN
## Where to draw it. The unit's actual tile while it is `SEEN`, the remembered one while it is a ghost.
var tile: int = -1
var facing: int = -1
## Where the gun points, as an absolute world bearing (0027). Visible information while the contact is
## `SEEN` — a turret is the most legible thing on a tank at four hundred meters, and which way it is
## laid is half of what you are reading a sighting for. A ghost does not remember it separately: memory
## keeps one heading, and it is the hull's, so this falls back to `facing` rather than inventing one.
var turret: int = -1
## Turns before the ghost goes cold. Zero for a live contact, which is not "about to expire" — it is
## "not ageing".
var ghost_turns_left: int = 0
## What kind of thing it is, for the roster line. Empty when the side has never seen it closely
## enough to say, which today means never at all.
var unit_type: StringName = &""


func is_live() -> bool:
	return state == SideKnowledge.State.SEEN


func is_ghost() -> bool:
	return state == SideKnowledge.State.GHOST


## How far through its life a ghost is: 0.0 when it was lost this turn, approaching 1.0 as it goes
## cold. `full_life` is `spotting.ghost_turns`, passed in because it is a tunable and `sim/` classes
## do not reach for a `Config` they were not handed. A live contact answers 0.0 — it is not ageing.
func staleness(full_life: int) -> float:
	if not is_ghost() or full_life <= 0:
		return 0.0
	return clampf(1.0 - float(ghost_turns_left) / float(full_life), 0.0, 1.0)
