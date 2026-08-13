class_name MapGenerator
extends RefCounted

## The generation pipeline, start to finish.
##
## Stage order is load-bearing and each stage assumes the one before it ran:
##
##   4.2 base relief      tectonic bands + domain-warped ridged multifractal
##   4.3 hydraulic        droplet erosion carves valleys
##   4.4 thermal          collapses anything past the angle of repose
##   4.5 hydrology        depression fill, D8 flow, channels, fords
##   4.6 quantize         800 -> 200, 0.5 m levels, transition classes, connectivity repair
##   4.7 terrain types    cover and concealment from moisture, slope, elevation
##   4.8 roads            A* with cut and fill, bridges, villages
##
## Every stage draws from its own tagged substream (see Rng.substream), so inserting a stage never
## reshuffles the noise of the ones after it.


## Generation parameters. Kept as an object rather than a long argument list because --small mode
## overrides several of them together, and a half-overridden pipeline is a subtle bug.
class Params extends RefCounted:
	var hf_size: int = 800
	var hf_cell_m: float = 2.5
	var grid_size: int = 200
	var droplets: int = 500000

	static func from_config(cfg: Config) -> Params:
		var p := Params.new()
		p.hf_size = cfg.i("world.hf_size", 800)
		p.hf_cell_m = cfg.f("world.hf_cell_m", 2.5)
		p.grid_size = cfg.i("world.grid_size", 200)
		p.droplets = cfg.i("erosion.hydraulic.droplet_count", 500000)
		return p

	## A small pipeline for tests: same stages, same code paths, seconds instead of minutes.
	##
	## This shrinks the **world**, keeping the cell and tile sizes exactly as they ship. Stretching
	## the tiles instead would be the obvious way to make a smaller map out of the same arrays, and
	## it is wrong: a 40 m tile spans four times the ground of a 10 m one, so every tile-to-tile
	## drop quadruples and a map that ships with 7% impassable edges comes out fragmented into
	## pockets. Tests would then be running against terrain the game never produces.
	##
	## Keeping the downsample ratio identical matters for the same reason — averaging sixteen cells
	## into a tile smooths differently from averaging four.
	static func small(cfg: Config) -> Params:
		var p := Params.from_config(cfg)
		var ratio: int = maxi(p.hf_size / p.grid_size, 1)
		p.hf_size = 200
		p.grid_size = p.hf_size / ratio
		p.droplets = 25000
		return p


## Stages 4.2 to 4.5: everything that operates on the continuous heightfield.
##
## Returns the eroded field. Hydrology results are written into `out_hydrology` if supplied, since
## the quantize stage needs the flow accumulation for moisture and the channels for water tiles.
static func generate_field(
	cfg: Config, master_seed: int, p: Params, progress: Callable = Callable(),
	out_stats: Dictionary = {}
) -> HeightField:
	var field: HeightField = BaseRelief.generate(
		cfg, master_seed, p.hf_size, p.hf_size, p.hf_cell_m, progress
	)
	out_stats["hydraulic"] = HydraulicErosion.run(
		field, cfg, master_seed, p.droplets, progress
	)
	out_stats["thermal"] = ThermalErosion.run(field, cfg, progress)

	var hydro: Hydrology.Result = Hydrology.run(field, cfg, master_seed, progress)
	out_stats["hydrology"] = hydro
	return field


## The whole pipeline. Returns the gameplay map, or null if the seed could not be repaired into a
## connected one — the caller is expected to try the next seed rather than ship a broken map.
static func generate(
	cfg: Config, master_seed: int, p: MapGenerator.Params = null,
	progress: Callable = Callable(), out_stats: Dictionary = {}
) -> MapData:
	var params: MapGenerator.Params = p if p != null else Params.from_config(cfg)

	var field: HeightField = generate_field(cfg, master_seed, params, progress, out_stats)
	var hydro: Hydrology.Result = out_stats["hydrology"]
	# Kept for the diagnostic dumps; nothing in the simulation reads the heightfield after this.
	out_stats["field"] = field

	var md: MapData = Quantizer.build(field, hydro, cfg, master_seed, params.grid_size)

	# Terrain typing comes first. It is what decides which tiles are impassable, and neither "put
	# the deployment zone on good ground" nor "can this zone reach that objective" is answerable
	# before the water and the rock are known.
	TerrainTyper.assign(md, cfg, master_seed)

	ConnectivityRepair.place_zones(md, cfg, master_seed)

	# Village sites are chosen before a single road is routed, because the road network is a spanning
	# tree over them and the map edges — people settle on good ground and then build roads between
	# the places they settled, not the other way round. See docs/decisions/0019.
	var sites: PackedInt32Array = SettlementPlacer.choose_sites(md, cfg, master_seed)
	out_stats["village_sites"] = sites

	# Roads before the connectivity check, not after. Cut and fill reshapes the ground and bridges
	# make rivers crossable, so a road can be the thing that connects two halves of a map — running
	# the check first would carve an earthwork the road was about to make unnecessary.
	var roads: Array = RoadBuilder.build(md, cfg, master_seed, sites)
	out_stats["roads"] = roads

	# Stamped only now. A village flattens its footprint to a median height and the road runs
	# straight through the middle of it, so the stamp has to follow the earthworks and the road's
	# gradient has to be re-established afterwards. Only the *choosing* moved earlier.
	out_stats["villages"] = SettlementPlacer.stamp_all(md, cfg, sites)
	RoadBuilder.resmooth(md, cfg, roads)

	# Objectives are placed on the generator's features — villages, bridges, crests (2e-iii) — so
	# they cannot be chosen until the features exist. Still before the repair pass, which needs
	# them as its anchors: every deployment zone must be able to reach every objective.
	ConnectivityRepair.place_objectives(md, cfg, master_seed)

	out_stats["connectivity"] = ConnectivityRepair.repair(md, cfg)
	if not bool(out_stats["connectivity"]["connected"]):
		return null

	if progress.is_valid():
		progress.call("map", 1.0)
	return md


## Quarter-scale generation for tests: same stages and same code paths, seconds instead of minutes.
static func generate_small(cfg: Config, master_seed: int) -> MapData:
	return generate(cfg, master_seed, Params.small(cfg))
