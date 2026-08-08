class_name IntHeap
extends RefCounted

## Minimum binary heap over (key, value) pairs of integers.
##
## GDScript has no priority queue. The two candidates are this and a bucket queue; this one is for
## searches whose key range is unbounded or large — connectivity repair and road routing, where an
## edge can cost hundreds and a path can cost tens of thousands.
##
## Both fields are packed into one 64-bit integer, key in the high bits, so the whole heap is a
## single PackedInt64Array and every comparison is an integer compare on a contiguous buffer. No
## Callable, no Variant boxing, no allocation per push. Ordering by the packed word orders by key
## first and by value second, which also makes ties resolve deterministically.
##
## For the tank pathfinder's hot loop, prefer DialQueue: its keys are small and bounded, and a
## bucket queue beats a heap there by doing no comparisons at all.

const VALUE_BITS := 20
const VALUE_MASK := (1 << VALUE_BITS) - 1
## Keys above this would overflow into the sign bit once shifted.
const MAX_KEY := (1 << 42) - 1

var _data := PackedInt64Array()


func clear() -> void:
	_data.clear()


func size() -> int:
	return _data.size()


func is_empty() -> bool:
	return _data.is_empty()


func push(key: int, value: int) -> void:
	var packed: int = (key << VALUE_BITS) | (value & VALUE_MASK)
	var i: int = _data.size()
	_data.push_back(packed)
	while i > 0:
		var parent: int = (i - 1) >> 1
		if _data[parent] <= _data[i]:
			break
		var tmp: int = _data[parent]
		_data[parent] = _data[i]
		_data[i] = tmp
		i = parent


## Returns the packed word; use `key_of` and `value_of` to unpack. Returns -1 when empty, which is
## distinguishable from any real entry because keys are non-negative.
func pop() -> int:
	if _data.is_empty():
		return -1
	var top: int = _data[0]
	var last: int = _data[_data.size() - 1]
	_data.resize(_data.size() - 1)
	if _data.is_empty():
		return top

	_data[0] = last
	var i: int = 0
	var count: int = _data.size()
	while true:
		var left: int = i * 2 + 1
		if left >= count:
			break
		var smallest: int = left
		var right: int = left + 1
		if right < count and _data[right] < _data[left]:
			smallest = right
		if _data[i] <= _data[smallest]:
			break
		var tmp: int = _data[i]
		_data[i] = _data[smallest]
		_data[smallest] = tmp
		i = smallest

	return top


static func key_of(packed: int) -> int:
	return packed >> VALUE_BITS


static func value_of(packed: int) -> int:
	return packed & VALUE_MASK
