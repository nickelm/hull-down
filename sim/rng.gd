class_name Rng
extends RefCounted

## Named, seeded random number streams. The whole determinism contract lives here.
##
## Nothing in sim/ may call randi(), randf(), or randomize(). Every draw comes from a stream
## obtained here, seeded from the match's master_seed mixed with a stream constant.
##
## Four top-level streams keep subsystems independent: adding an AI call can never shift a combat
## roll, because they draw from different generators. substream() gives the same guarantee one
## level down — each terrain generation stage takes its own tagged substream, so inserting a stage
## never reshuffles the noise of the stages that follow it.
##
## See docs/decisions/0005-deterministic-seeded-simulation.md.

enum Stream {
	TERRAIN = 0,
	COMBAT = 1,
	AI = 2,
	CRITS = 3,
}

# splitmix64 constants, written as signed decimal because GDScript integers are int64 and these
# exceed its positive range. Bit patterns are identical; the hex form is given for recognition.
const GOLDEN: int = -7046029254386353131   # 0x9E3779B97F4A7C15
const MIX_A: int = -4658895280553007687    # 0xBF58476D1CE4E5B9
const MIX_B: int = -7723592293110705685    # 0x94D049BB133111EB
const SALT_D: int = -2960836687051489901   # 0xD6E8FEB86659FD93

# FNV-1a 64-bit.
const FNV_OFFSET: int = -3750763034362895579  # 0xCBF29CE484222325
const FNV_PRIME: int = 1099511628211          # 0x100000001B3

const _STREAM_SALT: Array[int] = [GOLDEN, MIX_A, MIX_B, SALT_D]


## Logical (zero-filling) right shift.
##
## GDScript's >> is arithmetic on signed integers, which sign-extends. splitmix64 and FNV both
## require the unsigned form, so the sign bits have to be masked off explicitly. n must be 1..63.
static func ushr(v: int, n: int) -> int:
	return (v >> n) & ((1 << (64 - n)) - 1)


## splitmix64 finalizer over two inputs. Avalanches hard enough that seeds one apart produce
## unrelated streams, which matters because map seeds are typically small consecutive integers.
static func mix(a: int, b: int) -> int:
	var z: int = a ^ (b * GOLDEN)
	z = (z ^ ushr(z, 30)) * MIX_A
	z = (z ^ ushr(z, 27)) * MIX_B
	return z ^ ushr(z, 31)


## FNV-1a over the UTF-8 bytes of a string.
##
## Deliberately not String.hash(): that is an engine implementation detail with no stability
## guarantee across versions, and a substream tag whose hash changes between releases would
## silently regenerate every map.
static func fnv1a(s: String) -> int:
	var bytes: PackedByteArray = s.to_utf8_buffer()
	var h: int = FNV_OFFSET
	for i: int in bytes.size():
		h = (h ^ bytes[i]) * FNV_PRIME
	return h


## A top-level stream. Use this for match-scoped randomness: combat rolls, AI decisions, crits.
static func stream(master_seed: int, s: Stream) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = mix(master_seed, _STREAM_SALT[int(s)])
	return r


## A tagged substream of a top-level stream.
##
## Independent of every other tag and of draw order, so stages can be added, removed, or reordered
## without disturbing each other. Every terrain generation stage should take one of these rather
## than sharing the TERRAIN stream directly.
static func substream(master_seed: int, s: Stream, tag: String) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = mix(mix(master_seed, _STREAM_SALT[int(s)]), fnv1a(tag))
	return r


## A deterministic integer derived from a seed and a tag, without allocating a generator.
## Useful for seeding FastNoiseLite, which takes a seed rather than a stream.
static func derive(master_seed: int, s: Stream, tag: String) -> int:
	return mix(mix(master_seed, _STREAM_SALT[int(s)]), fnv1a(tag))
