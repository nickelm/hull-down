extends SceneTree

## AI-versus-AI batch runner — 2e-ii.
##
##   godot --headless --path . --script res://tools/ai_batch.gd -- --count 50
##
## Runs N headless matches of `UtilityPolicy` against itself and reports win rate, turns to first
## objective, losses, and turn timing — the numbers that say whether the advance is an advance.
##
## Matches are spread over a handful of maps rather than one per match: quarter-scale generation
## costs seconds, not minutes, and what the batch is measuring is the policy, not the generator.
## Full-scale maps are a flag away. Each match gets its own combat seed derived from the map seed
## and its index, so fifty matches on five maps are fifty different wars.
##
## Serial on purpose, unlike gen_batch: a match is seconds, the report wants per-turn timings that
## subprocess stdout would garble, and the policy timing numbers only mean something measured one
## match at a time.


func _initialize() -> void:
	var cli := Cli.from_os()
	var count: int = cli.int_opt("count", 50)
	var map_count: int = cli.int_opt("maps", 5)
	var first_seed: int = cli.int_opt("first-seed", 1000)
	var turn_limit: int = cli.int_opt("turn-limit", 24)
	var per_side: int = cli.int_opt("per-side", 0)
	var full: bool = cli.flag("full")

	var cfg: Config = Config.load_default()

	print("Hull Down — AI batch: %d matches over %d %s maps, turn limit %d" % [
		count, map_count, "full-scale" if full else "quarter-scale", turn_limit
	])
	print("")

	var maps: Dictionary = {}
	var wins := PackedInt32Array([0, 0, 0])   # draws, side 1, side 2
	var total_turns: int = 0
	var total_losses := PackedInt32Array([0, 0])
	var hold_turns := PackedInt32Array()
	var slowest_turn_ms: float = 0.0
	var total_turn_ms: float = 0.0
	var turns_timed: int = 0
	var t_batch: int = Time.get_ticks_usec()

	for i: int in count:
		var map_seed: int = first_seed + (i % map_count)
		if not maps.has(map_seed):
			var t_gen: int = Time.get_ticks_usec()
			maps[map_seed] = (
				MapGenerator.generate(cfg, map_seed) if full
				else MapGenerator.generate_small(cfg, map_seed)
			)
			print("  map seed %d generated (%.1f s)" % [
				map_seed, float(Time.get_ticks_usec() - t_gen) / 1e6
			])
		var md: MapData = maps[map_seed]

		var match_seed: int = Rng.mix(map_seed, i)
		var policies: Array[Policy] = [
			UtilityPolicy.new(match_seed),
			UtilityPolicy.new(Rng.mix(match_seed, 2)),
		]
		var runner: MatchRunner = MatchRunner.create(
			md, cfg, match_seed, policies, per_side if per_side > 0 else -1
		)

		# `play`, unrolled, so each side-turn can be timed against the acceptance budget.
		var winner: int = runner.resolver.winner()
		while winner == 0 and runner.state.turn <= turn_limit:
			var t_turn: int = Time.get_ticks_usec()
			runner.step()
			var ms: float = float(Time.get_ticks_usec() - t_turn) / 1000.0
			slowest_turn_ms = maxf(slowest_turn_ms, ms)
			total_turn_ms += ms
			turns_timed += 1
			winner = runner.resolver.winner()

		var s: Dictionary = runner.summary(winner)
		wins[clampi(winner, 0, 2)] += 1
		total_turns += int(s["turns"])
		total_losses[0] += int(s["losses_1"])
		total_losses[1] += int(s["losses_2"])
		for side: int in [1, 2]:
			var h: int = int(s["first_hold_%d" % side])
			if h >= 0:
				hold_turns.append(h)

		print("  match %2d  seed %d  winner %d  turns %2d  losses %d/%d  first hold %s/%s" % [
			i + 1, map_seed, winner, int(s["turns"]),
			int(s["losses_1"]), int(s["losses_2"]),
			str(s["first_hold_1"]), str(s["first_hold_2"]),
		])

	print("")
	var n: float = float(maxi(count, 1))
	print("=== %d matches in %.1f s ===" % [count, float(Time.get_ticks_usec() - t_batch) / 1e6])
	print("  side 1 wins %d (%.0f%%)   side 2 wins %d (%.0f%%)   undecided %d (%.0f%%)" % [
		wins[1], 100.0 * float(wins[1]) / n,
		wins[2], 100.0 * float(wins[2]) / n,
		wins[0], 100.0 * float(wins[0]) / n,
	])
	print("  mean match length %.1f turns" % (float(total_turns) / n))
	print("  mean losses per match: side 1 %.1f, side 2 %.1f" % [
		float(total_losses[0]) / n, float(total_losses[1]) / n
	])
	if not hold_turns.is_empty():
		var sum: int = 0
		for h2: int in hold_turns:
			sum += h2
		print("  mean turns to first objective hold %.1f" % (float(sum) / float(hold_turns.size())))
	if turns_timed > 0:
		print("  side-turn time: mean %.0f ms, slowest %.0f ms" % [
			total_turn_ms / float(turns_timed), slowest_turn_ms
		])

	quit(0)
