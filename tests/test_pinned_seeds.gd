extends TestCase

## The regression seeds in `data/pinned_seeds.json`.
##
## This is the first thing that has ever read that file. It sat empty since it was created, with a
## comment explaining that it existed so a later generator change would show up as a metric diff —
## a purpose an empty list serves not at all.
##
## What is asserted here is the file's *shape*, not the maps. Regenerating five full-size maps costs
## minutes and belongs in `tools/gen_batch.gd`, not in a suite that has to stay under two minutes.
## The value of these assertions is that a generator change which invalidates the pinned metrics —
## a new terrain type, a new movement class, a metric that stops being emitted — fails here rather
## than being noticed months later when someone wonders why the numbers look odd.

const PATH := "res://data/pinned_seeds.json"

## Every metric key `tools/pin_seeds.gd` records. A metric that stops being emitted, or is renamed,
## silently makes a pinned entry undiffable against a future run.
const REQUIRED_METRICS: Array[String] = [
	"sightline_median_m", "hull_down_frac", "chokepoints", "imbalance_pct",
	"escarpment_frac", "passable_frac", "river_crossings",
]

var cfg: Config
var doc: Dictionary


func setup() -> void:
	cfg = Config.load_default()
	var text: String = FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(text)
	doc = parsed as Dictionary if typeof(parsed) == TYPE_DICTIONARY else {}


func test_the_file_is_populated() -> void:
	assert_false(doc.is_empty(), "pinned_seeds.json did not parse as an object")
	if doc.is_empty():
		return
	var seeds: Array = doc.get("seeds", []) as Array
	assert_eq(seeds.size(), 5,
		"decision 0006 asks for five regression maps, found %d" % seeds.size())


## Recorded because float behavior is not guaranteed bit-stable across Godot releases — a pinned
## metric measured on another engine build is not comparable. See decision 0010.
func test_the_engine_version_is_recorded() -> void:
	var v: String = str(doc.get("engine_version", ""))
	assert_ne(v, "", "no engine version recorded against the pinned metrics")
	assert_ne(v, "<null>", "engine version is null — the seeds were never actually pinned")


## Every entry carries its measurements, and its failures where it has them.
##
## A pinned seed does **not** have to pass. The file exists to detect drift, and it detects drift
## just as well from a seed that misses a target — provided the miss is written down, so nobody
## later reads a stale number as a passing one.
func test_every_entry_carries_its_measurements() -> void:
	var seeds: Array = doc.get("seeds", []) as Array
	for k: int in seeds.size():
		var e: Dictionary = seeds[k] as Dictionary
		assert_true(e.has("seed"), "pinned entry %d has no seed" % k)
		assert_true(e.has("name"), "pinned entry %d has no name" % k)
		assert_true(e.has("pass"), "pinned entry %d does not say whether it passed" % k)

		var m: Dictionary = e.get("metrics", {}) as Dictionary
		for key: String in REQUIRED_METRICS:
			assert_true(m.has(key),
				"pinned seed %s is missing metric '%s'" % [str(e.get("seed", "?")), key])

		# A failing seed must say why, or the record is a number with no context.
		if not bool(e.get("pass", false)):
			assert_gt(float((e.get("failures", []) as Array).size()), 0.0,
				"pinned seed %s is marked failing but records no failures"
					% str(e.get("seed", "?")))


func test_the_seeds_are_distinct() -> void:
	var seeds: Array = doc.get("seeds", []) as Array
	var seen := {}
	for e: Dictionary in seeds:
		var s: int = int(e.get("seed", -1))
		assert_false(seen.has(s), "seed %d is pinned twice" % s)
		seen[s] = true


## The metrics were measured against a particular terrain table. Adding a type or a movement class
## changes what the generator builds, so the pinned numbers stop being comparable and the seeds want
## re-pinning — which is exactly the event this catches.
func test_the_data_shape_matches_what_was_pinned() -> void:
	assert_eq(int(doc.get("terrain_types", -1)), cfg.type_count(),
		"terrain.json has gained or lost a type since these seeds were pinned — re-run tools/pin_seeds.gd")
	assert_eq(int(doc.get("movement_classes", -1)), cfg.class_count(),
		"terrain.json has gained or lost a movement class since these seeds were pinned")
