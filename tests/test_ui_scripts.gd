extends TestCase

## The UI layer cannot be exercised headlessly — a CanvasLayer needs a viewport — but the failure
## mode that actually bites is cheaper than that: a script that fails to parse still comes back from
## `load()` as a GDScript, just one that cannot be instantiated, and calling `new()` on it aborts
## the caller silently (see CLAUDE.md). This walks every script in `game/` and asserts each one
## compiles, which turns a typo in the HUD from a blank window at runtime into a named test failure.

const GAME_DIRS: Array[String] = [
	"res://game",
	"res://game/actions",
	"res://game/camera",
	"res://game/input",
	"res://game/ui",
	"res://game/units",
	"res://game/world",
]


func test_game_scripts_compile() -> void:
	var checked: int = 0
	for dir: String in GAME_DIRS:
		for f: String in DirAccess.get_files_at(dir):
			if not f.ends_with(".gd"):
				continue
			var path: String = dir + "/" + f
			var gd := load(path) as GDScript
			assert_true(
				gd != null and gd.can_instantiate(),
				"%s failed to compile (see the parse errors above)" % path
			)
			checked += 1
	assert_true(checked > 0, "found no scripts under game/ — the directory walk is broken")
