extends SceneTree

## Generate and measure many maps, then report which pass.
##
##   godot --headless --path . --script res://tools/gen_batch.gd -- --count 20
##
## This is the generate-measure-reject loop from 4.11. Its output is two things: the pass rate,
## which says whether the targets are achievable at all, and the distribution of each metric, which
## says *which* target is wrong when they are not.
##
## Work is fanned out across cores with OS.create_process, because twenty full-size maps run
## serially is the better part of an hour. Erosion is deliberately not cheapened for the batch —
## erosion is what drives the sightline and hull-down numbers, so a cheap batch would select seeds
## that fail at full quality.

const OUT_DIR := "res://dumps/batch"


func _initialize() -> void:
	var cli := Cli.from_os()
	var count: int = cli.int_opt("count", 20)
	var first: int = cli.int_opt("first-seed", 1000)
	var hf_size: int = cli.int_opt("hf-size", 0)
	var droplets: int = cli.int_opt("droplets", 0)
	var workers: int = cli.int_opt("workers", maxi(OS.get_processor_count() - 2, 1))

	Cli.ensure_dir(OUT_DIR + "/x")

	print("Hull Down — batch of %d maps on %d workers" % [count, workers])
	if hf_size > 0:
		print("  reduced heightfield %d (tuning run, not a shipping measurement)" % hf_size)
	print("")

	var exe: String = OS.get_executable_path()
	var project: String = ProjectSettings.globalize_path("res://")
	var results: Array = []
	var running: Array = []
	var next_seed: int = first
	var issued: int = 0
	var t0: int = Time.get_ticks_usec()

	while results.size() < count:
		# Top the pool back up.
		while running.size() < workers and issued < count:
			var master_seed: int = next_seed
			next_seed += 1
			issued += 1
			var out_path: String = "%s/seed_%d.json" % [OUT_DIR, master_seed]
			var args := PackedStringArray([
				"--headless", "--path", project,
				"--script", "res://tools/_batch_one.gd", "--",
				"--seed", str(master_seed), "--out", out_path,
			])
			if hf_size > 0:
				args.append_array(PackedStringArray(["--hf-size", str(hf_size)]))
			if droplets > 0:
				args.append_array(PackedStringArray(["--droplets", str(droplets)]))
			var pid: int = OS.create_process(exe, args)
			if pid <= 0:
				print("  failed to launch a worker for seed %d" % master_seed)
				results.append({"seed": master_seed, "pass": false, "failures": ["launch failed"]})
				continue
			running.append({"pid": pid, "seed": master_seed, "path": out_path})

		if running.is_empty():
			break

		# Poll. A worker writes its JSON and exits; nothing here parses partial output.
		var still: Array = []
		for job: Dictionary in running:
			if OS.is_process_running(int(job["pid"])):
				still.append(job)
				continue
			var r: Dictionary = _read_result(str(job["path"]), int(job["seed"]))
			results.append(r)
			_print_row(r)
		running = still
		OS.delay_msec(200)

	_summarise(results, Time.get_ticks_usec() - t0)
	quit(0)


func _read_result(path: String, master_seed: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"seed": master_seed, "pass": false, "failures": ["worker produced no output"]}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"seed": master_seed, "pass": false, "failures": ["unreadable output"]}
	return parsed


func _print_row(r: Dictionary) -> void:
	if not r.has("sightline_median_m"):
		print("  seed %-6d  REJECTED  %s" % [int(r["seed"]), ", ".join(_failures(r))])
		return
	print("  seed %-6d  %s  sight %4.0f m  hull %4.1f%%  choke %2d  imbal %4.1f%%  esc %4.1f%%  dl %4.2f  flat %4.1f%%  span %3d" % [
		int(r["seed"]), "pass" if bool(r["pass"]) else "FAIL",
		float(r["sightline_median_m"]), float(r["hull_down_frac"]) * 100.0,
		int(r["chokepoints"]), float(r["imbalance_pct"]), float(r["escarpment_frac"]) * 100.0,
		float(r.get("mean_abs_dl", 0.0)), float(r.get("flat_edge_frac", 0.0)) * 100.0,
		int(r.get("level_span", 0)),
	])


func _failures(r: Dictionary) -> Array:
	return r["failures"] if r.has("failures") else []


## The distribution matters more than the pass rate. If every seed misses the same target by the
## same margin, the target is wrong; if they scatter across it, the generator is.
func _summarise(results: Array, elapsed: int) -> void:
	var passed: Array = []
	for r: Dictionary in results:
		if bool(r.get("pass", false)):
			passed.append(r)

	print("")
	print("  %d of %d passed  (%s)" % [passed.size(), results.size(), Cli.fmt_secs(elapsed)])

	var keys := {
		"sightline_median_m": "sightline m",
		"hull_down_frac": "hull-down frac",
		"chokepoints": "chokepoints",
		"imbalance_pct": "imbalance %",
		"escarpment_frac": "escarpment frac",
		"passable_frac": "passable frac",
		"mean_abs_dl": "relief dl quanta",
		"flat_edge_frac": "flat edge frac",
		"level_span": "level span",
	}
	print("")
	print("  metric            min    median       max")
	for key: String in keys:
		var vals := PackedFloat32Array()
		for r2: Dictionary in results:
			if r2.has(key):
				vals.append(float(r2[key]))
		if vals.is_empty():
			continue
		vals.sort()
		print("  %-16s %6.2f  %8.2f  %8.2f" % [
			keys[key], vals[0], vals[vals.size() / 2], vals[vals.size() - 1],
		])

	# Which target is doing the rejecting.
	var tally := {}
	for r3: Dictionary in results:
		for f: Variant in _failures(r3):
			var head: String = str(f).split(" ")[0]
			tally[head] = int(tally.get(head, 0)) + 1
	if not tally.is_empty():
		print("")
		print("  rejected by:")
		var names: Array = tally.keys()
		names.sort()
		for k: String in names:
			print("    %-14s %d" % [k, int(tally[k])])

	if passed.size() > 0:
		print("")
		print("  passing seeds: %s" % ", ".join(_seed_list(passed)))


func _seed_list(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for r: Dictionary in rows:
		out.append(str(int(r["seed"])))
	return out
