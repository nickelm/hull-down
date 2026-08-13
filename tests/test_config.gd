extends TestCase

## Guards the data files. A missing key does not crash anything — Config falls back to a default —
## so without these tests a renamed or deleted tunable shows up as terrain that quietly changed
## shape, weeks later.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


## Sections whose disappearance would leave a whole generation stage running on defaults.
const REQUIRED_SECTIONS: Array[String] = [
	"world", "relief", "erosion", "hydrology", "traversal",
	"zones", "terrain_typing", "roads", "settlements", "movement",
	"visibility", "metrics", "playback",
	"spotting", "combat", "victory",
	# Mounted from data/ai.json rather than present in rules.json — the mount is what this asserts.
	"ai",
]

## Individually load-bearing paths. Each of these is read in a hot or structural place where the
## fallback default would be wrong rather than merely untuned.
const CRITICAL_PATHS: Array[String] = [
	"world.hf_size", "world.hf_cell_m", "world.grid_size", "world.tile_m", "world.quant_m",
	"relief.octaves", "relief.base_freq", "relief.strike_anisotropy",
	"erosion.hydraulic.droplet_count", "erosion.hydraulic.brush_radius",
	"erosion.hydraulic.mass_drift_max_pct",
	"erosion.thermal.repose_deg", "erosion.thermal.max_passes",
	"hydrology.stream_threshold_frac", "hydrology.river_threshold_frac", "hydrology.min_fords",
	"traversal.normal_max_dl", "traversal.rough_max_dl", "traversal.repair_max_passes",
	# The pathfinder read this as "movement.rough_extra_cost" for its whole life. That key does not
	# exist, so it silently ran on the fallback default — which happened to be the right number, so
	# nothing was ever visibly wrong. `cfg.missing` is the only thing that knew.
	"traversal.rough_extra_cost", "traversal.earthwork_penalty",
	"zones.count", "zones.objective_count",
	"roads.portal_count", "roads.redundant_edges", "roads.reuse_discount", "roads.max_road_dl",
	"settlements.site_count",
	"movement.base_ortho", "movement.base_diag", "movement.turn_cost_per_45",
	"movement.reverse_mult", "movement.default_mp",
	"visibility.hull_h_m", "visibility.turret_h_m", "visibility.max_range_tiles",
	"metrics.sightline_samples", "metrics.hull_down_min_frac",
	"metrics.chokepoint_frac_min", "metrics.chokepoint_frac_max",
	"overlay.border_width_m", "overlay.glow_width_m", "overlay.fill_strength",
	"overlay.emission_strength", "overlay.glow_strength", "overlay.path_fill_strength",
	"overlay.move_color", "overlay.exposed_color", "overlay.hull_down_color",
	"overlay.hover_color", "overlay.path_color", "overlay.move_far_color",
	"movement.actions_per_turn",
	"camera.gunner_look_sensitivity", "camera.gunner_min_pitch_deg", "camera.gunner_max_pitch_deg",
	"camera.focus_distance_m", "camera.min_distance_m",
	"camera.focus_lerp_rate", "camera.zoom_lerp_rate",
	"turn.units_per_side", "turn.sides", "turn.unit_spacing_tiles",
	"look.road_lift_m", "look.grid_strength",
	"look.hud.font_size", "look.hud.reference_height", "look.hud.button_min_w_px",
	"look.scatter.trees_per_woods_tile", "look.scatter.trunk_frac",
	"look.scatter.canopy_radius_m", "look.scatter.visible_range_m",
	"roads.junction_hub_sides",
	"camera.orbit_step_deg", "camera.yaw_lerp_rate", "camera.edge_scroll_margin_px",
	"camera.follow_during_action", "camera.follow_lerp_rate", "camera.follow_cancel_on_pan",
	"playback.drive_speed_m_s", "playback.reverse_speed_m_s", "playback.turn_rate_deg_s",
	"playback.speed_normal", "playback.speed_fast", "playback.min_event_seconds",
	"look.marker.anchor_height_m", "look.marker.arrow_px", "look.marker.arrow_offset_px",
	"look.marker.bar_width_px", "look.marker.mp_color",
	"look.path.line_lift_m", "look.path.line_width_m", "look.path.arrow_length_m",
	"look.path.line_color", "look.path.line_far_color", "look.path.label_px",
	"look.card.width_px", "look.card.placeholder", "look.card.pending_color",
	"turn.lock_controls_during_action",
	"spotting.point_blank_m", "spotting.exposed_mult", "spotting.hull_down_mult",
	"spotting.moved_max_mult", "spotting.stationary_mult", "spotting.ghost_turns",
	"combat.base_hit_chance", "combat.range_falloff_per_100m",
	"combat.min_hit_chance", "combat.max_hit_chance",
	"combat.hull_down_hit_mult", "combat.firer_moved_mult",
	"combat.no_pen_ratio", "combat.certain_pen_ratio", "combat.pen_falloff_per_100m",
	"combat.shred_share", "combat.critical_chance", "combat.critical_immobilised_share",
	"combat.default_ammo", "combat.turret_arc_steps", "combat.wreck_blocker_h_m",
	"combat.overwatch_shots", "combat.overwatch_arc_steps",
	"turn.turret_step_steps", "turn.enemy_playback_speed_index",
	"playback.turret_rate_deg_s", "playback.shot_flight_seconds",
	"playback.shot_impact_seconds", "playback.destroyed_seconds", "playback.spot_seconds",
	"look.hud.bar.button_min_w_px", "look.hud.bar.aim_color",
	"look.hud.log.max_lines", "look.hud.log.hold_seconds", "look.hud.log.contact_color",
	"victory.capture_radius_tiles", "victory.hold_turns", "victory.objectives_to_win",
	"look.ghost.color", "look.ghost.alpha_fresh", "look.watch.cone_length_m",
	"look.roster.width_px", "look.card.damaged_color",
	"ai.weights.progress_per_tile", "ai.weights.kill", "ai.weights.fire_threshold",
	"ai.candidates.max_per_unit", "ai.candidates.contacts_considered", "ai.tie_break_epsilon",
	"victory.turn_limit", "victory.value_village", "victory.grade_decisive",
	"entrenchment.concealment_mult",
]


