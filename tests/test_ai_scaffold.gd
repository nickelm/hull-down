extends TestCase

## 2e-i — the AI scaffolding: `Policy`, `AiView`, `AiRunner`, and the wall between the AI and the
## board. docs/decisions/0038.
##
## Two kinds of test in here, and the split matters. The behavioral half proves a full AI turn
## with `NullPolicy` completes, moves nothing, and leaves the state valid. The scan half proves the
## thing behavior cannot: that no file in the AI's decision path so much as names the classes that
## hold or take ground truth — covering policy files that do not exist yet, which is most of them.

const AI_DIR := "res://sim/ai"

## The boundary files — the only two under `sim/ai/` entitled to hold a `MatchState`. Everything
## else in that directory is decision code and gets scanned.
const BOUNDARY: Array[String] = ["ai_runner.gd", "ai_view.gd"]

## Class names whose APIs hold or take a `MatchState`. A policy naming any of these has either a
## board reference to pass in — already a leak — or is about to acquire one.
const GROUND_TRUTH_TOKENS: Array[String] = [
	"MatchState", "ActionResolver", "Spotting", "Overwatch", "FireAction", "MoveAction",
	"TurretAction", "HitResolver", "EventApplier", "SideKnowledge", "SideSound", "Sound",
	"Victory", "Deployment",
]

## A reach through another object's underscore-prefixed member — `view._resolver`, and every
## sibling it might grow. GDScript has no private, so the convention is enforced here instead.
## Bare `_helper()` calls on the policy's own members do not match; `self._helper` would, and
## policy code is written without `self.` on privates for exactly that reason.
const PRIVATE_REACH := "[\\w\\)\\]]\\._"

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, type_name: String = "medium") -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


## Two a side on a small flat board — everyone sees everyone, which is what the executor tests
## want. The isolation tests build their own bigger board where nobody sees anything.
func _match(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 3, 8))
	m.add_unit(_unit(md, 1, 3, 14))
	m.add_unit(_unit(md, 2, 20, 8))
	m.add_unit(_unit(md, 2, 20, 14))
	return m


# --- policies scripted for these tests only --------------------------------------------------------


## Moves its unit one tile east on the first ask, passes forever after.
class StepEastOnce:
	extends Policy
	var asked: Dictionary = {}

	func decide(view: AiView, unit_index: int) -> AiOrder:
		if asked.has(unit_index):
			return AiOrder.pass_order(unit_index)
		asked[unit_index] = true
		var u: UnitState = view.my_unit(unit_index)
		if u == null:
			return AiOrder.pass_order(unit_index)
		var goal: int = view.map().neighbor(u.tile, Grid.E)
		return AiOrder.move(unit_index, goal)


## Answers TURRET forever — free, so nothing but the runner's cap can end it.
class SpinsForever:
	extends Policy

	func decide(view: AiView, unit_index: int) -> AiOrder:
		var u: UnitState = view.my_unit(unit_index)
		var dir: int = Grid.N if u != null and u.turret != Grid.N else Grid.S
		return AiOrder.turret(unit_index, dir)


## Orders every unit onto a tile something is already standing on. Every order is refused.
class DrivesIntoFriends:
	extends Policy
	var other_tile: int = -1

	func decide(_view: AiView, unit_index: int) -> AiOrder:
		return AiOrder.move(unit_index, other_tile)


# --- the acceptance check: a NullPolicy turn -------------------------------------------------------


