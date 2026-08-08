class_name DialQueue
extends RefCounted

## Bucket priority queue for small integer keys.
##
## Dijkstra and A* pop in non-decreasing key order, so the queue never has to look backwards. That
## turns the priority queue into an array of buckets and a cursor that only moves forward: pushing
## is an index and a write, popping is a read. No comparisons, no sift loops, no allocation.
##
## Against a binary heap this is two to four times faster in GDScript, and the reason is that
## GDScript charges for every operation in a sift loop while a bucket queue has none.
##
## The buckets are linked lists over a **node pool**, not over the values themselves.
##
## The obvious version links each value directly — `next[value]` — and it is wrong. Dijkstra with
## lazy deletion pushes the same state again whenever it finds a cheaper route to it, and an
## intrusive list can only hold a value once: the second push overwrites that value's `next`
## pointer and silently orphans everything behind it in the old bucket. The search then loses
## whole regions of the map and reports no route across open ground.
##
## A node pool costs one more array and allows duplicates, which is what lazy deletion needs.
## An array of PackedInt32Arrays would be the other obvious option and is the copy-on-write trap:
## reading a bucket out, pushing to it and writing it back copies the whole bucket per push.

var last_key: int = 0

var _bucket_head: PackedInt32Array
var _node_next: PackedInt32Array
var _node_value: PackedInt32Array
var _node_count: int = 0
var _cursor: int = 0
var _count: int = 0
var _max_key: int


func _init(max_key: int, capacity: int) -> void:
	_max_key = max_key
	_bucket_head = PackedInt32Array()
	_bucket_head.resize(max_key + 2)
	_bucket_head.fill(-1)
	_node_next = PackedInt32Array()
	_node_value = PackedInt32Array()
	_node_next.resize(capacity)
	_node_value.resize(capacity)


## Ready the queue for another search. The node pool is reset with a counter rather than cleared,
## so this does not touch it at all.
func clear() -> void:
	_bucket_head.fill(-1)
	_cursor = 0
	_count = 0
	_node_count = 0


func size() -> int:
	return _count


func is_empty() -> bool:
	return _count == 0


## Keys above `max_key` are clamped into the last bucket. That degrades the ordering for the very
## worst paths rather than corrupting the search, and those paths are beyond any movement allowance
## a unit will have.
func push(key: int, value: int) -> void:
	var b: int = key if key <= _max_key else _max_key + 1
	# The cursor only moves forward, so an item that belongs behind it goes into the current bucket
	# instead. With non-negative edge costs this never happens during a search; it is a guard, not
	# a mechanism, and it keeps a caller mistake from writing outside the bucket array.
	if b < _cursor:
		b = _cursor

	if _node_count >= _node_value.size():
		# Every relaxation that improves a state pushes it again, so the pool can outgrow the state
		# count. Doubling is rare and amortizes away.
		var grown: int = maxi(_node_value.size() * 2, 64)
		_node_value.resize(grown)
		_node_next.resize(grown)

	var node: int = _node_count
	_node_count += 1
	_node_value[node] = value
	_node_next[node] = _bucket_head[b]
	_bucket_head[b] = node
	_count += 1


## Returns the next value, or -1 when empty. `last_key` holds the key it came from.
func pop() -> int:
	# Checked before scanning, not after. Letting the scan run off the end of an empty queue leaves
	# the cursor past the last bucket, and then the guard in push() clamps every subsequent key up
	# to that — so a queue that has been drained once silently swallows everything pushed into it
	# afterwards.
	if _count == 0:
		return -1
	while _cursor < _bucket_head.size():
		var node: int = _bucket_head[_cursor]
		if node != -1:
			_bucket_head[_cursor] = _node_next[node]
			_count -= 1
			last_key = _cursor
			return _node_value[node]
		_cursor += 1
	return -1
