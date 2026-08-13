extends SceneTree

## Pin regression seeds from a batch run.
##
##   godot --headless --path . --script res://tools/gen_batch.gd -- --count 40
##   godot --headless --path . --script res://tools/pin_seeds.gd -- --count 5
##
## Reads whatever `gen_batch` left in `dumps/batch/` and writes the best few into
## `data/pinned_seeds.json` with their measured metrics.
##
## **Pinned is not the same as passing.** The file exists so that a later generator change shows up
## as a metric diff, and that purpose is served perfectly well by a seed that fails a §4.11 target —
## and not at all by an empty list, which detects nothing. Each entry therefore records `pass` and
## the failure strings alongside the numbers, so the file is honest about where the generator stands
## rather than staying empty until every target is met.
##
## Ranked by how many targets a seed misses and then by how badly it misses the sightline band,
## which is the one currently furthest out.

const BATCH_DIR := "res://dumps/batch"
const OUT_PATH := "res://data/pinned_seeds.json"

## The five maps decision 0006 asks for, in rank order. Names are descriptive, not generated —
## whoever looks at a regression diff wants to know which map moved.
const NAMES: Array[String] = ["Ridge", "Village", "Steppe", "Chokepoint", "Sprawl"]


func _initialize() -> void:
	var cli := Cli.from_os()
	var want: int = cli.int_opt("count", 5)

	var rows: Array = _load_rows()
	if rows.is_empty():
		print("no batch results in %s — run tools/gen_batch.gd first" % BATCH_DIR)
		quit(1)
		return

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var fa: int = (a.get("failures", []) as Array).size()
		var fb: int = (b.get("failures", []) as Array).size()
		if fa != fb:
			return fa < fb
		return _sight_miss(a) < _sight_miss(b)
	)

	var cfg := Config.load_default()
	var seeds: Array = []
	for k: int in mini(want, rows.size()):
		var r: Dictionary = rows[k]
		seeds.append({
			"seed": int(r["seed"]),
			"name": NAMES[k] if k < NAMES.size() else "Seed %d" % int(r["seed"]),
			"pass": bool(r.get("pass", false)),
			"failures": Array(r.get("failures", [])),
			"metrics": {
				"sightline_median_m": float(r.get("sightline_median_m", 0.0)),
				"sightline_q1_m": float(r.get("sightline_q1_m", 0.0)),
				"sightline_q3_m": float(r.get("sightline_q3_m", 0.0)),
				"hull_down_frac": float(r.get("hull_down_frac", 0.0)),
				"chokepoints": int(r.get("chokepoints", 0)),
				"imbalance_pct": float(r.get("imbalance_pct", 0.0)),
				"escarpment_frac": float(r.get("escarpment_frac", 0.0)),
				"passable_frac": float(r.get("passable_frac", 0.0)),
				"river_crossings": int(r.get("river_crossings", 0)),
				"river_spans_map": bool(r.get("river_spans_map", false)),
			},
		})

	var doc := {
		"_comment": (
			"Regression maps, written by tools/pin_seeds.gd from a gen_batch run. Each entry records "
			+ "the metrics measured when it was pinned, so a later generator change shows up as a "
			+ "metric diff. `pass` says whether the seed met the 4.11 targets at pin time — a seed "
			+ "that fails is still worth pinning, because an empty file detects nothing. Engine "
			+ "version is recorded because float behavior is not guaranteed bit-stable across Godot "
			+ "releases — see docs/decisions/0010."
		),
		"engine_version": Engine.get_version_info()["string"],
		"terrain_types": cfg.type_count(),
		"movement_classes": cfg.class_count(),
		"seeds": seeds,
	}

	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		print("cannot write %s" % OUT_PATH)
		quit(2)
		return
	f.store_string(JSON.stringify(doc, "  ") + "\n")
	f.close()

	print("pinned %d seeds to %s" % [seeds.size(), OUT_PATH])
	for s: Dictionary in seeds:
		var m: Dictionary = s["metrics"]
		print("  %-12s seed %-6d %s  sight %4.0f m  hull %4.1f%%  choke %2d  imbal %4.1f%%" % [
			s["name"], int(s["seed"]), "pass" if bool(s["pass"]) else "FAIL",
			float(m["sightline_median_m"]), float(m["hull_down_frac"]) * 100.0,
			int(m["chokepoints"]), float(m["imbalance_pct"]),
		])
	quit(0)


## How far outside the sightline band a seed sits, in meters. Zero when inside.
func _sight_miss(r: Dictionary) -> float:
	var v: float = float(r.get("sightline_median_m", 0.0))
	return maxf(maxf(300.0 - v, v - 900.0), 0.0)


func _load_rows() -> Array:
	var out: Array = []
	var dir := DirAccess.open(BATCH_DIR)
	if dir == null:
		return out
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for name: String in names:
		if not name.ends_with(".json"):
			continue
		var text: String = FileAccess.get_file_as_string("%s/%s" % [BATCH_DIR, name])
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("seed"):
			out.append(parsed)
	return out