func test_a_null_policy_turn_completes_and_moves_nothing() -> void:
	var md: MapData = _flat()
	var m: MatchState = _match(md)
	var resolver := ActionResolver.new(md, cfg, m, 99)
	resolver.refresh_knowledge()

	var before_tiles := PackedInt32Array()
	var before_mp := PackedInt32Array()
	for u: UnitState in m.units:
		before_tiles.append(u.tile)
		before_mp.append(u.mp_left)
	var before_knowledge: int = m.knowledge_for(1).fingerprint()

	var results: Array[ActionResult] = AiRunner.run_turn(resolver, NullPolicy.new())

	assert_eq(results.size(), 0, "a side that passes produced action results")
	for k: int in m.units.size():
		assert_eq(m.units[k].tile, before_tiles[k], "unit %d moved under NullPolicy" % k)
		assert_eq(m.units[k].mp_left, before_mp[k], "unit %d spent movement under NullPolicy" % k)
	assert_true(m.all_activated(), "a passed turn left units still owed a decision")
	assert_eq(m.knowledge_for(1).fingerprint(), before_knowledge,
		"passing a turn changed what the side knows")

	# And the turn hands over cleanly on top of it.
	resolver.end_turn()
	assert_eq(m.active_side, 2, "the hand-over after an AI turn went to the wrong side")


func test_a_scripted_move_goes_through_the_resolver_and_really_moves() -> void:
	var md: MapData = _flat()
	var m: MatchState = _match(md)
	var resolver := ActionResolver.new(md, cfg, m, 99)
	resolver.refresh_knowledge()

	var from: int = m.unit(0).tile
	var results: Array[ActionResult] = AiRunner.run_turn(resolver, StepEastOnce.new())

	assert_eq(results.size(), 2, "two units stepping once should commit two results")
	if results.size() < 1:
		return
	assert_true(results[0].committed, "the runner returned an uncommitted result")
	assert_eq(m.unit(0).tile, md.neighbor(from, Grid.E), "the ordered step did not happen")
	assert_true(m.all_activated(), "a finished scripted turn left units unactivated")


func test_the_order_cap_ends_a_turn_a_policy_never_would() -> void:
	var md: MapData = _flat()
	var m: MatchState = _match(md)
	var resolver := ActionResolver.new(md, cfg, m, 99)
	resolver.refresh_knowledge()

	var results: Array[ActionResult] = AiRunner.run_turn(resolver, SpinsForever.new())
	assert_true(m.all_activated(), "a spinning policy left the turn unfinished")
	# Every result is a free traverse; the cap bounds them per unit.
	assert_le(float(results.size()), float(AiRunner.MAX_ORDERS_PER_UNIT * 2),
		"the cap did not bound a policy that never passes")


func test_a_refused_order_stands_the_unit_down_instead_of_looping() -> void:
	var md: MapData = _flat()
	var m: MatchState = _match(md)
	var resolver := ActionResolver.new(md, cfg, m, 99)
	resolver.refresh_knowledge()

	var p := DrivesIntoFriends.new()
	p.other_tile = m.unit(1).tile
	var results: Array[ActionResult] = AiRunner.run_turn(resolver, p)

	assert_eq(results.size(), 0, "an order onto an occupied tile was committed")
	assert_true(m.all_activated(), "refused orders left the turn unfinished")


# --- the wall --------------------------------------------------------------------------------------


func test_an_unseen_enemy_is_absent_from_the_view() -> void:
	var md: MapData = _flat(64)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 60, 60))
	var resolver := ActionResolver.new(md, cfg, m, 99)
	resolver.refresh_knowledge()

	var view: AiView = AiView.create(resolver, 1)
	assert_eq(view.contacts().size(), 0, "an enemy 800 m away in the open was a contact")
	assert_eq(view.my_unit(1), null, "the view handed out an enemy UnitState")
	assert_eq(view.my_units().size(), 1, "my_units does not match the side's roster")

	var probe: FireForecast = view.preview_fire(0, 1)
	assert_eq(probe.status, ActionResult.Status.NOT_VISIBLE,
		"a shot at an unseen enemy was not refused as NOT_VISIBLE")
	assert_eq(probe.range_m, 0.0, "a refused preview still measured the range to the target")


