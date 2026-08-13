class_name MapCodec
extends RefCounted

## Binary save and load for MapData.
##
## This exists because full generation costs minutes and stages 4.7 through 4.14 must not pay it on
## every run. A map is about a megabyte and loads in a millisecond, which is the difference between
## iterating on the mesh or the camera in seconds versus in minutes.
##
## The format is deliberately dumb: a header, then each layer as a length followed by its raw bytes
## via `to_byte_array()`. No compression, no field names, no forward compatibility beyond the
## version check — a map file is a cache, not an archive. If the version does not match, regenerate.

const MAGIC := 0x484D4150  # "HMAP"
## 3: objective_value appended (2e-iii). A map file is a cache — old versions regenerate.
## 4: no format change — invalidates caches generated before the connectivity guarantee
##    (`ConnectivityRepair.repair` + fords), which loads never re-validate.
const VERSION := 4


static func save(md: MapData, path: String) -> Error:
	var dir: String = path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()

	f.store_32(MAGIC)
	f.store_32(VERSION)
	f.store_64(md.master_seed)
	f.store_32(md.size)
	f.store_float(md.tile_m)
	f.store_float(md.quant)

	_write(f, md.level.to_byte_array())
	_write(f, md.terrain)
	_write(f, md.trans)
	_write(f, md.move_cost.to_byte_array())
	_write(f, md.water)
	_write(f, md.water_level.to_byte_array())
	_write(f, md.moisture.to_byte_array())
	_write(f, md.blocker_h.to_byte_array())
	_write(f, md.road_links)
	_write(f, md.deploy_zone)
	_write(f, md.objectives.to_byte_array())
	_write(f, md.objective_value.to_byte_array())

	f.close()
	return OK


static func load_map(path: String) -> MapData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("MapCodec: cannot open %s (%d)" % [path, FileAccess.get_open_error()])
		return null

	if f.get_32() != MAGIC:
		push_error("MapCodec: %s is not a Hull Down map" % path)
		return null
	var version: int = f.get_32()
	if version != VERSION:
		push_error("MapCodec: %s is version %d, this build reads %d — regenerate it"
			% [path, version, VERSION])
		return null

	var master_seed: int = f.get_64()
	var size: int = f.get_32()
	var md := MapData.create(size)
	md.master_seed = master_seed
	md.tile_m = f.get_float()
	md.quant = f.get_float()

	md.level = _read(f).to_int32_array()
	md.terrain = _read(f)
	md.trans = _read(f)
	md.move_cost = _read(f).to_int32_array()
	md.water = _read(f)
	md.water_level = _read(f).to_int32_array()
	md.moisture = _read(f).to_float32_array()
	md.blocker_h = _read(f).to_float32_array()
	md.road_links = _read(f)
	md.deploy_zone = _read(f)
	md.objectives = _read(f).to_int32_array()
	md.objective_value = _read(f).to_int32_array()

	f.close()
	return md


static func _write(f: FileAccess, bytes: PackedByteArray) -> void:
	f.store_32(bytes.size())
	if bytes.size() > 0:
		f.store_buffer(bytes)


static func _read(f: FileAccess) -> PackedByteArray:
	var count: int = f.get_32()
	if count == 0:
		return PackedByteArray()
	return f.get_buffer(count)