func test_data_files_loaded() -> void:
	assert_false(cfg.rules.is_empty(), "rules.json did not load")
	assert_false(cfg.units.is_empty(), "units.json did not load")
	assert_gt(float(cfg.type_count()), 0.0, "terrain.json produced no types")


func test_required_sections_present() -> void:
	for s: String in REQUIRED_SECTIONS:
		assert_true(cfg.rules.has(s), "rules.json is missing the '%s' section" % s)


func test_critical_paths_present() -> void:
	for p: String in CRITICAL_PATHS:
		assert_true(cfg.has(p), "rules.json is missing '%s'" % p)
	assert_eq(cfg.missing.size(), 0,
		"lookups fell back to defaults: %s" % str(cfg.missing))


## Every leaf in rules.json must be reachable by its dotted path. This catches a _resolve bug
## rather than a data bug, and it scales without anyone maintaining a list.
func test_every_leaf_resolves() -> void:
	var paths: PackedStringArray = PackedStringArray()
	_collect(cfg.rules, "", paths)
	assert_gt(float(paths.size()), 60.0, "suspiciously few tunables found: %d" % paths.size())
	for p: String in paths:
		assert_true(cfg.has(p), "leaf '%s' exists in the file but does not resolve" % p)
	assert_eq(cfg.missing.size(), 0, "resolution recorded misses: %s" % str(cfg.missing))


func _collect(node: Dictionary, prefix: String, out: PackedStringArray) -> void:
	for k: Variant in node.keys():
		var key: String = str(k)
		if key.begins_with("_"):
			continue
		var path: String = key if prefix == "" else prefix + "." + key
		var v: Variant = node[k]
		if typeof(v) == TYPE_DICTIONARY:
			_collect(v as Dictionary, path, out)
		else:
			out.append(path)


func test_missing_path_is_recorded_not_silent() -> void:
	var v: float = cfg.f("world.no_such_key", 42.0)
	assert_eq(v, 42.0, "an absent path must return the supplied default")
	assert_true(cfg.missing.has("world.no_such_key"), "an absent path must be recorded in missing")


func test_terrain_types_are_complete() -> void:
	var n: int = cfg.type_count()
	assert_eq(n, 12, "expected twelve terrain types")
	for k: int in n:
		var name: String = cfg.terrain_names[k]
		assert_ne(name, "?", "terrain type %d has no name" % k)
		assert_ne(cfg.terrain_colors[k], Color.html("#ff00ff"),
			"terrain '%s' fell back to the missing-color magenta" % name)
		assert_ge(cfg.terrain_spotting[k], 0.0, "terrain '%s' has negative spotting" % name)
		assert_ge(cfg.terrain_blocker_h[k], 0.0, "terrain '%s' has negative blocker height" % name)
		var cost: float = cfg.terrain_move_cost[k]
		assert_true(cost > 0.0 or cost == -1.0,
			"terrain '%s' move_cost must be positive or exactly -1 for impassable" % name)


## The names and order in terrain.json are load-bearing: TerrainTyper.Type indexes straight into
## these arrays. Reordering the file without changing the enum would silently repaint the map.
func test_terrain_order_matches_the_enum() -> void:
	var expected: Array[String] = [
		"open", "scrub", "woods", "marsh", "rock", "water", "ford", "road", "field", "village",
		"woods_light", "woods_heavy",
	]
	for k: int in expected.size():
		assert_eq(cfg.terrain_names[k], expected[k], "terrain type at index %d" % k)


## The tiers are a movement claim and a visibility claim at once, and the visibility half is the
## sharper of the two. LOS blocks when a tile's cover clears the observer's eye, which sits at
## `turret_h_m` — so cover below that height does not block a tank's sightline at all, and cover
## above it blocks completely no matter how far above. There is no partial. A light tier is only
## worth having if it is on the transparent side of that line, and only interesting if it is still
## tall enough to mask a hull.
func test_the_forest_tiers_are_ordered_around_the_sight_lines() -> void:
	var light: int = cfg.type_by_name("woods_light")
	var mid: int = cfg.type_by_name("woods")
	var heavy: int = cfg.type_by_name("woods_heavy")
	for t: int in [light, mid, heavy]:
		assert_ge(float(t), 0.0, "a forest tier is missing from terrain.json")

	var hull_h: float = cfg.f("visibility.hull_h_m", 1.4)
	var turret_h: float = cfg.f("visibility.turret_h_m", 2.6)

	assert_lt(cfg.terrain_blocker_h[light], turret_h,
		"light woods stands above the turret line, so it blocks sight exactly as 8 m woods does")
	assert_gt(cfg.terrain_blocker_h[light], hull_h,
		"light woods is below the hull line, so it is not even concealment")
	assert_gt(cfg.terrain_blocker_h[mid], turret_h, "ordinary woods must block sight")
	assert_gt(cfg.terrain_blocker_h[heavy], cfg.terrain_blocker_h[mid],
		"heavy woods must be the tallest tier")

	# Going gets worse as the stand gets denser, and the heaviest stops armor outright.
	var tracked: int = MovementClass.Kind.TRACKED
	assert_lt(cfg.class_cost(tracked, light), cfg.class_cost(tracked, mid),
		"light woods is not easier going than ordinary woods")
	assert_eq(cfg.class_cost(tracked, heavy), -1.0, "heavy woods must stop a tank")
	assert_gt(cfg.class_cost(MovementClass.Kind.FOOT, heavy), 0.0,
		"infantry must be able to walk into heavy woods")
	assert_lt(cfg.terrain_spotting[heavy], cfg.terrain_spotting[light],
		"spotting must fall as the forest thickens")


