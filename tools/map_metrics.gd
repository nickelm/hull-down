extends SceneTree

## Measure a map against the tactical targets.
##
##   godot --headless --path . --script res://tools/map_metrics.gd -- --map user://maps/dev.hdmap
##   godot --headless --path . --script res://tools/map_metrics.gd -- --seed 12345
##
## Exits nonzero if the map fails, so it can gate a batch run.


func _initialize() -> void:
	var cli := Cli.from_os()
	var cfg := Config.load_default()

	var md: MapData = null
	var master_seed: int = cli.int_opt("seed", 12345)

	var map_path: String = cli.str_opt("map", "")
	if map_path != "":
		md = MapCodec.load_map(map_path)
		if md == null:
			print("could not load %s" % map_path)
			quit(2)
			return
		master_seed = md.master_seed
	else:
		var params: MapGenerator.Params = (
			MapGenerator.Params.small(cfg) if cli.flag("small")
			else MapGenerator.Params.from_config(cfg)
		)
		md = MapGenerator.generate(
			cfg, master_seed, params, Callable() if cli.flag("quiet") else Cli.printer()
		)
		if md == null:
			print("seed %d could not be repaired into a connected map" % master_seed)
			quit(1)
			return

	var m: Dictionary = MapMetrics.evaluate(md, cfg, master_seed)
	if cli.flag("json"):
		print(JSON.stringify(_summary(m), "  "))
	else:
		_report(m, cfg)

	quit(0 if bool(m["pass"]) else 1)


func _report(m: Dictionary, cfg: Config) -> void:
	var sight: Dictionary = m["sightline"]
	var hull: Dictionary = m["hull_down"]
	var bal: Dictionary = m["balance"]

	print("")
	print("Map metrics — seed %d" % int(m["seed"]))
	print("  %-14s %6.0f m   (quartiles %.0f / %.0f, target %.0f-%.0f)" % [
		"sightline", float(sight["ray_median_m"]), float(sight["ray_q1_m"]),
		float(sight["ray_q3_m"]), cfg.f("metrics.sightline_median_min_m", 300.0),
		cfg.f("metrics.sightline_median_max_m", 900.0),
	])
	print("  %-14s %6.0f m   (the spec's random-pair metric — see decision 0009)" % [
		"  pair median", float(sight["pair_median_m"]),
	])
	print("  %-14s %6.1f %%  (target >= %.1f%%)" % [
		"hull down", float(hull["fraction"]) * 100.0,
		cfg.f("metrics.hull_down_min_frac", 0.05) * 100.0,
	])
	# As a fraction of the map's width, which is what `evaluate` actually gates on. This printed an
	# absolute "target 2-6" against two config keys that do not exist, so it silently reported the
	# band superseded by decision 0009 while the real gate was something else entirely.
	print("  %-14s %6d     (%.1f%% of width, target %.1f-%.1f%%)" % [
		"chokepoints", int(m["chokepoints"]), float(m["chokepoint_frac"]) * 100.0,
		cfg.f("metrics.chokepoint_frac_min", 0.05) * 100.0,
		cfg.f("metrics.chokepoint_frac_max", 0.22) * 100.0,
	])
	print("  %-14s %6.1f %%  (elevation %.1f%%, hull-down ground %.1f%%, limit %.1f%%)" % [
		"imbalance", float(bal["worst_pct"]), float(bal["elev_diff_pct"]),
		float(bal["hull_diff_pct"]), cfg.f("metrics.zone_balance_max_pct", 15.0),
	])
	print("  %-14s %6.1f %%  (target %.1f-%.1f%%)" % [
		"escarpment", float(m["escarpment_frac"]) * 100.0,
		cfg.f("metrics.escarpment_frac_min", 0.03) * 100.0,
		cfg.f("metrics.escarpment_frac_max", 0.15) * 100.0,
	])
	print("  %-14s %6.1f %%" % ["drivable", float(m["passable_frac"]) * 100.0])
	var riv: Dictionary = m["rivers"]
	# Only a target where the water actually divides the map — see decision 0018.
	if bool(riv["spans_map"]):
		print("  %-14s %6d     (target %d-%d, river divides the map)" % [
			"crossings", int(riv["crossings"]),
			cfg.i("metrics.river_crossings_min", 2), cfg.i("metrics.river_crossings_max", 4),
		])
	else:
		print("  %-14s %6d     (%d river tiles, not a barrier on this seed)" % [
			"crossings", int(riv["crossings"]), int(riv["river_tiles"]),
		])
	print("")

	if bool(m["pass"]):
		print("  PASS  (%s)" % Cli.fmt_secs(int(m["elapsed_usec"])))
	else:
		print("  FAIL  (%s)" % Cli.fmt_secs(int(m["elapsed_usec"])))
		for f: String in m["failures"]:
			print("    - %s" % f)


## Flat, JSON-safe view for the batch tool to collate. Drops the per-tile flag buffer.
func _summary(m: Dictionary) -> Dictionary:
	var sight: Dictionary = m["sightline"]
	var hull: Dictionary = m["hull_down"]
	var bal: Dictionary = m["balance"]
	return {
		"seed": int(m["seed"]),
		"pass": bool(m["pass"]),
		"failures": Array(m["failures"]),
		"sightline_median_m": float(sight["ray_median_m"]),
		"sightline_q1_m": float(sight["ray_q1_m"]),
		"sightline_q3_m": float(sight["ray_q3_m"]),
		"sightline_pair_median_m": float(sight["pair_median_m"]),
		"hull_down_frac": float(hull["fraction"]),
		"chokepoints": int(m["chokepoints"]),
		"imbalance_pct": float(bal["worst_pct"]),
		"escarpment_frac": float(m["escarpment_frac"]),
		"passable_frac": float(m["passable_frac"]),
		"river_crossings": int(m["river_crossings"]),
		"river_spans_map": bool(m["river_spans_map"]),
	}
