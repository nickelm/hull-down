class_name TestCase
extends RefCounted

## Base class for test files. Subclass it, name the file tests/test_<thing>.gd, and name each test
## method test_<what>. The runner instantiates the class fresh for every method, so tests cannot
## leak state into each other.
##
## GDScript has no exceptions, so assertions record into `failures` and execution continues. That
## means a failing assertion does not stop the rest of the method — write tests so a bad early
## assertion produces one clear failure rather than a cascade, and use `bail()` where continuing
## would crash on a null.

var failures: PackedStringArray = PackedStringArray()

## Set by an assertion that makes the rest of the method meaningless. Checked via bailed().
var _bailed: bool = false


func setup() -> void:
	pass


func teardown() -> void:
	pass


func bailed() -> bool:
	return _bailed


func fail(msg: String) -> void:
	failures.append(msg)


## Record a failure and mark the test as unable to continue meaningfully.
func fail_hard(msg: String) -> void:
	failures.append(msg)
	_bailed = true


func assert_true(cond: bool, msg: String) -> void:
	if not cond:
		failures.append(msg)


func assert_false(cond: bool, msg: String) -> void:
	if cond:
		failures.append(msg)


func assert_eq(actual: Variant, expected: Variant, msg: String) -> void:
	if actual != expected:
		failures.append("%s — expected %s, got %s" % [msg, str(expected), str(actual)])


func assert_ne(actual: Variant, unexpected: Variant, msg: String) -> void:
	if actual == unexpected:
		failures.append("%s — expected anything but %s" % [msg, str(unexpected)])


func assert_almost_eq(actual: float, expected: float, tol: float, msg: String) -> void:
	if absf(actual - expected) > tol:
		failures.append("%s — expected %f +/- %f, got %f" % [msg, expected, tol, actual])


func assert_lt(actual: float, bound: float, msg: String) -> void:
	if not (actual < bound):
		failures.append("%s — expected < %f, got %f" % [msg, bound, actual])


func assert_le(actual: float, bound: float, msg: String) -> void:
	if not (actual <= bound):
		failures.append("%s — expected <= %f, got %f" % [msg, bound, actual])


func assert_gt(actual: float, bound: float, msg: String) -> void:
	if not (actual > bound):
		failures.append("%s — expected > %f, got %f" % [msg, bound, actual])


func assert_ge(actual: float, bound: float, msg: String) -> void:
	if not (actual >= bound):
		failures.append("%s — expected >= %f, got %f" % [msg, bound, actual])


func assert_in_range(actual: float, lo: float, hi: float, msg: String) -> void:
	if actual < lo or actual > hi:
		failures.append("%s — expected %f..%f, got %f" % [msg, lo, hi, actual])


func assert_not_null(v: Variant, msg: String) -> void:
	if v == null:
		fail_hard(msg + " — got null")
