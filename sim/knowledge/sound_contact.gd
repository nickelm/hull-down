class_name SoundContact
extends RefCounted

## One noise a side has heard, flattened for drawing — the sibling of `Contact`.
##
## Like `Contact` this owns nothing: `SideSound` is the authority and this is a boundary value type,
## built a handful of times per repaint and never in a loop that matters.
##
## **What is worth reading here is what is absent.** `Contact` carries a `unit` and a `unit_type`,
## because a sighting is about a particular tank and the roster line says which. This carries neither,
## and no amount of asking will produce one — 0033's "identity: not known" row. A sound contact
## answers *something is roughly there*, and the two fields that would let a caller quietly upgrade
## that to *that tank is there* do not exist to be read.
##
## `tile` is the errored position and there is no field holding the true one, for the same reason.

var tile: int = -1
var source: int = SideSound.Source.FIRE
## The radius the true position could be anywhere inside, in meters. The marker is drawn at this size,
## so the uncertainty is not a number the player has to be told — it is how big the thing on screen is.
var error_m: float = 0.0
## Turns before it goes quiet. Never zero for a contact that exists: unlike a ghost's counter, which
## reads zero for a live sighting that is not ageing, everything in this container is ageing.
var turns_left: int = 0


func is_gunfire() -> bool:
	return source == SideSound.Source.FIRE


func is_engine() -> bool:
	return source == SideSound.Source.MOVE
