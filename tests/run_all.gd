extends SceneTree

## Headless test runner.
##
##   godot --headless --path <project> --script res://tests/run_all.gd
##   godot --headless --path <project> --script res://tests/run_all.gd -- --only test_rng
##
## Discovers tests/test_*.gd, runs every test_* method on a fresh instance, and exits nonzero if
## anything failed.
##
## A hard GDScript runtime error inside a test does not reliably set a nonzero process exit code,
## so the last line printed is always the sentinel below. A run without it did not finish, whatever
## the exit code says — treat that as failure.

const TEST_DIR := "res://tests"
const SENTINEL := "TESTS_COMPLETE"

## Excluded from discovery despite matching the test_ prefix: it is the base class, not a suite.
const NOT_A_SUITE := "test_case.gd"


func _initialize() -> void:
	var only: String = _arg("--only")
	var files: PackedStringArray = _discover(only)

	var passed: int = 0
	var failed: int = 0
	var started_us: int = Time.get_ticks_usec()

	for f: String in files:
		# A file that fails to parse still comes back from load() as a GDScript — just one that
		# cannot be instantiated. Calling new() on it aborts _initialize(), which leaves the
		# SceneTree running forever with no output. Guard before touching it.
		var gd := load(TEST_DIR + "/" + f) as GDScript
		if gd == null or not gd.can_instantiate():
			print("  ERROR %s — failed to compile (see the parse errors above)" % f)
			failed += 1
			continue

		var probe: Object = gd.new()
		if probe == null or not (probe is TestCase):
			print("  ERROR %s — does not extend TestCase" % f)
			failed += 1
			continue

		var methods: PackedStringArray = PackedStringArray()
		for m: Dictionary in probe.get_method_list():
			var mname: String = str(m["name"])
			if mname.begins_with("test_") and not methods.has(mname):
				methods.append(mname)
		methods.sort()

		if methods.is_empty():
			print("  ERROR %s — no test_* methods" % f)
			failed += 1
			continue

		for mname: String in methods:
			var tc := gd.new() as TestCase
			var t0: int = Time.get_ticks_usec()
			tc.setup()
			tc.call(mname)
			tc.teardown()
			var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

			if tc.failures.is_empty():
				passed += 1
				print("  PASS  %s::%s  (%.1f ms)" % [f, mname, ms])
			else:
				failed += 1
				print("  FAIL  %s::%s  (%.1f ms)" % [f, mname, ms])
				for msg: String in tc.failures:
					print("        " + msg)

	var total_ms: float = float(Time.get_ticks_usec() - started_us) / 1000.0
	print("")
	print("%d passed, %d failed  (%.0f ms)" % [passed, failed, total_ms])
	print(SENTINEL)
	quit(1 if failed > 0 else 0)


func _discover(only: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var names: PackedStringArray = DirAccess.get_files_at(TEST_DIR)
	names.sort()
	for f: String in names:
		if not f.begins_with("test_") or not f.ends_with(".gd"):
			continue
		if f == NOT_A_SUITE:
			continue
		if only != "" and not f.begins_with(only):
			continue
		out.append(f)
	return out


## Read `--key value` from the user args after `--`. Returns "" if absent.
func _arg(key: String) -> String:
	var argv: PackedStringArray = OS.get_cmdline_user_args()
	for k: int in argv.size():
		if argv[k] == key and k + 1 < argv.size():
			return argv[k + 1]
	return ""