func test_water_is_impassable_and_woods_block_sight() -> void:
	var water: int = cfg.type_by_name("water")
	assert_ge(float(water), 0.0, "no water terrain type")
	assert_eq(cfg.terrain_move_cost[water], -1.0, "water must be impassable")

	var woods: int = cfg.type_by_name("woods")
	assert_gt(cfg.terrain_blocker_h[woods], 0.0, "woods must block line of sight")
	var open: int = cfg.type_by_name("open")
	assert_eq(cfg.terrain_blocker_h[open], 0.0, "open ground must not block line of sight")

	# Roads are the only terrain cheaper than open ground; that is the point of them.
	var road: int = cfg.type_by_name("road")
	assert_lt(cfg.terrain_move_cost[road], cfg.terrain_move_cost[open],
		"roads must be cheaper than open ground")


# --- movement classes ---------------------------------------------------------------------------

## Every class must price every terrain. A short `costs` array is padded as impassable rather than
## as cost 1.0, so a class that silently forgot a terrain shows up as "cannot go there" instead of
## "drives straight through it" — but the padding is a safety net, not a licence, and this asserts
## nobody is relying on it.
func test_every_movement_class_is_complete() -> void:
	var types: int = cfg.type_count()
	var classes: int = cfg.class_count()
	assert_eq(classes, 4, "expected four movement classes")
	assert_eq(cfg.class_move_cost.size(), classes * types,
		"the class cost table is not classes x types")

	for c: int in classes:
		var name: String = cfg.class_names[c]
		assert_ne(name, "?", "movement class %d has no name" % c)
		var passable: int = 0
		for t: int in types:
			var cost: float = cfg.class_cost(c, t)
			assert_true(cost > 0.0 or cost == -1.0,
				"class '%s' on '%s' must be positive or exactly -1" % [name, cfg.terrain_names[t]])
			if cost > 0.0:
				passable += 1
		assert_gt(float(passable), float(types) * 0.5,
			"class '%s' cannot enter most of the map — that is a typo, not a design" % name)


## The order of movement_classes is load-bearing against MovementClass.Kind exactly as the types
## order is against TerrainTyper.Type.
func test_movement_class_order_matches_the_enum() -> void:
	var expected: Array[String] = ["tracked", "wheeled", "foot", "amphibious"]
	for k: int in expected.size():
		assert_eq(cfg.class_names[k], expected[k], "movement class at index %d" % k)
	assert_eq(cfg.class_by_name("tracked"), MovementClass.Kind.TRACKED, "class_by_name disagrees")
	assert_eq(MovementClass.REFERENCE, MovementClass.Kind.TRACKED,
		"the reference class must be the one the game actually fields")


## The reference row is a slice of the table, not a second copy of the numbers.
func test_the_reference_row_is_the_tracked_row() -> void:
	for t: int in cfg.type_count():
		assert_eq(cfg.terrain_move_cost[t], cfg.class_cost(MovementClass.REFERENCE, t),
			"terrain_move_cost disagrees with the class table at '%s'" % cfg.terrain_names[t])


## The classes have to actually differ, or the dimension is decoration. Each claim here is a rule:
## a lorry cannot cross a marsh a tank can; infantry walk through woods a tank labors in; only an
## amphibian enters the water.
func test_the_classes_disagree_about_the_ground() -> void:
	var marsh: int = cfg.type_by_name("marsh")
	var woods: int = cfg.type_by_name("woods")
	var water: int = cfg.type_by_name("water")
	var road: int = cfg.type_by_name("road")

	assert_gt(cfg.class_cost(MovementClass.Kind.TRACKED, marsh), 0.0, "a tank can cross a marsh")
	assert_eq(cfg.class_cost(MovementClass.Kind.WHEELED, marsh), -1.0, "a lorry cannot")

	assert_lt(cfg.class_cost(MovementClass.Kind.FOOT, woods),
		cfg.class_cost(MovementClass.Kind.TRACKED, woods), "infantry outpace armor in woods")

	assert_eq(cfg.class_cost(MovementClass.Kind.TRACKED, water), -1.0, "a tank cannot swim")
	assert_gt(cfg.class_cost(MovementClass.Kind.AMPHIBIOUS, water), 0.0, "an amphibian can")

	# Every class is faster on a made surface than on the ground beside it; that is what a road is.
	var open: int = cfg.type_by_name("open")
	for c: int in cfg.class_count():
		assert_lt(cfg.class_cost(c, road), cfg.class_cost(c, open),
			"class '%s' gains nothing from a road" % cfg.class_names[c])


