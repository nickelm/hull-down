extends SceneTree

## One map, generated and measured, result written as JSON. Spawned by tools/gen_batch.gd, one per
## worker process — a separate entry point rather than a flag on generate_map.gd so a worker that
## dies takes nothing with it but its own row.


func _initialize() -> void:
	var cli := Cli.from_os()
	var master_seed: int = cli.int_opt("seed", 1)
	var out_path: String = cli.str_opt("out", "")
	var cfg := Config.load_default()

	var p: MapGenerator.Params = MapGenerator.Params.from_config(cfg)
	if cli.has("hf-size"):
		var span: float = float(p.hf_size) * p.hf_cell_m
		p.hf_size = cli.int_opt("hf-size", p.hf_size)
		p.hf_cell_m = span / float(p.hf_size)
	if cli.has("droplets"):
		p.droplets = cli.int_opt("droplets", p.droplets)

	var result: Dictionary
	var md: MapData = MapGenerator.generate(cfg, master_seed, p)
	if md == null:
		result = {
			"seed": master_seed,
			"pass": false,
			"failures": ["seed could not be repaired into a connected map"],
		}
	else:
		var m: Dictionary = MapMetrics.evaluate(md, cfg, master_seed)
		var sight: Dictionary = m["sightline"]
		var hull: Dictionary = m["hull_down"]
		var bal: Dictionary = m["balance"]
		result = {
			"seed": master_seed,
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
			"mean_abs_dl": float(m["mean_abs_dl"]),
			"flat_edge_frac": float(m["flat_edge_frac"]),
			"level_span": int(m["level_span"]),
		}

	if out_path != "":
		Cli.ensure_dir(out_path)
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(result))
			f.close()

	quit(0)
