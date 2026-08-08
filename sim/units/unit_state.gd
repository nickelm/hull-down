class_name UnitState
extends RefCounted

## A unit as the simulation sees it: where it is, which way it points, and what it has left.
## No rendering, no node, no animation — the view in game/ reads this and follows it.

var tile: int = 0
var facing: int = Grid.N
var unit_type: StringName = &"medium"
var mp_max: int = 220
var mp_left: int = 220
var side: int = 1
## Whether this unit has already acted this turn. Advisory in iteration 1 — it drives the "who has
## not acted" indicator and the order Tab cycles in, and nothing else. The two-actions-per-unit
## budget from docs/decisions/0003 arrives with combat in iteration 2.
var activated: bool = false


static func create(md: MapData, cfg: Config, start_tile: int, type_name: String) -> UnitState:
	var u := UnitState.new()
	u.tile = start_tile
	u.unit_type = StringName(type_name)

	var data: Dictionary = cfg.unit(type_name)
	var move: Dictionary = data.get("movement", {})
	u.mp_max = int(move.get("mp", cfg.i("movement.default_mp", 220)))
	u.mp_left = u.mp_max
	return u


func begin_turn() -> void:
	mp_left = mp_max
	activated = false


## Whether the unit can still do anything. A unit that cannot afford even the cheapest step is done
## whether or not it has been marked, so this is what the turn tracking actually asks.
func can_act(cfg: Config) -> bool:
	return not activated and mp_left >= cfg.i("movement.base_ortho", 10)


## Apply a committed path. Facing follows the route, and movement points are spent.
func apply(path: PathResult) -> void:
	if not path.found or path.length() == 0:
		return
	tile = path.destination()
	facing = path.final_facing()
	mp_left = maxi(mp_left - path.cost, 0)


func turret_height_m(cfg: Config) -> float:
	var dims: Dictionary = cfg.unit(String(unit_type)).get("dimensions", {})
	return float(dims.get("turret_h_m", cfg.f("visibility.turret_h_m", 2.6)))


func hull_height_m(cfg: Config) -> float:
	var dims: Dictionary = cfg.unit(String(unit_type)).get("dimensions", {})
	return float(dims.get("hull_h_m", cfg.f("visibility.hull_h_m", 1.4)))
