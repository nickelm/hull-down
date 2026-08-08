class_name Cli
extends RefCounted

## Argument parsing for the headless tools in tools/.
##
## Godot swallows its own arguments; everything after a bare `--` arrives via
## OS.get_cmdline_user_args(). So the invocation is always:
##
##   godot --headless --path <project> --script res://tools/<tool>.gd -- --seed 12345 --dump-png

var _values: Dictionary = {}
var _flags: Dictionary = {}


static func parse(argv: PackedStringArray) -> Cli:
	var c := Cli.new()
	var k: int = 0
	while k < argv.size():
		var a: String = argv[k]
		if not a.begins_with("--"):
			k += 1
			continue
		var key: String = a.substr(2)
		if k + 1 < argv.size() and not argv[k + 1].begins_with("--"):
			c._values[key] = argv[k + 1]
			k += 2
		else:
			c._flags[key] = true
			k += 1
	return c


static func from_os() -> Cli:
	return parse(OS.get_cmdline_user_args())


func has(key: String) -> bool:
	return _values.has(key) or _flags.has(key)


func flag(key: String) -> bool:
	return _flags.has(key) or (_values.has(key) and str(_values[key]) == "true")


func str_opt(key: String, default_value: String) -> String:
	return str(_values[key]) if _values.has(key) else default_value


func int_opt(key: String, default_value: int) -> int:
	return int(str(_values[key])) if _values.has(key) else default_value


func float_opt(key: String, default_value: float) -> float:
	return float(str(_values[key])) if _values.has(key) else default_value


## Ensure a directory exists for a res:// or user:// path before writing into it.
static func ensure_dir(path: String) -> void:
	var dir: String = path.get_base_dir()
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))


## A progress callback that prints one line per stage step. Passed into the generation stages so a
## multi-minute run shows signs of life.
static func printer() -> Callable:
	return func(stage: String, t: float) -> void:
		print("  [%-10s] %3d%%" % [stage, int(t * 100.0)])


static func fmt_secs(usec: int) -> String:
	return "%.1f s" % (float(usec) / 1_000_000.0)
