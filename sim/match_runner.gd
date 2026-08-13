class_name MatchRunner
extends RefCounted

## A whole match, headless: policies in, outcome out — 2e-ii.
##
## The harness the batch runner and the AI tests drive. It owns the ground truth the policies must
## not see, which is why it lives beside `MatchState` rather than under `sim/ai/` — the scan there
## would rightly reject it. The game layer does not use it: an interactive match is driven by
## clicks and replays, and this is the version of that loop with both taken out.

var md: MapData
var cfg: Config
var state: MatchState
var resolver: ActionResolver
## One policy per side, indexed `side - 1`, exactly as `MatchState.knowledge` is.
var policies: Array[Policy] = []
## The mission being played, or null for a plain deployment. Owns the waves (2g): `step` asks it
## to deliver whatever is due before the side's policy runs.
var scenario: Scenario = null

## The turn a side first held any objective, per side (`side - 1`), or -1 — the "turns to
## objective" figure the 2e-ii batch report asks for.
var first_hold_turn: PackedInt32Array = PackedInt32Array()


static func create(
	map: MapData, config: Config, match_seed: int, side_policies: Array[Policy],
	per_side: int = -1
) -> MatchRunner:
	var r := MatchRunner.new()
	r.md = map
	r.cfg = config
	r.state = Deployment.deploy(map, config, per_side)
	r.resolver = ActionResolver.new(map, config, r.state, match_seed)
	r.resolver.refresh_knowledge()
	r.policies = side_policies
	r.first_hold_turn = PackedInt32Array()
	r.first_hold_turn.resize(r.state.side_count)
	r.first_hold_turn.fill(-1)
	return r


## As `create`, but over a state the caller has already built — a scenario's deployment, a test's
## hand-placed fixture. The runner adds nothing to it beyond the first knowledge sweep.
static func over(
	map: MapData, config: Config, match_state: MatchState, match_seed: int,
	side_policies: Array[Policy]
) -> MatchRunner:
	var r := MatchRunner.new()
	r.md = map
	r.cfg = config
	r.state = match_state
	r.resolver = ActionResolver.new(map, config, match_state, match_seed)
	r.resolver.refresh_knowledge()
	r.policies = side_policies
	r.first_hold_turn = PackedInt32Array()
	r.first_hold_turn.resize(match_state.side_count)
	r.first_hold_turn.fill(-1)
	return r


## As `over`, but the state comes from the scenario's own deployment and the runner keeps the
## scenario so its waves arrive — 2f and 2g.
static func for_scenario(
	map: MapData, config: Config, sc: Scenario, match_seed: int, side_policies: Array[Policy]
) -> MatchRunner:
	var r: MatchRunner = MatchRunner.over(
		map, config, sc.build_state(map, config), match_seed, side_policies
	)
	r.scenario = sc
	return r


## One side's whole turn: waves due this turn, then policy, then hand-over. Returns the committed
## results, for a caller that wants to watch.
func step() -> Array[ActionResult]:
	var side: int = state.active_side
	if scenario != null:
		var arrived: PackedInt32Array = scenario.spawn_due(md, cfg, state)
		if not arrived.is_empty():
			# An arrival can be seen — and can see. The sweep is the turn boundary's own tool.
			resolver.refresh_knowledge()
	var policy: Policy = policies[side - 1] if side - 1 < policies.size() else Policy.new()
	var results: Array[ActionResult] = AiRunner.run_turn(resolver, policy)
	resolver.end_turn()

	for s: int in state.side_count:
		if first_hold_turn[s] >= 0:
			continue
		for k: int in state.objective_holder.size():
			if state.objective_holder[k] == s + 1:
				first_hold_turn[s] = state.turn
				break
	return results


## Play to a decision or to the turn limit. Returns the summary the batch report aggregates.
## A limit of 0 defers to the scenario's clock, and past that to the config's `victory.turn_limit`
## — the mission owns its clock (0041).
func play(turn_limit: int = 0) -> Dictionary:
	var limit: int = turn_limit
	if limit <= 0 and scenario != null:
		limit = scenario.turn_limit
	if limit <= 0:
		limit = cfg.i("victory.turn_limit", 24)
	var winner: int = resolver.winner()
	while winner == 0 and state.turn <= limit:
		step()
		winner = resolver.winner()
	return summary(winner)


func losses(side: int) -> int:
	var lost: int = 0
	for k: int in state.side_roster(side):
		if not state.units[k].alive:
			lost += 1
	return lost


func summary(winner: int) -> Dictionary:
	var out: Dictionary = {
		"winner": winner,
		"turns": state.turn,
	}
	for s: int in range(1, state.side_count + 1):
		out["losses_%d" % s] = losses(s)
		out["first_hold_%d" % s] = first_hold_turn[s - 1]
		# The graded outcome — 2e-iii. Signed, so grade_1 is always -grade_2 in a two-sided match.
		out["grade_%d" % s] = Victory.grade(md, cfg, state, s)
		out["points_%d" % s] = Victory.points_held(md, cfg, state, s)
	return out
