class_name HeightField
extends RefCounted

## The continuous heightfield that stages 4.2 through 4.5 pass between themselves.
##
## Heights are metres in a flat PackedFloat32Array indexed y * w + x. At the shipping size — 800
## square at 2.5 m — that is 640,000 cells and 2.56 MB, contiguous, with the cheapest indexed read
## GDScript offers. An Array[Array] of the same data would be roughly 15 MB behind two levels of
## indirection, and the erosion stage alone performs hundreds of millions of accesses.
##
## Stages mutate `data` **in place**. That is deliberate: a copy per stage would be cheap in bytes
## but would break the aliasing that the hot loops depend on. Remember that PackedFloat32Array is
## copy-on-write — a local alias must be assigned back to `data` when the loop is done.

var w: int = 0
var h: int = 0
var cell_m: float = 1.0
var data: PackedFloat32Array = PackedFloat32Array()


static func create(width: int, height: int, cell: float) -> HeightField:
	var f := HeightField.new()
	f.w = width
	f.h = height
	f.cell_m = cell
	f.data.resize(width * height)
	return f


func count() -> int:
	return w * h


func idx(x: int, y: int) -> int:
	return y * w + x


func at(x: int, y: int) -> float:
	return data[y * w + x]


func set_at(x: int, y: int, v: float) -> void:
	data[y * w + x] = v


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < w and y >= 0 and y < h


func duplicate_field() -> HeightField:
	var f := HeightField.new()
	f.w = w
	f.h = h
	f.cell_m = cell_m
	f.data = data.duplicate()
	return f


## Bilinear sample in cell coordinates. Used by the erosion droplet loop for gradients; sampling
## nearest-cell instead makes droplets snap to the grid and produces axis-aligned artifacts rather
## than dendritic valleys.
func sample(fx: float, fy: float) -> float:
	var x0: int = clampi(int(fx), 0, w - 2)
	var y0: int = clampi(int(fy), 0, h - 2)
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	var i: int = y0 * w + x0
	var h00: float = data[i]
	var h10: float = data[i + 1]
	var h01: float = data[i + w]
	var h11: float = data[i + w + 1]
	return (
		h00 * (1.0 - tx) * (1.0 - ty)
		+ h10 * tx * (1.0 - ty)
		+ h01 * (1.0 - tx) * ty
		+ h11 * tx * ty
	)


## Total height summed over every cell. Erosion moves material around; it must not create or
## destroy it, and this is what the mass-conservation acceptance check compares.
func total_mass() -> float:
	var sum: float = 0.0
	for i: int in data.size():
		sum += data[i]
	return sum


func min_max() -> Vector2:
	if data.is_empty():
		return Vector2.ZERO
	var lo: float = data[0]
	var hi: float = data[0]
	for i: int in data.size():
		var v: float = data[i]
		if v < lo:
			lo = v
		elif v > hi:
			hi = v
	return Vector2(lo, hi)


## Steepest tile-to-tile height difference anywhere on the field, in metres. Used by the thermal
## erosion acceptance check.
func max_gradient() -> float:
	var worst: float = 0.0
	for y: int in h:
		var row: int = y * w
		for x: int in w:
			var i: int = row + x
			var v: float = data[i]
			if x + 1 < w:
				worst = maxf(worst, absf(data[i + 1] - v))
			if y + 1 < h:
				worst = maxf(worst, absf(data[i + w] - v))
	return worst


## Steepest slope (rise over run, dimensionless) to any of the eight neighbours. This is what the
## angle of repose is actually expressed against — max_gradient() reports a height difference,
## which is only comparable between fields of the same cell size.
func max_slope() -> float:
	var worst: float = 0.0
	var inv_ortho: float = 1.0 / cell_m
	var inv_diag: float = 1.0 / (cell_m * sqrt(2.0))
	for y: int in h:
		var row: int = y * w
		for x: int in w:
			var v: float = data[row + x]
			if x + 1 < w:
				worst = maxf(worst, absf(data[row + x + 1] - v) * inv_ortho)
			if y + 1 < h:
				worst = maxf(worst, absf(data[row + w + x] - v) * inv_ortho)
				if x + 1 < w:
					worst = maxf(worst, absf(data[row + w + x + 1] - v) * inv_diag)
				if x > 0:
					worst = maxf(worst, absf(data[row + w + x - 1] - v) * inv_diag)
	return worst


