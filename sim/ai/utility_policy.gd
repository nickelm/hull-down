class_name UtilityPolicy
extends Policy

## The first real AI — 2e-ii, docs/decisions/0039.
##
## One unit at a time: take the best shot on offer if it clears a threshold, otherwise score a
## sampled set of reachable tiles against weighted terms and drive to the best one, otherwise sit,
## and if sitting, watch the most suspicious bearing. Every term's weight is in `data/ai.json`;
## nothing here knows a number.
##
## Scores are computed from the `AiView` only. Danger is priced against *known* enemies — live
## contacts, ghosts, sound ripples — because that is all the side has, and it is the honest reason
## an AI can be ambushed: a tile is only "safe" against the enemies it has heard about.
##
## The AI RNG stream is drawn for exactly one thing: breaking ties between candidates whose scores
## are within epsilon. Everything else is deterministic, so two runs of a match from one seed play
## the same war.

var _rng: RandomNumberGenerator
var _intent: AiIntent = AiIntent.new()
## The turn the per-turn state was last rebuilt for. `MatchState.turn` only advances when the side
## count wraps, so (turn, side-asked-about) would be the full key; the runner only asks about one
## side per turn, which makes the turn alone sufficient.
var _turn_seen: int = -1


## `_init` rather than a `create` factory, and not by taste: a factory writes the new instance's
## privates from outside (`p._rng = ...`), which is exactly the reach the boundary scan bans, and
## the policy should not be the one file with a licence to look like a violation.
func _init(master_seed: int = 0) -> void:
	_rng = Rng.stream(master_seed, Rng.Stream.AI)


func decide(view: AiView, unit_index: int) -> AiOrder:
	var u: UnitState = view.my_unit(unit_index)
	if u == null:
		return AiOrder.pass_order(unit_index)

	if view.turn() != _turn_seen:
		_turn_seen = view.turn()
		_intent.refresh(view)

	var cfg: Config = view.config()
	var contacts: Array[Contact] = view.contacts()
	var live: Array[Contact] = []
	for c: Contact in contacts:
		if c.is_live():
			live.append(c)

	# --- shoot, if a shot worth the action exists ---------------------------------------------------
	var target: int = _best_shot(view, unit_index, live, cfg)
	if target >= 0:
		return AiOrder.fire(unit_index, target)

	# --- otherwise drive somewhere better -----------------------------------------------------------
	if not u.immobilised:
		var goal: int = _best_move(view, u, unit_index, contacts, live, cfg)
		if goal >= 0 and goal != u.tile:
			return AiOrder.move(unit_index, goal)

	# --- otherwise hold ground and cover the most suspicious bearing --------------------------------
	var dir: int = _watch_bearing(view, u, contacts, cfg)
	if dir >= 0 and view.overwatch_legality(unit_index, dir) == ActionResult.Status.OK:
		return AiOrder.overwatch(unit_index, dir)

	return AiOrder.pass_order(unit_index)


## The most valuable target this unit can engage right now, or -1 when nothing clears the
## threshold. Expected value per round: kills are worth `kill`, and a non-penetrating hit is still
## worth `shred` — 0004's no-null-results rule priced into the AI's appetite.
func _best_shot(view: AiView, unit_index: int, live: Array[Contact], cfg: Config) -> int:
	var w_kill: float = cfg.f("ai.weights.kill", 60.0)
	var w_shred: float = cfg.f("ai.weights.shred", 10.0)
	var threshold: float = cfg.f("ai.weights.fire_threshold", 6.0)

	var best: int = -1
	var best_score: float = threshold
	for c: Contact in live:
		var pf: FireForecast = view.preview_fire(unit_index, c.unit)
		if not pf.ok():
			continue
		var score: float = pf.kill_chance() * w_kill \
			+ pf.hit_chance * (1.0 - pf.pen_chance) * w_shred
		if score > best_score:
			best_score = score
			best = c.unit
	return best


