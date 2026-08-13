class_name Victory
extends RefCounted

## Hold objectives to win — `docs/design/rules.md` §6.
##
## The objectives have been placed, connectivity-checked and unread since map generation landed. This
## is the smallest thing that consumes them, and it deliberately stays small: the interesting decisions
## in this game are about ground and armor, and a capture rule with its own subsystem would compete
## with them rather than give them a point.
##
## A side holds an objective when it has a living unit within `victory.capture_radius_tiles` of it and
## the other side does not. Contested is nobody's — walking a scout onto a tile the enemy is sitting
## on does not take it off them, which is what stops the last turn of a match being a race of
## suicidal dashes.


## Which side holds one objective right now, or 0 for nobody.
##
## Uses the map's own coordinates rather than `Grid`'s, because the tests run quarter-scale maps and
## anything that decodes a tile with the shipping size answers about a different board.
static func holder_of(md: MapData, cfg: Config, state: MatchState, objective: int) -> int:
	if objective < 0 or objective >= md.n:
		return 0
	var radius: int = maxi(cfg.i("victory.capture_radius_tiles", 1), 0)
	var ox: int = md.tx(objective)
	var oy: int = md.ty(objective)

	var claimant: int = 0
	for k: int in state.units.size():
		var u: UnitState = state.units[k]
		if not u.alive or not u.on_board:
			continue
		if maxi(absi(md.tx(u.tile) - ox), absi(md.ty(u.tile) - oy)) > radius:
			continue
		if claimant == 0:
			claimant = u.side
		elif claimant != u.side:
			return 0   # contested
	return claimant


## Who holds each objective, parallel to `md.objectives`.
static func held_by(md: MapData, cfg: Config, state: MatchState) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(md.objectives.size())
	for k: int in md.objectives.size():
		out[k] = holder_of(md, cfg, state, md.objectives[k])
	return out


## Update how long each objective has been held, and by whom. Called once per hand-over.
##
## A count rather than a timestamp, because `hold_turns` is "how many turns in a row" and a side that
## loses an objective and retakes it has not been holding it throughout. The counter is per objective
## rather than per side for the same reason.
static func tick(md: MapData, cfg: Config, state: MatchState) -> void:
	var now: PackedInt32Array = held_by(md, cfg, state)
	if state.objective_holder.size() != now.size():
		state.objective_holder.resize(now.size())
		state.objective_held_turns.resize(now.size())

	for k: int in now.size():
		if now[k] != 0 and now[k] == state.objective_holder[k]:
			state.objective_held_turns[k] += 1
		else:
			state.objective_holder[k] = now[k]
			state.objective_held_turns[k] = 1 if now[k] != 0 else 0


## The five-step outcome ladder — 2e-iii. Signed so that one side's grade is the negation of the
## other's, which is not a convenience but the definition: a marginal victory over somebody is that
## somebody's marginal defeat, and two independent computations could disagree about it.
enum Grade {
	DECISIVE_DEFEAT = -2,
	MARGINAL_DEFEAT = -1,
	DRAW = 0,
	MARGINAL_VICTORY = 1,
	DECISIVE_VICTORY = 2,
}


## Victory points a side holds right now: the sum of the values of the objectives it holds.
## Current possession, not `hold_turns` — grading asks where the line stands when time runs out,
## and the hold requirement belongs to the outright win, which asks a different question.
static func points_held(md: MapData, cfg: Config, state: MatchState, side: int) -> int:
	var held: PackedInt32Array = held_by(md, cfg, state)
	var total: int = 0
	for k: int in held.size():
		if held[k] == side:
			total += md.objective_worth(k)
	return total


## Enemy units this side's war has destroyed. In a two-sided match this is simply the other side's
## losses; summed over "everyone else" so a multi-sided match still grades.
static func kills_by(state: MatchState, side: int) -> int:
	var n: int = 0
	for k: int in state.units.size():
		if state.units[k].side != side and not state.units[k].alive:
			n += 1
	return n


## One side's standing, in points: ground held plus damage done. What `grade` compares.
static func score(md: MapData, cfg: Config, state: MatchState, side: int) -> float:
	return float(points_held(md, cfg, state, side)) * cfg.f("victory.grade_vp_weight", 2.0) \
		+ float(kills_by(state, side)) * cfg.f("victory.grade_kill_weight", 1.0)


## The graded outcome for one side — 2e-iii. Meaningful whenever the match is over, whether by
## outright win, annihilation, or the turn limit expiring.
##
## The margin of the two scores decides the step; an outright win is clamped to at least marginal
## victory, because a side that met the victory condition has won whatever the arithmetic of
## corpses says — and symmetrically for the loser.
static func grade(md: MapData, cfg: Config, state: MatchState, side: int) -> int:
	var margin: float = score(md, cfg, state, side)
	for other: int in range(1, state.side_count + 1):
		if other != side:
			margin -= score(md, cfg, state, other)

	var decisive: float = cfg.f("victory.grade_decisive", 8.0)
	var marginal: float = cfg.f("victory.grade_marginal", 2.0)
	var g: int = Grade.DRAW
	if margin >= decisive:
		g = Grade.DECISIVE_VICTORY
	elif margin >= marginal:
		g = Grade.MARGINAL_VICTORY
	elif margin <= -decisive:
		g = Grade.DECISIVE_DEFEAT
	elif margin <= -marginal:
		g = Grade.MARGINAL_DEFEAT

	var winner: int = evaluate(md, cfg, state)
	if winner == side:
		g = maxi(g, Grade.MARGINAL_VICTORY)
	elif winner != 0:
		g = mini(g, Grade.MARGINAL_DEFEAT)
	return g


## Whether the match has ended: somebody won outright, or the clock ran out. `turn_limit` above
## zero overrides the config's — a scenario's limit is the scenario's to set (2f).
static func over(md: MapData, cfg: Config, state: MatchState, turn_limit: int = 0) -> bool:
	if evaluate(md, cfg, state) != 0:
		return true
	var limit: int = turn_limit if turn_limit > 0 else cfg.i("victory.turn_limit", 24)
	return state.turn > limit


## The winning side, or 0 if the match is still on.
##
## Two ways to win, and the second is what stops a match stalling: hold enough objectives for long
## enough, or be the only side with anything left that can fight.
static func evaluate(md: MapData, cfg: Config, state: MatchState) -> int:
	var alive_sides := PackedInt32Array()
	for side: int in range(1, state.side_count + 1):
		# Counting reserves still off the board (2g): a side whose next wave has not arrived is
		# not annihilated, however empty the board looks.
		if state.side_alive_count(side) > 0:
			alive_sides.append(side)
	if alive_sides.size() == 1:
		return alive_sides[0]
	if alive_sides.is_empty():
		return 0

	var need: int = maxi(cfg.i("victory.objectives_to_win", 2), 1)
	var hold: int = maxi(cfg.i("victory.hold_turns", 2), 1)

	var tally: Dictionary = {}
	for k: int in state.objective_holder.size():
		var side: int = state.objective_holder[k]
		if side == 0 or state.objective_held_turns[k] < hold:
			continue
		tally[side] = int(tally.get(side, 0)) + 1

	# Ascending side order, never `Dictionary` key order — CLAUDE.md, and it is what stops the winner
	# of a simultaneous double capture depending on insertion order.
	for side2: int in range(1, state.side_count + 1):
		if int(tally.get(side2, 0)) >= need:
			return side2
	return 0
