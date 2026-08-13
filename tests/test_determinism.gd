extends TestCase

## The two contracts in CLAUDE.md that nothing enforced.
##
## Both are stated as absolutes — "no `randi()` / `randf()` / `randomize()` anywhere in `sim/`. Not
## once, not 'just for this'", and "`game/` imports `sim/`; `sim/` never imports `game/`" — and both
## are the kind of rule that holds until the afternoon someone is in a hurry. A source scan is a
## blunt instrument, but it is the only one that covers files that do not exist yet, which is most
## of iteration 2.
##
## This is deliberately a scan and not a behavioral test. Determinism is already tested where it
## can be observed (test_rng, test_pinned_seeds, and the fingerprint tests in test_actions); what is
## missing is the guarantee that a *new* file cannot quietly opt out.

const SIM_DIR := "res://sim"
const GAME_DIR := "res://game"

## A **stored** `UnitState` in `game/` — docs/decisions/0034. Anchored at column zero, which in
## GDScript is exactly the difference between a member and a local: a member is a live handle on ground
## truth that outlives the call, and a local is the boundary doing its job.
##
## `PlayerController` takes `UnitState` locals constantly and must be allowed to — it owns the
## `MatchState` and is the one place entitled to turn knowledge into a pose. What broke fog of war was
## `TankView` *keeping* one, so that is what is banned.
const STORED_UNIT_STATE := "^var\\s+\\w+\\s*:\\s*UnitState\\b"

## The pattern that reference produced at the call sites: `view.state.tile`, `actor.state.turret`.
## There is nothing in `game/` left to read it off, and this is what keeps it that way.
const REACHED_THROUGH_STATE := "\\.state\\.\\w+"

## Unseeded global randomness. Matched only where the name is not preceded by a dot or a word
## character, so `rng.randf_range(...)` on a seeded `RandomNumberGenerator` — which is how every
## legitimate draw in the codebase is written — does not match.
const FORBIDDEN_RNG := "(?<![\\w.])(randi|randf|randi_range|randf_range|randomize)\\s*\\("