# --- concealment — docs/decisions/0028 ------------------------------------------------------------

## The restructure's whole claim, as an assertion.
##
## The per-type `spotting` scalar became the tracked row of a per-class table. If those twelve
## numbers are not the twelve that were deleted, the change was not a restructure — it was a silent
## retune of every spotting range in the game, dressed up as a refactor. The literal is here rather
## than derived precisely because deriving it from the file being tested would prove nothing.
func test_the_tracked_concealment_row_is_the_scalar_it_replaced() -> void:
	var was: Array[float] = [
		1.0, 0.9, 0.4, 0.8, 0.95, 1.0, 1.0, 1.0, 0.95, 0.5, 0.7, 0.25,
	]
	assert_eq(cfg.type_count(), was.size(), "the roster of terrain types changed size")
	for t: int in was.size():
		assert_almost_eq(cfg.terrain_spotting[t], was[t], 0.0001,
			"concealment on '%s' moved when the table was restructured" % cfg.terrain_names[t])


## Every class prices every terrain's concealment, and the padding is a net rather than a licence —
## the same claim `test_every_movement_class_is_complete` makes about going.
func test_every_concealment_class_is_complete() -> void:
	var types: int = cfg.type_count()
	assert_eq(cfg.concealment_class_names.size(), cfg.class_count(),
		"the concealment table has a different number of classes from the movement table")
	assert_eq(cfg.class_concealment.size(), cfg.class_count() * types,
		"the concealment table is not classes x types")

	for c: int in cfg.class_count():
		assert_eq(cfg.concealment_class_names[c], cfg.class_names[c],
			"concealment class %d is not the movement class of the same index" % c)
		for t: int in types:
			var v: float = cfg.concealment(c, t)
			assert_in_range(v, 0.01, 1.0,
				"concealment for '%s' on '%s' is outside (0, 1]"
					% [cfg.class_names[c], cfg.terrain_names[t]])


## The axis has to actually bend, or the whole restructure bought a table with four identical rows.
## Infantry are not in the game yet; the numbers that will make them work are, and this is what stops
## them being quietly flattened before they arrive.
func test_concealment_differs_by_movement_class() -> void:
	var heavy: int = cfg.type_by_name("woods_heavy")
	var open: int = cfg.type_by_name("open")
	var foot: int = MovementClass.Kind.FOOT
	var tracked: int = MovementClass.Kind.TRACKED

	assert_lt(cfg.concealment(foot, heavy), cfg.concealment(tracked, heavy),
		"a rifle section hides no better in heavy forest than a tank does")
	assert_lt(cfg.concealment(foot, open), cfg.concealment(tracked, open),
		"a rifle section is as conspicuous as a tank in the open")
	assert_eq(cfg.concealment(tracked, open), 1.0,
		"open ground must be the fully-visible reference for a vehicle")


## The early-out in Spotting prunes a pair without casting a ray when the distance already exceeds
## the range before exposure is applied. That is only sound while exposure can shrink a range and
## never grow one — the day a multiplier goes above 1.0, spotting starts silently missing contacts
## and nothing else in the suite would notice.
func test_the_exposure_multipliers_can_only_shrink_a_spotting_range() -> void:
	var exposed: float = cfg.f("spotting.exposed_mult", 1.0)
	var hull_down: float = cfg.f("spotting.hull_down_mult", 1.0)
	assert_le(exposed, 1.0, "the exposed multiplier is above 1.0 and breaks the spotting early-out")
	assert_le(hull_down, 1.0, "the hull-down multiplier is above 1.0 and breaks the early-out")
	assert_lt(hull_down, exposed, "hull down must be harder to see than exposed, or it buys nothing")
	assert_ge(cfg.f("spotting.moved_max_mult", 0.0), cfg.f("spotting.stationary_mult", 1.0),
		"moving must not make a unit harder to see than sitting still")
	assert_ge(float(cfg.i("spotting.ghost_turns", 0)), 1.0,
		"a ghost that decays in under a turn is never seen by the player at all")
	# Entrenchment rides the same early-out: it multiplies the pre-exposure range, so it may only
	# ever shrink one — 2f, docs/decisions/0041.
	assert_in_range(cfg.f("entrenchment.concealment_mult", 1.0), 0.01, 1.0,
		"the entrenchment multiplier is above 1.0 and breaks the spotting early-out")


# --- combat — docs/decisions/0029 -----------------------------------------------------------------

