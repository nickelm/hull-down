extends SceneTree

## Generate a map headlessly.
##
##   godot --headless --path . --script res://tools/generate_map.gd -- --seed 12345 --dump-png
##
## Options:
##   --seed N        master seed (default 12345)
##   --small         quarter-scale pipeline, seconds instead of minutes
##   --dump-png      write diagnostic images to dumps/
##   --out PATH      write the finished map (once MapCodec exists in 4.6)
##   --quiet         suppress per-stage progress

const DUMP_DIR := "res://dumps"


func _initialize() -> void:
	var cli := Cli.from_os()
	var master_seed: int = cli.int_opt("seed", 12345)
	var quiet: bool = cli.flag("quiet")
	var dump: bool = cli.flag("dump-png")

	var cfg := Config.load_default()
	var p: MapGenerator.Params = (
		MapGenerator.Params.small(cfg) if cli.flag("small")
		else MapGenerator.Params.from_config(cfg)
	)
	# Overrides for tuning runs. --hf-size keeps the map 2 km across by scaling the cell size, so
	# every threshold expressed in metres stays comparable between sizes.
	if cli.has("hf-size"):
		var span: float = float(p.hf_size) * p.hf_cell_m
		p.hf_size = cli.int_opt("hf-size", p.hf_size)
		p.hf_cell_m = span / float(p.hf_size)
	if cli.has("droplets"):
		p.droplets = cli.int_opt("droplets", p.droplets)

	# Relief dials, overridable so a tuning sweep can run several configurations side by side
	# without editing data/rules.json between them. Anything set here is reported below, so a run's
	# output always says what produced it.
	var overrides: Array[String] = []
	if cli.has("relief"):
		cfg.rules["world"]["target_relief_m"] = cli.float_opt("relief", 0.0)
		overrides.append("relief %.0f m" % float(cfg.rules["world"]["target_relief_m"]))
	if cli.has("octaves"):
		cfg.rules["relief"]["octaves"] = cli.int_opt("octaves", 5)
		overrides.append("octaves %d" % int(cfg.rules["relief"]["octaves"]))
	if cli.has("h-exp"):
		cfg.rules["relief"]["h_exp"] = cli.float_opt("h-exp", 0.45)
		overrides.append("h_exp %.2f" % float(cfg.rules["relief"]["h_exp"]))
	if cli.has("gain"):
		cfg.rules["relief"]["gain"] = cli.float_opt("gain", 1.9)
		overrides.append("gain %.2f" % float(cfg.rules["relief"]["gain"]))
	if cli.has("carve"):
		cfg.rules["hydrology"]["max_carve_depth_m"] = cli.float_opt("carve", 2.5)
		overrides.append("carve %.1f m" % float(cfg.rules["hydrology"]["max_carve_depth_m"]))
	if cli.has("repose"):
		cfg.rules["erosion"]["thermal"]["repose_deg"] = cli.float_opt("repose", 34.0)
		overrides.append("repose %.0f deg" % float(cfg.rules["erosion"]["thermal"]["repose_deg"]))

	print("Hull Down — map generation")
	if not overrides.is_empty():
		print("  OVERRIDES   %s" % ", ".join(overrides))
	print("  seed        %d" % master_seed)
	print("  heightfield %d x %d at %.2f m  (%.0f m square)"
		% [p.hf_size, p.hf_size, p.hf_cell_m, float(p.hf_size) * p.hf_cell_m])
	print("  grid        %d x %d" % [p.grid_size, p.grid_size])
	print("  droplets    %d" % p.droplets)
	print("")

	var progress: Callable = Callable() if quiet else Cli.printer()
	var stats: Dictionary = {}
	var t0: int = Time.get_ticks_usec()
	var md: MapData = MapGenerator.generate(cfg, master_seed, p, progress, stats)
	var elapsed: int = Time.get_ticks_usec() - t0
	var field: HeightField = stats["field"]

	var mm: Vector2 = field.min_max()
	print("")
	print("  relief      %.1f m to %.1f m  (span %.1f m)" % [mm.x, mm.y, mm.y - mm.x])
	print("  max step    %.2f m between adjacent cells" % field.max_gradient())

	if stats.has("hydraulic"):
		var hy: Dictionary = stats["hydraulic"]
		print("  hydraulic   %d droplets in %s, mass drift %.3f%%"
			% [int(hy["droplets"]), Cli.fmt_secs(int(hy["elapsed_usec"])), float(hy["drift_pct"])])

	if stats.has("thermal"):
		var th: Dictionary = stats["thermal"]
		print("  thermal     %d passes in %s%s, mass drift %.3f%%"
			% [
				int(th["passes"]), Cli.fmt_secs(int(th["elapsed_usec"])),
				"" if bool(th["converged"]) else " (HIT THE PASS CAP)", float(th["drift_pct"]),
			])
		print("              slope %.3f -> %.3f, limit %.3f (%.0f deg), max step %.2f m"
			% [
				float(th["slope_before"]), float(th["slope_after"]), float(th["slope_limit"]),
				float(th["repose_deg"]), float(th["max_step_after_m"]),
			])

	var hydro: Hydrology.Result = null
	if stats.has("hydrology"):
		hydro = stats["hydrology"]
		var cells: int = p.hf_size * p.hf_size
		print("  hydrology   %s, %d cells raised by depression fill"
			% [Cli.fmt_secs(hydro.elapsed_usec), hydro.filled_cells])
		print("              %d stream cells, %d river cells (%.1f%% of the map)"
			% [
				hydro.stream_cells, hydro.river_cells,
				float(hydro.stream_cells + hydro.river_cells) / float(cells) * 100.0,
			])
		print("              %d fords (%d needed easing)" % [hydro.ford_count, hydro.forced_fords])

	if stats.has("connectivity"):
		var cn: Dictionary = stats["connectivity"]
		print("  connect     %s after %d repair passes, %d edges cut%s"
			% [
				"connected" if bool(cn["connected"]) else "NOT CONNECTED",
				int(cn["passes"]), int(cn["edits"]),
				"" if str(cn["reason"]) == "" else " — " + str(cn["reason"]),
			])

	if md == null:
		print("")
		print("  REJECTED: this seed could not be repaired into a connected map.")
		quit(1)
		return

	print("  map         %d x %d tiles, %d objectives" % [md.size, md.size, md.objectives.size()])
	print("  escarpment  %.1f%% of edges impassable (target %.0f-%.0f%%), %.1f%% of tiles drivable"
		% [
			md.escarpment_fraction() * 100.0,
			cfg.f("metrics.escarpment_frac_min", 0.03) * 100.0,
			cfg.f("metrics.escarpment_frac_max", 0.15) * 100.0,
			md.passable_fraction() * 100.0,
		])
	# How folded the ground is, as opposed to how much of it is a wall — docs/decisions/0013.
	# escarpment_fraction counts only the edges a tank cannot cross, so it reports a flat map and a
	# gently folded one identically, and "the terrain is boring" needs its own number.
	var variety: Dictionary = MapMetrics.relief_variety(md)
	print("  relief var  %.2f quanta per edge (%.2f m), %.1f%% of edges flat, span %d quanta"
		% [
			float(variety["mean_abs_dl"]), float(variety["mean_abs_dl"]) * md.quant,
			float(variety["flat_edge_frac"]) * 100.0, int(variety["level_span"]),
		])
	if stats.has("roads"):
		var roads: Array = stats["roads"]
		var parts := PackedStringArray()
		for k: int in roads.size():
			var road: RoadBuilder.Road = roads[k]
			var bridges: int = 0
			for b: int in road.is_bridge.size():
				bridges += int(road.is_bridge[b])
			parts.append("%d tiles / max step %.1f m / %d bridges"
				% [
					road.length(),
					float(RoadBuilder.max_gradient_dl(md, road)) * md.quant,
					bridges,
				])
		print("  roads       %d built: %s" % [roads.size(), "; ".join(parts)])
		print("              gradient limit %.1f m per tile"
			% (float(cfg.i("roads.max_road_dl", 2)) * md.quant))
	if stats.has("villages"):
		print("  villages    %d" % int(stats["villages"]))

	_print_edge_histogram(md)
	_print_terrain_mix(md, cfg)
	print("  hash        %s" % md.content_hash().substr(0, 16))
	print("  elapsed     %s" % Cli.fmt_secs(elapsed))

	var out_path: String = cli.str_opt("out", "")
	if out_path != "":
		var err: Error = MapCodec.save(md, out_path)
		print("  saved       %s%s" % [out_path, "" if err == OK else " FAILED (%d)" % err])

	if dump:
		Cli.ensure_dir(DUMP_DIR + "/x")
		var stem: String = "%s/seed_%d%s" % [DUMP_DIR, master_seed, "_small" if cli.flag("small") else ""]
		var shaded: Error = field.save_png(stem + "_relief.png", true)
		var raw: Error = field.save_png(stem + "_height.png", false)
		if shaded == OK and raw == OK:
			print("  dumped      %s_relief.png (hillshaded), %s_height.png (raw)" % [stem, stem])
		else:
			print("  dump FAILED (%d / %d)" % [shaded, raw])

		if hydro != null:
			var img: Image = field.to_shaded_image()
			_paint_water(img, field, hydro)
			if img.save_png(stem + "_water.png") == OK:
				print("  dumped      %s_water.png (drainage network over the relief)" % stem)

		if _dump_tiles(md, cfg, stem + "_tiles.png") == OK:
			print("  dumped      %s_tiles.png (terrain types, zones, objectives)" % stem)

	quit(0)


