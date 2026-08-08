class_name OverlayLayer
extends RefCounted

## The map overlays, as one small texture rather than geometry.
##
## A 200x200 image, one texel per tile, sampled by the terrain shader:
##
##   R  movement range      G  exposure      B  highlight (hover, path preview)
##
## Repainting is a PackedByteArray write plus `ImageTexture.update()` — one or two milliseconds for
## the whole map. Rebuilding an overlay mesh instead costs thirty to eighty, which would eat the
## entire 50 ms budget the movement overlay has to hit in 4.12 before any pathfinding happened.

const R := 0
const G := 1
const B := 2

var image: Image
var texture: ImageTexture
var _size: int
var _bytes: PackedByteArray


static func create(size: int) -> OverlayLayer:
	var o := OverlayLayer.new()
	o._size = size
	o._bytes = PackedByteArray()
	o._bytes.resize(size * size * 3)
	o.image = Image.create_from_data(size, size, false, Image.FORMAT_RGB8, o._bytes)
	o.texture = ImageTexture.create_from_image(o.image)
	return o


func clear_channel(channel: int) -> void:
	var stride: int = 3
	var count: int = _size * _size
	for i: int in count:
		_bytes[i * stride + channel] = 0


func clear_all() -> void:
	_bytes.fill(0)


func set_tile(tile: int, channel: int, value: int) -> void:
	_bytes[tile * 3 + channel] = value


## Write a whole channel from a per-tile byte buffer. This is the path the movement and visibility
## overlays actually use — one call, no per-tile scripting.
func set_channel(channel: int, values: PackedByteArray) -> void:
	var count: int = mini(_size * _size, values.size())
	for i: int in count:
		_bytes[i * 3 + channel] = values[i]


## Push the CPU-side buffer to the GPU. Cheap, but not free — call it once after a batch of writes,
## never per tile.
func upload() -> void:
	image.set_data(_size, _size, false, Image.FORMAT_RGB8, _bytes)
	texture.update(image)
