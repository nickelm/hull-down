class_name MovementClass
extends RefCounted

## How a thing gets across ground.
##
## Terrain does not have *a* movement cost — it has one per kind of vehicle. A marsh is slow for a
## tank, impossible for a lorry and merely wet for infantry, and the traversal graph has to be able
## to say so without every caller hardcoding "can a tank go here".
##
## Iteration 1 fields tracked vehicles and nothing else. The other three exist so the graph, the
## repair pass and the metrics are already parameterized: retrofitting a class dimension later would
## mean touching pathfinding, the reachability fill, the connectivity repair and the chokepoint
## min-cut all at once, which is the sort of change that is cheap now and miserable later.
##
## Indices into `movement_classes` in data/terrain.json. The order is the file's order and is
## load-bearing, exactly as `TerrainTyper.Type` is against `types`.
enum Kind { TRACKED = 0, WHEELED = 1, FOOT = 2, AMPHIBIOUS = 3 }

## The class every consumer means when it does not say. `MapData.move_cost` holds this class's row,
## `md.is_passable` answers for it, and the generator guarantees connectivity for it — because it is
## the only class iteration 1 actually fields.
const REFERENCE := Kind.TRACKED