## Bands, orderings and clamps, all read straight off the JSON. None of this needs the combat code to
## exist; it is the shape of the numbers, and it is what stops a retune landing an impossible rule.
func test_the_combat_numbers_are_well_formed() -> void:
	assert_in_range(cfg.f("combat.base_hit_chance", 0.0), 0.0, 1.0, "base_hit_chance is a probability")
	assert_lt(cfg.f("combat.min_hit_chance", 0.0), cfg.f("combat.max_hit_chance", 0.0),
		"the to-hit clamp is inverted")
	assert_in_range(cfg.f("combat.max_hit_chance", 0.0), 0.0, 1.0, "max_hit_chance is a probability")
	assert_gt(cfg.f("combat.range_falloff_per_100m", 0.0), 0.0,
		"without falloff, range does not enter the to-hit roll at all")

	# Every to-hit modifier is a penalty. A multiplier above 1.0 would let the clamp be the only
	# thing holding the chance down, which is a different rule from the one written in rules.md.
	for key: String in [
		"combat.hull_down_hit_mult", "combat.firer_moved_mult", "combat.target_moved_mult",
		"combat.shaken_hit_mult", "combat.gun_damaged_hit_mult", "combat.overwatch_hit_mult",
	]:
		assert_in_range(cfg.f(key, 0.0), 0.01, 1.0, "'%s' is not a penalty" % key)

	assert_lt(cfg.f("combat.no_pen_ratio", 0.0), cfg.f("combat.certain_pen_ratio", 0.0),
		"the penetration band is inverted")
	assert_lt(cfg.f("combat.no_pen_ratio", 0.0), 1.0,
		"nothing below parity ever penetrates, which makes the band one-sided")
	assert_gt(cfg.f("combat.certain_pen_ratio", 0.0), 1.0,
		"parity penetrates with certainty, which deletes the interesting half of the band")

	assert_in_range(cfg.f("combat.shred_share", 0.0), 0.0, 1.0, "shred_share is a probability")
	assert_in_range(cfg.f("combat.critical_chance", 0.0), 0.0, 1.0,
		"critical_chance is a probability")
	assert_in_range(cfg.f("combat.critical_immobilised_share", 0.0), 0.0, 1.0,
		"critical_immobilised_share is a probability")
	assert_lt(cfg.f("combat.critical_chance", 0.0), 1.0,
		"every penetration rolling a critical means nothing is ever destroyed")

	assert_ge(float(cfg.i("combat.turret_arc_steps", 0)), float(cfg.i("combat.overwatch_arc_steps", 0)),
		"overwatch watches a wider arc than the turret can physically traverse")
	assert_le(float(cfg.i("combat.turret_arc_steps", 0)), 4.0,
		"a turret arc of more than four 45-degree steps is the whole circle and no arc at all")


## A wreck has to conceal a hull and leave a turret, which is the same threshold light woods is
## chosen against — docs/decisions/0031. Below the hull line it is decoration; above the turret line
## it is a wall, and destroying a tank would blind everyone behind it.
func test_a_wreck_conceals_a_hull_and_leaves_a_turret() -> void:
	var wreck: float = cfg.f("combat.wreck_blocker_h_m", 0.0)
	assert_gt(wreck, cfg.f("visibility.hull_h_m", 1.4),
		"a wreck below the hull line is cover that covers nothing")
	assert_lt(wreck, cfg.f("visibility.turret_h_m", 2.6),
		"a wreck above the turret line is an opaque wall, not a hull-down position")


func test_the_victory_condition_is_winnable() -> void:
	var need: int = cfg.i("victory.objectives_to_win", 0)
	var placed: int = cfg.i("zones.objective_count", 0)
	assert_ge(float(need), 1.0, "a victory condition needing no objectives is already met")
	assert_le(float(need), float(placed),
		"winning needs %d objectives and the generator places %d" % [need, placed])
	assert_ge(float(cfg.i("victory.hold_turns", 0)), 1.0,
		"an objective held for no turns is captured by driving past it")


func test_unit_roster() -> void:
	for name: String in ["light", "medium", "heavy"]:
		var u: Dictionary = cfg.unit(name)
		assert_false(u.is_empty(), "unit '%s' missing from units.json" % name)
		for block: String in ["movement", "armor", "gun", "optics", "dimensions"]:
			assert_true(u.has(block), "unit '%s' is missing its '%s' block" % [name, block])

		# By key, not by block. The card read `armor.side` for its whole life and nothing here
		# noticed when the roster went to five facings — a block-level check cannot tell a renamed
		# key from a present one, and the symptom was a card quietly reading 0 mm of side armor.
		var armor: Dictionary = u["armor"] as Dictionary
		for facing: String in ["front", "left", "right", "rear", "top"]:
			assert_true(armor.has(facing),
				"unit '%s' has no '%s' armor — docs/decisions/0004 names five facings"
					% [name, facing])
			assert_gt(float(armor[facing]), 0.0,
				"unit '%s' has no thickness on its %s plate" % [name, facing])

		var gun: Dictionary = u["gun"] as Dictionary
		for key: String in [
			"calibre_mm", "penetration_mm", "shred_mm", "shots_per_action", "accuracy", "ammo"
		]:
			assert_true(gun.has(key), "unit '%s' gun is missing '%s'" % [name, key])
			assert_gt(float(gun[key]), 0.0, "unit '%s' gun has a useless '%s'" % [name, key])

	assert_false(cfg.unit(cfg.default_unit_name()).is_empty(),
		"default_unit names a unit that does not exist")

	# The roster's shape is a design claim: light is fast and thin, heavy is slow and thick.
	var light: Dictionary = cfg.unit("light")
	var heavy: Dictionary = cfg.unit("heavy")
	assert_gt(
		float((light["movement"] as Dictionary)["mp"]),
		float((heavy["movement"] as Dictionary)["mp"]),
		"the light tank must be faster than the heavy"
	)
	assert_lt(
		float((light["armor"] as Dictionary)["front"]),
		float((heavy["armor"] as Dictionary)["front"]),
		"the light tank must be thinner-skinned than the heavy"
	)
	assert_gt(
		float((light["optics"] as Dictionary)["base_range_m"]),
		float((heavy["optics"] as Dictionary)["base_range_m"]),
		"the light tank must have the better optics"
	)


