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
	"visibility", "metrics",
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
	"zones.count", "zones.objective_count",
	"roads.count", "roads.max_road_dl",
	"movement.base_ortho", "movement.base_diag", "movement.turn_cost_per_45",
	"movement.reverse_mult", "movement.default_mp",
	"visibility.hull_h_m", "visibility.turret_h_m", "visibility.max_range_tiles",
	"metrics.sightline_samples", "metrics.hull_down_min_frac",
	"metrics.chokepoint_frac_min", "metrics.chokepoint_frac_max",
	"overlay.border_width_m", "overlay.glow_width_m", "overlay.fill_strength",
	"overlay.emission_strength", "overlay.glow_strength", "overlay.path_fill_strength",
	"overlay.move_colour", "overlay.exposed_colour", "overlay.hull_down_colour",
	"overlay.hover_colour", "overlay.path_colour",
	"camera.focus_distance_m", "camera.min_distance_m",
	"camera.focus_lerp_rate", "camera.zoom_lerp_rate",
	"turn.units_per_side", "turn.sides", "turn.unit_spacing_tiles",
	"look.road_lift_m", "look.grid_strength",
	"look.hud.font_size", "look.hud.reference_height", "look.hud.button_min_w_px",
	"look.scatter.trees_per_woods_tile", "look.scatter.trunk_frac",
	"look.scatter.canopy_radius_m", "look.scatter.visible_range_m",
	"roads.junction_hub_sides",
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
	assert_eq(n, 10, "expected ten terrain types")
	for k: int in n:
		var name: String = cfg.terrain_names[k]
		assert_ne(name, "?", "terrain type %d has no name" % k)
		assert_ne(cfg.terrain_colours[k], Color.html("#ff00ff"),
			"terrain '%s' fell back to the missing-colour magenta" % name)
		assert_ge(cfg.terrain_spotting[k], 0.0, "terrain '%s' has negative spotting" % name)
		assert_ge(cfg.terrain_blocker_h[k], 0.0, "terrain '%s' has negative blocker height" % name)
		var cost: float = cfg.terrain_move_cost[k]
		assert_true(cost > 0.0 or cost == -1.0,
			"terrain '%s' move_cost must be positive or exactly -1 for impassable" % name)


## The names and order in terrain.json are load-bearing: TerrainTyper.Type indexes straight into
## these arrays. Reordering the file without changing the enum would silently repaint the map.
func test_terrain_order_matches_the_enum() -> void:
	var expected: Array[String] = [
		"open", "scrub", "woods", "marsh", "rock", "water", "ford", "road", "field", "village"
	]
	for k: int in expected.size():
		assert_eq(cfg.terrain_names[k], expected[k], "terrain type at index %d" % k)


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


func test_unit_roster() -> void:
	for name: String in ["light", "medium", "heavy"]:
		var u: Dictionary = cfg.unit(name)
		assert_false(u.is_empty(), "unit '%s' missing from units.json" % name)
		for block: String in ["movement", "armour", "gun", "optics", "dimensions"]:
			assert_true(u.has(block), "unit '%s' is missing its '%s' block" % [name, block])

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
		float((light["armour"] as Dictionary)["front"]),
		float((heavy["armour"] as Dictionary)["front"]),
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
	assert_almost_eq(float(normal) * Grid.QUANT, 1.0, 0.0001, "normal transition ceiling in metres")
	assert_almost_eq(float(rough) * Grid.QUANT, 2.0, 0.0001, "rough transition ceiling in metres")


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


## The road ribbon is drawn above the terrain's top face. Six centimetres was inside float precision
## at four hundred metres and z-fought, which read as holes in the road.
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