## The gameplay map as the rules see it: terrain colours from terrain.json, escarpment edges picked
## out in black, deployment zones tinted, objectives marked. This is the view that answers 4.6 and
## 4.7 — whether woods cluster in the valleys, and whether the zones landed on sane ground.
func _dump_tiles(md: MapData, cfg: Config, path: String) -> Error:
	var scale: int = maxi(1024 / md.size, 1)
	var w: int = md.size * scale
	var img: Image = Image.create_empty(w, w, false, Image.FORMAT_RGB8)

	for y: int in md.size:
		for x: int in md.size:
			var i: int = md.idx(x, y)
			var col: Color = cfg.terrain_colours[int(md.terrain[i])]

			# Shade by elevation so relief is still readable through the type colours.
			col = col.lerp(Color.WHITE, clampf(float(md.level[i]) * md.quant / 260.0, 0.0, 0.5))

			# Roads are a layer over the terrain rather than a type of it, so they have to be drawn
			# on top or they vanish from this diagnostic entirely.
			if md.has_road(i):
				col = col.lerp(cfg.terrain_colours[TerrainTyper.Type.ROAD], 0.75)

			var zone: int = int(md.deploy_zone[i])
			if zone == 1:
				col = col.lerp(Color(0.2, 0.5, 1.0), 0.35)
			elif zone == 2:
				col = col.lerp(Color(1.0, 0.35, 0.2), 0.35)

			for oy: int in scale:
				for ox: int in scale:
					img.set_pixel(x * scale + ox, y * scale + oy, col)

			# Impassable edges drawn on the tile's own east and south borders.
			if scale >= 2:
				if md.transition(i, Grid.E) >= MapData.Trans.BLOCKED and x < md.size - 1:
					for oy2: int in scale:
						img.set_pixel(x * scale + scale - 1, y * scale + oy2, Color.BLACK)
				if md.transition(i, Grid.S) >= MapData.Trans.BLOCKED and y < md.size - 1:
					for ox2: int in scale:
						img.set_pixel(x * scale + ox2, y * scale + scale - 1, Color.BLACK)

	for k: int in md.objectives.size():
		var o: int = md.objectives[k]
		var ox3: int = md.tx(o) * scale
		var oy3: int = md.ty(o) * scale
		for dy: int in range(-scale * 2, scale * 2 + 1):
			for dx: int in range(-scale * 2, scale * 2 + 1):
				var px: int = ox3 + dx
				var py: int = oy3 + dy
				if px >= 0 and px < w and py >= 0 and py < w:
					if absi(dx) + absi(dy) <= scale * 2:
						img.set_pixel(px, py, Color(1.0, 1.0, 0.1))

	return img.save_png(path)