## Structural constants in code and their counterparts in data must agree, or the pipeline
## downsamples into a grid of the wrong size.
func test_code_and_data_geometry_agree() -> void:
	assert_eq(cfg.i("world.grid_size", 0), Grid.SIZE, "world.grid_size vs Grid.SIZE")
	assert_almost_eq(cfg.f("world.tile_m", 0.0), Grid.TILE_M, 0.0001, "world.tile_m vs Grid.TILE_M")
	assert_almost_eq(cfg.f("world.quant_m", 0.0), Grid.QUANT, 0.0001, "world.quant_m vs Grid.QUANT")

	# The heightfield must downsample into the gameplay grid by a whole number of cells.
	var hf: int = cfg.i("world.hf_size", 0)
	assert_eq(hf % Grid.SIZE, 0, "hf_size %d does not divide into the %d grid" % [hf, Grid.SIZE])
	var ratio: int = hf / Grid.SIZE
	assert_almost_eq(
		cfg.f("world.hf_cell_m", 0.0) * float(ratio), Grid.TILE_M, 0.0001,
		"heightfield cell size times the downsample ratio must equal the tile size"
	)


## The angle of repose and the escarpment threshold are in tension: if repose is too shallow, no
## transition can ever exceed 2 m, escarpments never exist, and the connectivity repair path in
## 4.6 is dead code. See docs/decisions/0009.
func test_repose_still_permits_escarpments() -> void:
	var repose: float = cfg.f("erosion.thermal.repose_deg", 0.0)
	var escarpment_m: float = float(cfg.i("traversal.rough_max_dl", 4)) * Grid.QUANT

	# Compared at the *gameplay tile* scale, not the heightfield cell scale. Repose is enforced
	# between 2.5 m cells, but an escarpment is a drop between 10 m tiles, and a tile spans four
	# cells — so a slope well under the per-cell threshold still accumulates into a wall. Comparing
	# the two at the cell scale says escarpments are impossible on maps that are full of them.
	var max_tile_step_m: float = tan(deg_to_rad(repose)) * Grid.TILE_M
	assert_gt(max_tile_step_m, escarpment_m,
		"repose of %.1f degrees caps a %.1f m tile at %.2f m, below the %.2f m escarpment threshold"
			% [repose, Grid.TILE_M, max_tile_step_m, escarpment_m])


func test_traversal_thresholds_are_ordered() -> void:
	var normal: int = cfg.i("traversal.normal_max_dl", 0)
	var rough: int = cfg.i("traversal.rough_max_dl", 0)
	assert_lt(float(normal), float(rough), "normal_max_dl must be below rough_max_dl")
	# The spec's thresholds are 1.0 m and 2.0 m; at 0.5 m quanta that is 2 and 4.
	assert_almost_eq(float(normal) * Grid.QUANT, 1.0, 0.0001, "normal transition ceiling in meters")
	assert_almost_eq(float(rough) * Grid.QUANT, 2.0, 0.0001, "rough transition ceiling in meters")


func test_movement_costs_are_octile_consistent() -> void:
	var o: int = cfg.i("movement.base_ortho", 0)
	var d: int = cfg.i("movement.base_diag", 0)
	assert_eq(o, 10, "base_ortho must match Grid.octile's scaling")
	assert_eq(d, 14, "base_diag must match Grid.octile's scaling")
	assert_gt(cfg.f("movement.reverse_mult", 0.0), 1.0, "reversing must cost more than driving")


func test_visibility_heights_permit_hull_down() -> void:
	var hull: float = cfg.f("visibility.hull_h_m", 0.0)
	var turret: float = cfg.f("visibility.turret_h_m", 0.0)
	assert_lt(hull, turret, "the hull must sit below the turret or hull down cannot exist")
	# The hull-down band is the height range a crest must fall into. If it is thinner than one
	# elevation quantum, no terraced crest can ever produce the state the game is named after.
	assert_ge(turret - hull, Grid.QUANT,
		"the hull-down band (%.2f m) is thinner than one elevation quantum (%.2f m)"
			% [turret - hull, Grid.QUANT])


func test_metric_targets_are_well_formed() -> void:
	assert_lt(cfg.f("metrics.sightline_median_min_m", 0.0),
		cfg.f("metrics.sightline_median_max_m", 0.0), "sightline band is inverted")
	# Expressed as a fraction of the map's width, not an absolute tile count — see the note in
	# rules.json and decision 0009.
	assert_lt(cfg.f("metrics.chokepoint_frac_min", 0.0),
		cfg.f("metrics.chokepoint_frac_max", 0.0), "chokepoint band is inverted")
	assert_gt(float(cfg.i("metrics.chokepoint_cap", 0)),
		cfg.f("metrics.chokepoint_frac_max", 0.0) * float(Grid.SIZE),
		"the min-cut search cap is below the top of the target band, so a map that should fail "
		+ "for being too open would be reported as merely capped")
	assert_lt(cfg.f("metrics.escarpment_frac_min", 0.0),
		cfg.f("metrics.escarpment_frac_max", 0.0), "escarpment band is inverted")
	assert_in_range(cfg.f("metrics.hull_down_min_frac", 0.0), 0.0, 1.0,
		"hull_down_min_frac is a fraction")


## An overlay region's border is drawn inward from the tile edge. If it is anything like half a
## tile wide, opposite borders meet in the middle and every tile in the region reads as border —
## which is a flat tint again, the exact thing the outline replaced.
func test_the_overlay_border_fits_well_inside_a_tile() -> void:
	var border: float = cfg.f("overlay.border_width_m", 0.0)
	assert_gt(border, 0.0, "the overlay border has no width")
	assert_lt(border * 2.0, cfg.f("world.tile_m", 10.0) * 0.5,
		"the border is wide enough that opposite edges of a tile merge")