## The best tile to end this action on, scored against the weighted terms, or -1 for "stay put".
func _best_move(
	view: AiView, u: UnitState, unit_index: int,
	contacts: Array[Contact], live: Array[Contact], cfg: Config
) -> int:
	var reach: PackedInt32Array = view.reachable(unit_index)
	if reach.is_empty():
		return -1

	# Nearest first, so "the first `contacts_considered`" means the guns that dominate the danger.
	# The index is the tie-break: two enemies at one distance must sort the same way every run.
	live.sort_custom(func(a: Contact, b: Contact) -> bool:
		var da: float = view.dist_m(u.tile, a.tile)
		var db: float = view.dist_m(u.tile, b.tile)
		return da < db or (da == db and a.unit < b.unit))

	var objective: int = _intent.objective_tile(view, unit_index)
	var candidates: PackedInt32Array = _sample_candidates(view, u, reach, objective, cfg)

	var epsilon: float = cfg.f("ai.tie_break_epsilon", 0.25)
	var best_score: float = -INF
	var tied: PackedInt32Array = PackedInt32Array()

	for k: int in candidates.size():
		var cand: int = candidates[k]
		var s: float = _score_tile(view, u, cand, reach[cand], objective, contacts, live, cfg)
		if cand == u.tile:
			s += cfg.f("ai.weights.stationary_bonus", 1.0)
		if s > best_score + epsilon:
			best_score = s
			tied = PackedInt32Array([cand])
		elif s > best_score - epsilon:
			tied.append(cand)
			if s > best_score:
				best_score = s

	if tied.is_empty():
		return -1
	# The AI stream's single job. One draw, and only when there genuinely is a tie to break.
	var pick: int = tied[0] if tied.size() == 1 else tied[_rng.randi_range(0, tied.size() - 1)]
	return pick


## The reachable set, sampled down to the hard cap in tile order — deterministic, no draw.
##
## Three tiles are always in: where the unit stands (staying is a real candidate), the reachable
## tile nearest the assigned objective (the sample must not stride over the point of the move), and
## everything the stride selects.
func _sample_candidates(
	view: AiView, u: UnitState, reach: PackedInt32Array, objective: int, cfg: Config
) -> PackedInt32Array:
	var cap: int = maxi(cfg.i("ai.candidates.max_per_unit", 24), 2)

	var all: PackedInt32Array = PackedInt32Array()
	var toward: int = -1
	var toward_d: float = INF
	for t: int in reach.size():
		if reach[t] < 0:
			continue
		all.append(t)
		if objective >= 0:
			var d: float = view.dist_m(t, objective)
			if d < toward_d:
				toward_d = d
				toward = t

	var out: PackedInt32Array = PackedInt32Array()
	if all.size() <= cap:
		out = all
	else:
		var stride: int = all.size() / cap
		for k: int in cap:
			out.append(all[k * stride])

	if not out.has(u.tile):
		out.append(u.tile)
	if toward >= 0 and not out.has(toward):
		out.append(toward)
	return out