func test_a_seen_enemy_is_served_as_a_contact_with_its_true_tile() -> void:
	var md: MapData = _flat()
	var m: MatchState = _match(md)
	var resolver := ActionResolver.new(md, cfg, m, 99)
	resolver.refresh_knowledge()

	var view: AiView = AiView.create(resolver, 1)
	var seen: Array[Contact] = view.contacts()
	assert_eq(seen.size(), 2, "a flat board in optics range should serve both enemies")
	for c: Contact in seen:
		assert_true(c.is_live(), "a directly visible enemy came back as a ghost")
		assert_eq(c.tile, m.unit(c.unit).tile, "a live contact's tile is not the unit's tile")


func test_the_ai_stream_is_reserved_and_distinct() -> void:
	# 0005 reserved it; 2e-i is where it becomes load-bearing. The salt table is indexed by the
	# enum, so the value is part of every seeded draw the AI will ever make.
	assert_eq(Rng.Stream.AI, 2, "the AI stream moved — every seeded AI decision just changed")
	var a: RandomNumberGenerator = Rng.stream(1234, Rng.Stream.AI)
	var b: RandomNumberGenerator = Rng.stream(1234, Rng.Stream.COMBAT)
	assert_ne(a.randi(), b.randi(), "the AI stream is not independent of COMBAT")


# --- the scan: no ground truth anywhere in the decision path ---------------------------------------


func _policy_files() -> PackedStringArray:
	var out := PackedStringArray()
	var dir: DirAccess = DirAccess.open(AI_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry == "":
			break
		if entry.ends_with(".gd") and not BOUNDARY.has(entry):
			out.append(AI_DIR + "/" + entry)
	dir.list_dir_end()
	return out


func _strip_comments(source: String) -> String:
	var out := PackedStringArray()
	for line: String in source.split("\n"):
		var hash_at: int = line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


func test_the_scan_is_looking_at_real_files() -> void:
	var files: PackedStringArray = _policy_files()
	assert_ge(float(files.size()), 3.0,
		"the scan found only %d policy files under %s — it is not looking where it thinks it is"
			% [files.size(), AI_DIR])


func test_no_policy_file_names_a_ground_truth_class() -> void:
	var offenses := PackedStringArray()
	for path: String in _policy_files():
		var source: String = _strip_comments(FileAccess.get_file_as_string(path))
		var lines: PackedStringArray = source.split("\n")
		for k: int in lines.size():
			for token: String in GROUND_TRUTH_TOKENS:
				# Whole-word: "Sound" must not match "SoundContact", which policies may hold.
				var re := RegEx.new()
				re.compile("\\b%s\\b" % token)
				if re.search(lines[k]) != null:
					offenses.append("%s:%d  %s" % [path, k + 1, lines[k].strip_edges()])

	assert_eq(offenses.size(), 0,
		"AI decision code names classes that hold or take ground truth — go through AiView:\n%s"
			% "\n".join(offenses))


func test_no_policy_file_reaches_into_private_members() -> void:
	var re := RegEx.new()
	assert_eq(re.compile(PRIVATE_REACH), OK, "the scan's own pattern does not compile")

	var offenses := PackedStringArray()
	for path: String in _policy_files():
		var source: String = _strip_comments(FileAccess.get_file_as_string(path))
		var lines: PackedStringArray = source.split("\n")
		for k: int in lines.size():
			if re.search(lines[k]) != null:
				offenses.append("%s:%d  %s" % [path, k + 1, lines[k].strip_edges()])

	assert_eq(offenses.size(), 0,
		"AI decision code reaches through an underscore member — the view's internals are the "
			+ "board:\n%s" % "\n".join(offenses))


func test_the_reach_scan_recognizes_a_violation() -> void:
	var re := RegEx.new()
	re.compile(PRIVATE_REACH)
	for bad: String in ["view._resolver.state", "self._view._state", "x()._state"]:
		assert_ne(re.search(bad), null, "the scan would not have caught `%s`" % bad)
	for good: String in ["_score(c)", "var _memo := {}", "func _pick() -> int:"]:
		assert_eq(re.search(good), null, "the scan would falsely flag `%s`" % good)