## The road ribbon is drawn above the terrain's top face. Six centimeters was inside float precision
## at four hundred meters and z-fought, which read as holes in the road.
func test_the_road_lift_clears_the_terrain_surface() -> void:
	assert_gt(cfg.f("look.road_lift_m", 0.0), 0.1,
		"the road sits too close to the ground to survive depth precision at range")


## Two units a side is what docs/decisions/0012 specifies, and Deployment reads these.
func test_the_turn_setup_is_playable() -> void:
	assert_ge(float(cfg.i("turn.units_per_side", 0)), 1.0, "a side with no units cannot play")
	assert_ge(float(cfg.i("turn.sides", 0)), 1.0, "a match needs at least one side")


## Selecting a unit has to bring the camera closer than the overview, or focusing does nothing
## visible — which is the complaint that started this.
func test_focusing_zooms_in_from_the_overview() -> void:
	var focus: float = cfg.f("camera.focus_distance_m", 0.0)
	assert_gt(focus, cfg.f("camera.min_distance_m", 0.0), "focus distance is inside the zoom floor")
	assert_lt(focus, cfg.f("camera.start_height_m", 420.0),
		"focusing on a unit must be closer than the overview distance")


## One action has to buy less than a whole turn's movement, or the near and far regions of the
## movement overlay are the same set and the split says nothing — docs/decisions/0014.
func test_an_action_buys_part_of_a_turns_movement() -> void:
	var actions: int = cfg.i("movement.actions_per_turn", 0)
	assert_ge(float(actions), 2.0, "a turn needs at least two actions for the split to mean anything")
	assert_lt(float(cfg.i("movement.default_mp", 0)) / float(maxi(actions, 1)),
		float(cfg.i("movement.default_mp", 0)),
		"one action must buy less than the whole turn's movement")


func test_gunner_look_pitch_is_ordered() -> void:
	assert_lt(cfg.f("camera.gunner_min_pitch_deg", 0.0), cfg.f("camera.gunner_max_pitch_deg", 0.0),
		"the gunner view's pitch limits are inverted")


## The optic's zoom range, and that it starts inside it — a starting field of view outside the
## limits is clamped on the first wheel notch, so the view jumps the moment you touch it.
func test_the_gunner_optic_zooms_within_its_limits() -> void:
	var lo: float = cfg.f("camera.gunner_fov_min_deg", 0.0)
	var hi: float = cfg.f("camera.gunner_fov_max_deg", 0.0)
	assert_gt(lo, 0.0, "a field of view of zero degrees shows nothing")
	assert_lt(lo, hi, "the gunner optic's zoom limits are inverted")
	assert_in_range(cfg.f("camera.gunner_fov_deg", 0.0), lo, hi,
		"the gunner view starts at a field of view outside its own zoom range")
	assert_in_range(cfg.f("camera.gunner_zoom_step", 0.0), 0.01, 0.5,
		"a zoom step outside a few percent to half is either imperceptible or a jump")


## The gunner camera sits where the visibility rules put the observer's eye, and that is the whole
## basis on which this view is evidence about the overlay. It also has to clear the turret it is
## mounted on, or half of looking around is looking at your own vehicle — the two used to disagree,
## with the camera 30 cm low and inside the turret box.
func test_the_gunner_eye_is_the_eye_the_rules_use() -> void:
	var eye: float = cfg.f("visibility.turret_h_m", 0.0)
	assert_gt(eye, cfg.f("visibility.hull_h_m", 0.0),
		"the observer's eye is at or below the hull line")
	# The turret box in TankView.setup: centered at 1.95, 1.1 tall, so its top face is at 2.5.
	assert_gt(eye, 2.5,
		"the eye at %.2f m is inside the turret mesh, which is what made looking behind useless"
			% eye)


## Q and E exist to land the camera on the facing grid — docs/decisions/0022.
##
## Two claims, and the second is the one that matters. The step has to divide the circle evenly, or
## repeated presses never come back round to where they started. And it has to be a whole multiple
## of the facing increment itself, or the snap lands the camera between two facings and diagonals
## stop reading as diagonals — which is the one thing the snap is for. A quarter turn satisfies
## both; so would 45, and so would 180.
func test_the_orbit_step_lands_on_the_facing_grid() -> void:
	var step: float = cfg.f("camera.orbit_step_deg", 0.0)
	assert_gt(step, 0.0, "the orbit step has no size")

	var steps_per_turn: float = 360.0 / step
	assert_almost_eq(steps_per_turn, roundf(steps_per_turn), 0.0001,
		"an orbit step of %.1f degrees does not divide the circle evenly" % step)

	var facing_deg: float = 360.0 / float(Grid.DX.size())
	var facings_per_step: float = step / facing_deg
	assert_almost_eq(facings_per_step, roundf(facings_per_step), 0.0001,
		"an orbit step of %.1f degrees is not a whole number of %.0f-degree facings"
			% [step, facing_deg])


## Following has to be tighter than the ordinary focus glide. At the glide rate the camera trails a
## moving tank by a few meters, which is pleasant at 1x and reads as lag at 3x.
func test_following_is_tighter_than_the_focus_glide() -> void:
	assert_gt(cfg.f("camera.follow_lerp_rate", 0.0), cfg.f("camera.focus_lerp_rate", 0.0),
		"following a moving unit is no tighter than gliding to a stationary one")