## Distribution of tile-to-tile height differences, in quanta. Says *why* the escarpment fraction is
## what it is: broad steep hillsides and narrow river banks produce the same headline number and
## need opposite fixes.
func _print_edge_histogram(md: MapData) -> void:
	var buckets := PackedInt32Array()
	buckets.resize(6)
	var total: int = 0
	var wet_blocked: int = 0
	var blocked: int = 0

	for i: int in md.n:
		var x: int = i % md.size
		var y: int = i / md.size
		for slot: int in 4:
			var d: int = Grid.CANON[slot]
			var nx: int = x + Grid.DX[d]
			var ny: int = y + Grid.DY[d]
			if nx < 0 or nx >= md.size or ny < 0 or ny >= md.size:
				continue
			var nb: int = ny * md.size + nx
			var dl: int = absi(md.level[nb] - md.level[i])
			total += 1
			if dl <= 2:
				buckets[0] += 1
			elif dl <= 4:
				buckets[1] += 1
			elif dl <= 8:
				buckets[2] += 1
			elif dl <= 16:
				buckets[3] += 1
			elif dl <= 32:
				buckets[4] += 1
			else:
				buckets[5] += 1
			if dl > 4:
				blocked += 1
				# Is this edge next to water? River carving cuts metres in a single tile, so a
				# bank is an escarpment by construction and needs a different remedy from a
				# hillside that is simply too steep.
				if (
					md.water[i] != MapData.Water.NONE
					or md.water[nb] != MapData.Water.NONE
				):
					wet_blocked += 1

	var labels := ["0-2 (normal)", "3-4 (rough)", "5-8", "9-16", "17-32", "33+"]
	var parts := PackedStringArray()
	for k: int in buckets.size():
		parts.append("%s %.1f%%" % [labels[k], float(buckets[k]) / float(total) * 100.0])
	print("  edge steps  %s" % ", ".join(parts))
	if blocked > 0:
		print("              %.0f%% of impassable edges touch water"
			% (float(wet_blocked) / float(blocked) * 100.0))


