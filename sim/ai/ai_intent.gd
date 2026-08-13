class_name AiIntent
extends RefCounted

## The side-level intent layer — 2e-ii, docs/decisions/0039.
##
## Units are assigned to objectives in groups, so the side advances along axes rather than each
## tank picking its own nearest flag and the force dissolving into three solo sightseers. The
## assignment is the only thing decided here; what a unit does about its objective is the utility
## policy's business, which keeps "where is this side going" and "what is this tank doing" two
## separately readable answers.
##
## Deterministic and draw-free. Units are walked in deployment order and each takes the nearest
## objective that still has an open slot, slots being an even split of the force. Assignments are
## **sticky**: once a unit has an axis it keeps it until it dies, because a fresh greedy pass every
## turn re-shuffles the groups as distances change, and a force whose axes flap re-crosses its own
## line of advance forever — coordinated on every turn, scattered across any two.
##
## Lives in the scanned half of `sim/ai/` — everything here comes through `AiView`, and holding
## the assignment in an object the policy owns (rather than on any match state) is what keeps a
## side's intentions private to that side without a rule saying so.

## unit index -> index into `view.objectives()`. Never iterated — read per unit, so `sim/`'s
## no-dictionary-iteration rule is kept by construction rather than by sorting.
var assignment: Dictionary = {}


## Bring the assignment up to date against the living roster. Call once per turn.
func refresh(view: AiView) -> void:
	var objs: PackedInt32Array = view.objectives()
	if objs.is_empty():
		assignment.clear()
		return

	var units: PackedInt32Array = view.my_units()
	var counts: PackedInt32Array = PackedInt32Array()
	counts.resize(objs.size())

	# Keep every valid existing assignment, and let the dead drop out by never carrying them over.
	var fresh: Dictionary = {}
	for k: int in units.size():
		var i: int = units[k]
		if assignment.has(i):
			var oi: int = int(assignment[i])
			if oi >= 0 and oi < objs.size():
				fresh[i] = oi
				counts[oi] += 1

	# An even split, rounded up — the cap that makes this a grouping rather than a pile-on.
	var cap: int = int(ceil(float(units.size()) / float(objs.size())))

	for k2: int in units.size():
		var i2: int = units[k2]
		if fresh.has(i2):
			continue
		var u: UnitState = view.my_unit(i2)
		if u == null:
			continue
		var best: int = -1
		var best_d: float = INF
		for o: int in objs.size():
			if counts[o] >= cap:
				continue
			var d: float = view.dist_m(u.tile, objs[o])
			if d < best_d:
				best_d = d
				best = o
		if best < 0:
			best = 0
		fresh[i2] = best
		counts[best] += 1

	assignment = fresh


## The tile this unit's axis leads to, or -1 when the map has no objectives.
func objective_tile(view: AiView, unit_index: int) -> int:
	var objs: PackedInt32Array = view.objectives()
	if objs.is_empty():
		return -1
	var oi: int = int(assignment.get(unit_index, 0))
	if oi < 0 or oi >= objs.size():
		oi = 0
	return objs[oi]