## Six pixels was the original band and it is below the width of a window border. An edge you cannot
## aim at is not a control, it is an accident waiting to scroll the map.
func test_the_edge_scroll_band_is_hittable() -> void:
	assert_ge(cfg.f("camera.edge_scroll_margin_px", 0.0), 10.0,
		"the edge scroll band is too thin to hit deliberately")


func test_playback_speeds_are_ordered() -> void:
	assert_gt(cfg.f("playback.speed_normal", 0.0), 0.0, "1x playback must advance")
	assert_gt(cfg.f("playback.speed_fast", 0.0), cfg.f("playback.speed_normal", 0.0),
		"fast playback must be faster than normal")
	# A zero-length event would divide by zero and stall the replay loop on it forever.
	assert_gt(cfg.f("playback.min_event_seconds", 0.0), 0.0,
		"an event with no floor on its duration can stall the replay")
	assert_gt(cfg.f("playback.drive_speed_m_s", 0.0), cfg.f("playback.reverse_speed_m_s", 0.0),
		"reversing must look slower than driving, or the reverse edge has no visible consequence")
	var idx: int = cfg.i("playback.default_speed_index", -1)
	assert_in_range(float(idx), 0.0, 2.0, "default_speed_index must name one of the three speeds")


## Both marker sprites are `fixed_size`, so they hold constant screen size and their separation is in
## texture pixels rather than meters — docs/decisions/0023. If the offset is smaller than the two
## half-heights the arrow sits on top of the bar at every zoom, not just the far ones.
func test_the_marker_sprites_do_not_overlap() -> void:
	var half_arrow: float = cfg.f("look.marker.arrow_px", 0.0) * 0.5
	var half_bar: float = cfg.f("look.marker.bar_thickness_px", 0.0) * 0.5
	assert_ge(cfg.f("look.marker.arrow_offset_px", 0.0), half_arrow + half_bar,
		"the selection arrow overlaps the status bar")


## Same depth-precision problem the road ribbon has, and the same fix — the route lies on the
## terrain's top face and z-fights with it at range if it sits too close. It also has to clear the
## road, or a route that follows one vanishes into it for exactly the stretch where telling the two
## apart matters.
func test_the_path_line_clears_the_terrain_and_the_road() -> void:
	assert_gt(cfg.f("look.path.line_lift_m", 0.0), 0.1,
		"the path line sits too close to the ground to survive depth precision at range")
	assert_gt(cfg.f("look.path.line_lift_m", 0.0), cfg.f("look.road_lift_m", 0.14),
		"the path line sits at or below the road ribbon and will z-fight with it")
	assert_lt(cfg.f("look.path.line_width_m", 0.0), cfg.f("world.tile_m", 10.0) * 0.5,
		"the path line is wide enough to read as a filled corridor rather than as a route")
	assert_lt(cfg.f("look.path.arrow_length_m", 0.0), cfg.f("world.tile_m", 10.0) * 1.5,
		"the destination facing arrow is so long it spills across neighboring tiles")


## Separation in **hue**, in degrees around the wheel. Two colors can be far apart in RGB and still
## be the same color lit differently, which is exactly the trap the previous version of this fell
## into: it summed absolute RGB differences and passed at 0.56 on two ambers six degrees apart.
## Brightness says "the same thing, further away"; hue says "a different thing".
func _hue_gap_deg(a: Color, b: Color) -> float:
	var gap: float = absf(a.h - b.h) * 360.0
	return minf(gap, 360.0 - gap)


## The two halves of the route must be told apart at a glance, or the boundary the movement overlay
## draws as a ring says nothing when it is repeated along the route — docs/decisions/0014, amended
## by 0021.
func test_the_two_path_line_colors_are_distinguishable() -> void:
	var near: Color = cfg.color("look.path.line_color", Color.BLACK)
	var far: Color = cfg.color("look.path.line_far_color", Color.BLACK)
	assert_gt(_hue_gap_deg(near, far), 30.0,
		"the two halves of the path line differ in brightness but not in hue")


## The same claim for the overlay's two movement bands, which had no guard at all — which is how
## they came to be one amber at two brightnesses without anything noticing. Near is cool, far is
## warm, on the walk-and-dash convention; the threshold is a genuine hue step rather than a shade.
func test_the_two_movement_bands_are_different_colors() -> void:
	var near: Color = cfg.color("overlay.move_color", Color.BLACK)
	var far: Color = cfg.color("overlay.move_far_color", Color.BLACK)
	assert_gt(_hue_gap_deg(near, far), 60.0,
		"the near and far movement bands are the same hue at two brightnesses")


## The near band was light blue once before and read as water — see the note in rules.json. It is
## back, as an outline rather than a flat tint, and it has to stay clear of the water terrain on
## brightness even where the hues are close.
func test_the_near_band_does_not_read_as_water() -> void:
	var band: Color = cfg.color("overlay.move_color", Color.BLACK)
	var water: Color = cfg.terrain_colors[cfg.type_by_name("water")]
	var separated: bool = (
		_hue_gap_deg(band, water) > 25.0 or absf(band.v - water.v) > 0.25
	)
	assert_true(separated,
		"the movement band is the same hue and brightness as water, which is how it read as water "
		+ "the first time (hue %.0f vs %.0f, value %.2f vs %.2f)"
			% [band.h * 360.0, water.h * 360.0, band.v, water.v])