func _print_terrain_mix(md: MapData, cfg: Config) -> void:
	var counts := PackedInt32Array()
	counts.resize(cfg.type_count())
	for i: int in md.n:
		counts[int(md.terrain[i])] += 1

	var parts := PackedStringArray()
	for k: int in counts.size():
		if counts[k] == 0:
			continue
		parts.append("%s %.1f%%" % [cfg.terrain_names[k], float(counts[k]) / float(md.n) * 100.0])
	print("  terrain     %s" % ", ".join(parts))


## Paint the drainage network over a hillshade. This is the view that actually answers 4.5 — a
## river with a break in it or a lake where a channel should be is obvious here and invisible in a
## plain relief dump.
func _paint_water(img: Image, field: HeightField, hydro: Hydrology.Result) -> void:
	var stream := Color(0.36, 0.60, 0.78)
	var river := Color(0.16, 0.38, 0.62)
	var ford := Color(1.0, 0.85, 0.25)

	for y: int in field.h:
		for x: int in field.w:
			var i: int = y * field.w + x
			var ch: int = int(hydro.channel[i])
			if ch == Hydrology.Channel.NONE:
				continue
			img.set_pixel(x, y, river if ch == Hydrology.Channel.RIVER else stream)

	# Fords last and fattened, so a single cell is actually visible at map scale.
	for i2: int in hydro.ford.size():
		if hydro.ford[i2] == 0:
			continue
		var fx: int = i2 % field.w
		var fy: int = i2 / field.w
		for oy: int in range(maxi(fy - 2, 0), mini(fy + 3, field.h)):
			for ox: int in range(maxi(fx - 2, 0), mini(fx + 3, field.w)):
				img.set_pixel(ox, oy, ford)