## Rescale so the field spans exactly `target` metres from lowest point to highest, keeping the
## lowest point at `floor_m`.
func normalize_to(target: float, floor_m: float) -> void:
	var mm: Vector2 = min_max()
	var span: float = mm.y - mm.x
	if span < 1e-6:
		return
	var k: float = target / span
	for i: int in data.size():
		data[i] = floor_m + (data[i] - mm.x) * k


# --- diagnostics -------------------------------------------------------------------------------
# PNG dumps for the eyeball acceptance checks in 4.2, 4.3, 4.5 and 4.7. Nothing in the simulation
# reads these; they exist so a human can tell whether the terrain is right.


## Raw greyscale, normalized across the field's own range.
func to_image() -> Image:
	var mm: Vector2 = min_max()
	var span: float = maxf(mm.y - mm.x, 1e-6)
	var bytes := PackedByteArray()
	bytes.resize(w * h)
	for i: int in data.size():
		bytes[i] = int(clampf((data[i] - mm.x) / span, 0.0, 1.0) * 255.0)
	return Image.create_from_data(w, h, false, Image.FORMAT_L8, bytes)


## Hillshaded relief with an elevation ramp.
##
## This is the view that actually answers 4.2's acceptance check. Flat greyscale hides ridge
## structure — a directional ridge system and a field of isotropic lumps look much the same in it.
## Under a low sun they do not.
func to_shaded_image(sun_azimuth_deg: float = 315.0, sun_altitude_deg: float = 32.0) -> Image:
	var mm: Vector2 = min_max()
	var span: float = maxf(mm.y - mm.x, 1e-6)

	var az: float = deg_to_rad(sun_azimuth_deg)
	var alt: float = deg_to_rad(sun_altitude_deg)
	var lx: float = cos(alt) * cos(az)
	var ly: float = cos(alt) * sin(az)
	var lz: float = sin(alt)

	var bytes := PackedByteArray()
	bytes.resize(w * h * 3)
	var two_cell: float = 2.0 * cell_m

	for y: int in h:
		var row: int = y * w
		for x: int in w:
			var i: int = row + x
			var xm: int = maxi(x - 1, 0)
			var xp: int = mini(x + 1, w - 1)
			var ym: int = maxi(y - 1, 0)
			var yp: int = mini(y + 1, h - 1)
			var dzdx: float = (data[row + xp] - data[row + xm]) / two_cell
			var dzdy: float = (data[yp * w + x] - data[ym * w + x]) / two_cell

			# Surface normal of z = f(x, y) is (-dz/dx, -dz/dy, 1), normalized.
			var inv: float = 1.0 / sqrt(dzdx * dzdx + dzdy * dzdy + 1.0)
			var lambert: float = clampf((-dzdx * lx - dzdy * ly + lz) * inv, 0.0, 1.0)
			var shade: float = 0.25 + 0.75 * lambert

			var t: float = clampf((data[i] - mm.x) / span, 0.0, 1.0)
			# Low ground green, mid ground tan, high ground pale rock.
			var r: float
			var g: float
			var bl: float
			if t < 0.5:
				var u: float = t * 2.0
				r = lerpf(0.28, 0.66, u)
				g = lerpf(0.40, 0.60, u)
				bl = lerpf(0.26, 0.36, u)
			else:
				var u2: float = (t - 0.5) * 2.0
				r = lerpf(0.66, 0.92, u2)
				g = lerpf(0.60, 0.90, u2)
				bl = lerpf(0.36, 0.88, u2)

			var o: int = i * 3
			bytes[o] = int(clampf(r * shade, 0.0, 1.0) * 255.0)
			bytes[o + 1] = int(clampf(g * shade, 0.0, 1.0) * 255.0)
			bytes[o + 2] = int(clampf(bl * shade, 0.0, 1.0) * 255.0)

	return Image.create_from_data(w, h, false, Image.FORMAT_RGB8, bytes)


func save_png(path: String, shaded: bool = true) -> Error:
	var dir: String = path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var img: Image = to_shaded_image() if shaded else to_image()
	return img.save_png(path)