## One candidate tile's utility. Every term's weight is data; the shape of each term is the rule.
func _score_tile(
	view: AiView, u: UnitState, cand: int, cost: int, objective: int,
	contacts: Array[Contact], live: Array[Contact], cfg: Config
) -> float:
	var tile_m: float = cfg.f("world.tile_m", 10.0)
	var s: float = 0.0

	# Progress toward the assigned objective, in tiles closed.
	if objective >= 0:
		s += cfg.f("ai.weights.progress_per_tile", 1.0) \
			* (view.dist_m(u.tile, objective) - view.dist_m(cand, objective)) / tile_m

	# Ground worth standing on: concealment is the tile's own, cover is priced per known enemy.
	s += cfg.f("ai.weights.concealment", 4.0) \
		* (1.0 - view.concealment_at(cand, u.movement_class))

	var considered: int = cfg.i("ai.candidates.contacts_considered", 4)
	var w_hull_down: float = cfg.f("ai.weights.hull_down", 2.5)
	var w_masked: float = cfg.f("ai.weights.masked", 1.5)
	var w_arc: float = cfg.f("ai.weights.arc_threat", -6.0)
	var arc_steps: int = cfg.i("combat.overwatch_arc_steps", 1)
	var w_shot: float = cfg.f("ai.weights.shot_value", 8.0)
	var max_shots: int = cfg.i("ai.candidates.max_shots_counted", 2)
	var min_hit: float = cfg.f("ai.candidates.min_hit_chance_counted", 0.25)
	var base_hit: float = cfg.f("combat.base_hit_chance", 0.95)
	var falloff: float = cfg.f("combat.range_falloff_per_100m", 0.045)

	var shots_counted: int = 0
	for k: int in mini(live.size(), considered):
		var c: Contact = live[k]
		# How the enemy sees this tile. MASKED is the safest, hull down the next best; both are
		# cover *against that enemy*, so each known gun prices the tile separately.
		var seen_as: int = view.exposure_between_tiles(c.tile, cand)
		if seen_as == Los.Exposure.MASKED:
			s += w_masked
		elif seen_as == Los.Exposure.HULL_DOWN:
			s += w_hull_down

		if seen_as != Los.Exposure.MASKED:
			# The overwatch fact a side can honestly know: where the gun points. The watch order
			# itself is hidden (0036), so a laid turret is treated as a covered lane whether or not
			# an order stands behind it.
			var from_enemy: int = view.bearing_between(c.tile, cand)
			if from_enemy >= 0 and Grid.turn_steps(c.turret, from_enemy) <= arc_steps:
				s += w_arc

			# And the value of shooting back: a rough per-round estimate, deliberately cheaper
			# than a full preview — this runs per candidate, the preview runs once per order.
			if shots_counted < max_shots:
				var est: float = base_hit - falloff * view.dist_m(cand, c.tile) / 100.0
				if est >= min_hit:
					s += w_shot
					shots_counted += 1

	# Suspicion is repellent (or attractive — the sign is data): ghosts and ripples mark ground
	# somebody may be watching from.
	var radius: float = cfg.f("ai.candidates.caution_radius_m", 250.0)
	var w_ghost: float = cfg.f("ai.weights.ghost_caution", -1.5)
	for c2: Contact in contacts:
		if c2.is_live():
			continue
		var d2: float = view.dist_m(cand, c2.tile)
		if d2 < radius:
			s += w_ghost * (1.0 - d2 / radius)

	var w_sound: float = cfg.f("ai.weights.sound_caution", -2.0)
	for sc: SoundContact in view.sound_contacts():
		var d3: float = view.dist_m(cand, sc.tile)
		if d3 < radius:
			s += w_sound * (1.0 - d3 / radius)

	# Spending the whole allowance to gain nothing is worse than spending none of it.
	s += cfg.f("ai.weights.mp_thrift", -1.0) * float(cost) / float(maxi(u.mp_max, 1))

	return s


## The bearing worth covering from where the unit stands: the nearest thing the side knows or
## suspects, falling back to the objective. Clamped into the turret's arc — a promise the gun
## cannot keep is not worth making.
func _watch_bearing(view: AiView, u: UnitState, contacts: Array[Contact], cfg: Config) -> int:
	var focus: int = -1
	var best_d: float = INF
	for c: Contact in contacts:
		var d: float = view.dist_m(u.tile, c.tile)
		if d < best_d:
			best_d = d
			focus = c.tile
	for sc: SoundContact in view.sound_contacts():
		var d2: float = view.dist_m(u.tile, sc.tile)
		if d2 < best_d:
			best_d = d2
			focus = sc.tile

	if focus < 0:
		var objs: PackedInt32Array = view.objectives()
		if objs.is_empty():
			return -1
		focus = objs[0]

	var dir: int = view.bearing_between(u.tile, focus)
	if dir < 0:
		return -1
	return UnitState.clamp_turret(u.facing, dir, cfg.i("combat.turret_arc_steps", 3))