func _gd_files(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full: String = dir_path + "/" + entry
		if dir.current_is_dir():
			_gd_files(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
	dir.list_dir_end()


## Drop line comments before scanning, so the ban can be written down in a docstring without the
## docstring tripping it — `sim/rng.gd` does exactly that.
##
## Truncating at the first `#` also truncates at one inside a string literal, which can only ever
## hide a violation rather than invent one. Color strings are the only `#` literals in the project
## and they live in `data/`, not here.
func _strip_comments(source: String) -> String:
	var out := PackedStringArray()
	for line: String in source.split("\n"):
		var hash_at: int = line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


func test_the_sim_layer_is_present_to_be_scanned() -> void:
	var files := PackedStringArray()
	_gd_files(SIM_DIR, files)
	# A scan that silently found nothing would pass every test below for the wrong reason.
	assert_gt(float(files.size()), 20.0,
		"the scan found only %d files under %s — it is not looking where it thinks it is"
			% [files.size(), SIM_DIR])


func test_no_unseeded_randomness_anywhere_in_sim() -> void:
	var re := RegEx.new()
	assert_eq(re.compile(FORBIDDEN_RNG), OK, "the scan's own pattern does not compile")

	var files := PackedStringArray()
	_gd_files(SIM_DIR, files)

	var offenses := PackedStringArray()
	for path: String in files:
		var source: String = _strip_comments(FileAccess.get_file_as_string(path))
		var lines: PackedStringArray = source.split("\n")
		for k: int in lines.size():
			if re.search(lines[k]) != null:
				offenses.append("%s:%d  %s" % [path, k + 1, lines[k].strip_edges()])

	assert_eq(offenses.size(), 0,
		"unseeded randomness in sim/ — every draw must come from Rng.stream or Rng.substream:\n%s"
			% "\n".join(offenses))


## The pattern has to actually catch what it claims to, or the test above passes because it matches
## nothing rather than because there is nothing to match.
func test_the_scan_recognizes_a_violation() -> void:
	var re := RegEx.new()
	re.compile(FORBIDDEN_RNG)
	for bad: String in [
		"var x: float = randf()",
		"\tif randi() % 3 == 0:",
		"randomize()",
		"var t: int = randi_range(0, 7)",
	]:
		assert_ne(re.search(bad), null, "the scan would not have caught `%s`" % bad)
	for good: String in [
		"var x: float = rng.randf()",
		"var t: int = rng.randi_range(0, 7)",
		"func _randomize_nothing() -> void:",
	]:
		assert_eq(re.search(good), null, "the scan would falsely flag `%s`" % good)


## The directory contract, in the direction that matters. `game/` imports `sim/` freely; a reference
## the other way means something in the simulation has grown a dependency on a Node, and everything
## in `sim/` has to keep running under `godot --headless --script`.
func test_sim_never_reaches_into_game() -> void:
	var files := PackedStringArray()
	_gd_files(SIM_DIR, files)

	var offenses := PackedStringArray()
	for path: String in files:
		var source: String = _strip_comments(FileAccess.get_file_as_string(path))
		var lines: PackedStringArray = source.split("\n")
		for k: int in lines.size():
			if lines[k].contains("res://game"):
				offenses.append("%s:%d  %s" % [path, k + 1, lines[k].strip_edges()])

	assert_eq(offenses.size(), 0,
		"sim/ referenced game/ — the dependency only runs one way:\n%s" % "\n".join(offenses))


## RefCounted only. A `Node` in `sim/` does not merely bend the layering, it stops the file being
## constructible in a headless tool run, which is where the whole test suite and every generator
## entry point live.
##
## "RefCounted" includes extending a class that `sim/` itself declares — `NullPolicy extends
## Policy` is the intended shape of the policy hierarchy (0038), and every such base is a file
## this same scan covers, so the property holds transitively without being re-proved here.
func test_everything_in_sim_is_refcounted() -> void:
	var files := PackedStringArray()
	_gd_files(SIM_DIR, files)

	var sim_classes := PackedStringArray()
	for path: String in files:
		var source: String = FileAccess.get_file_as_string(path)
		for line: String in source.split("\n"):
			var trimmed: String = line.strip_edges()
			if trimmed.begins_with("class_name "):
				sim_classes.append(trimmed.substr(11).strip_edges())
				break

	var offenses := PackedStringArray()
	for path: String in files:
		var source: String = FileAccess.get_file_as_string(path)
		for line: String in source.split("\n"):
			var trimmed: String = line.strip_edges()
			if not trimmed.begins_with("extends "):
				continue
			var base: String = trimmed.substr(8).strip_edges()
			if base != "RefCounted" and not sim_classes.has(base):
				offenses.append("%s extends %s" % [path, base])
			break

	assert_eq(offenses.size(), 0,
		"sim/ must be RefCounted throughout:\n%s" % "\n".join(offenses))


# --- the fog of war boundary — docs/decisions/0034 -------------------------------------------------


## The renderer may not keep hold of ground truth.
##
## The rule this enforces is narrow on purpose: not "`game/` may not mention `UnitState`", which would
## ban the boundary from doing its job, but "`game/` may not *store* one". A stored reference is a live
## handle on an enemy's true tile that outlives the one call that was entitled to look, and that is
## exactly what `TankView` held while every unspotted tank on the board was drawn at full opacity.
##
## Where a pose comes from is `ViewState`'s answer, and `game/` asks it per repaint rather than keeping
## the source around.
func test_the_renderer_stores_no_ground_truth() -> void:
	var stored := RegEx.new()
	var reached := RegEx.new()
	assert_eq(stored.compile(STORED_UNIT_STATE), OK, "the scan's own pattern does not compile")
	assert_eq(reached.compile(REACHED_THROUGH_STATE), OK, "the scan's own pattern does not compile")

	var files := PackedStringArray()
	_gd_files(GAME_DIR, files)
	assert_gt(float(files.size()), 10.0,
		"the scan found only %d files under %s — it is not looking where it thinks it is"
			% [files.size(), GAME_DIR])

	var offenses := PackedStringArray()
	for path: String in files:
		var source: String = _strip_comments(FileAccess.get_file_as_string(path))
		var lines: PackedStringArray = source.split("\n")
		for k: int in lines.size():
			if stored.search(lines[k]) != null or reached.search(lines[k]) != null:
				offenses.append("%s:%d  %s" % [path, k + 1, lines[k].strip_edges()])

	assert_eq(offenses.size(), 0,
		"game/ holds simulation state directly — pose from ViewState instead (0034):\n%s"
			% "\n".join(offenses))


## Same argument as `test_the_scan_recognizes_a_violation`: a pattern that matches nothing passes the
## test above for the wrong reason, and the local-versus-member distinction is subtle enough to be
## worth stating in examples rather than only in a regex.
func test_the_ground_truth_scan_tells_a_member_from_a_local() -> void:
	var stored := RegEx.new()
	stored.compile(STORED_UNIT_STATE)
	for bad: String in ["var state: UnitState", "var  target : UnitState = null"]:
		assert_ne(stored.search(bad), null, "the scan would not have caught `%s`" % bad)
	for good: String in [
		"\tvar u: UnitState = match_state.unit(k)",
		"func active_unit() -> UnitState:",
		"\t\tvar u: UnitState = match_state.selected_unit()",
	]:
		assert_eq(stored.search(good), null, "the scan would falsely flag `%s`" % good)

	var reached := RegEx.new()
	reached.compile(REACHED_THROUGH_STATE)
	assert_ne(reached.search("_turret = actor.state.turret"), null,
		"the scan would not have caught a read through `.state`")
	assert_eq(reached.search("var match_state: MatchState"), null,
		"the scan would falsely flag a MatchState declaration")


## Every script under `game/` parses.
##
## CLAUDE.md records why this is worth a test of its own: a script that fails to parse still returns a
## `GDScript` from `load()`, just one whose `can_instantiate()` is false, and calling `new()` on it
## aborts the calling function silently. Nothing else in the suite touches `game/` — it is all Nodes —
## so before this, a syntax error there could only be found by launching the game.
func test_every_script_in_game_parses() -> void:
	var files := PackedStringArray()
	_gd_files(GAME_DIR, files)

	var broken := PackedStringArray()
	for path: String in files:
		var script: Resource = load(path)
		if script == null or not (script as GDScript).can_instantiate():
			broken.append(path)

	assert_eq(broken.size(), 0,
		"scripts under game/ do not parse — `new()` on these aborts its caller silently:\n%s"
			% "\n".join(broken))
