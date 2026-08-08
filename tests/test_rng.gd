extends TestCase

## The determinism contract, tested directly. See docs/decisions/0005.

const SEED_A: int = 12345
const SEED_B: int = 12346


func _draw(r: RandomNumberGenerator, n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	for i: int in n:
		out[i] = r.randf()
	return out


func test_same_seed_same_sequence() -> void:
	var a := _draw(Rng.stream(SEED_A, Rng.Stream.COMBAT), 64)
	var b := _draw(Rng.stream(SEED_A, Rng.Stream.COMBAT), 64)
	assert_eq(a, b, "same seed and stream must reproduce the sequence exactly")


func test_streams_are_independent() -> void:
	var names: Array[Rng.Stream] = [
		Rng.Stream.TERRAIN, Rng.Stream.COMBAT, Rng.Stream.AI, Rng.Stream.CRITS
	]
	var seqs: Array[PackedFloat64Array] = []
	for s: Rng.Stream in names:
		seqs.append(_draw(Rng.stream(SEED_A, s), 32))
	for i: int in seqs.size():
		for j: int in range(i + 1, seqs.size()):
			assert_ne(seqs[i], seqs[j], "streams %d and %d produced the same sequence" % [i, j])


## The property the whole contract rests on: adding work to one subsystem must not perturb another.
## If this fails, an extra AI call somewhere would silently reroll every combat outcome after it.
func test_ai_draws_do_not_disturb_combat() -> void:
	var baseline := _draw(Rng.stream(SEED_A, Rng.Stream.COMBAT), 48)

	var ai := Rng.stream(SEED_A, Rng.Stream.AI)
	for _k: int in 100:
		ai.randf()
	var after := _draw(Rng.stream(SEED_A, Rng.Stream.COMBAT), 48)

	assert_eq(after, baseline, "COMBAT sequence shifted after drawing from AI")


func test_adjacent_seeds_diverge() -> void:
	var a := _draw(Rng.stream(SEED_A, Rng.Stream.TERRAIN), 32)
	var b := _draw(Rng.stream(SEED_B, Rng.Stream.TERRAIN), 32)
	assert_ne(a, b, "seeds one apart produced identical streams — the mixer is not avalanching")
	# Not merely different in the tail: the very first draw must already differ.
	assert_ne(a[0], b[0], "first draw identical for adjacent seeds")


func test_substreams_are_tag_stable_and_order_independent() -> void:
	var erosion_first := _draw(Rng.substream(SEED_A, Rng.Stream.TERRAIN, "hydraulic"), 32)
	# Consume a different substream in between; the tagged one must be unaffected.
	var other := Rng.substream(SEED_A, Rng.Stream.TERRAIN, "thermal")
	for _k: int in 500:
		other.randf()
	var erosion_second := _draw(Rng.substream(SEED_A, Rng.Stream.TERRAIN, "hydraulic"), 32)

	assert_eq(erosion_second, erosion_first, "substream depends on draw order elsewhere")


func test_substream_tags_differ() -> void:
	var a := _draw(Rng.substream(SEED_A, Rng.Stream.TERRAIN, "hydraulic"), 32)
	var b := _draw(Rng.substream(SEED_A, Rng.Stream.TERRAIN, "thermal"), 32)
	assert_ne(a, b, "different substream tags produced the same sequence")

	# A substream must also differ from its parent stream.
	var parent := _draw(Rng.stream(SEED_A, Rng.Stream.TERRAIN), 32)
	assert_ne(a, parent, "substream matched its parent stream")


func test_fnv1a_is_deterministic_and_distinguishing() -> void:
	assert_eq(Rng.fnv1a("hydraulic"), Rng.fnv1a("hydraulic"), "fnv1a is not deterministic")
	assert_ne(Rng.fnv1a("hydraulic"), Rng.fnv1a("hydrauli"), "fnv1a collided on a prefix")
	assert_ne(Rng.fnv1a(""), Rng.fnv1a("a"), "fnv1a collided the empty string with 'a'")
	# Pinned so a refactor of the hash is caught rather than silently regenerating every map.
	assert_eq(Rng.fnv1a("terrain"), 4578760715504805550, "fnv1a value changed")


func test_ushr_is_logical_not_arithmetic() -> void:
	assert_eq(Rng.ushr(-1, 63), 1, "ushr sign-extended: -1 >>> 63 must be 1")
	assert_eq(Rng.ushr(-1, 1), 9223372036854775807, "ushr sign-extended on a 1-bit shift")
	assert_eq(Rng.ushr(256, 4), 16, "ushr wrong on a positive value")


func test_derive_matches_substream_seed() -> void:
	var r := Rng.substream(SEED_A, Rng.Stream.TERRAIN, "warp")
	assert_eq(
		Rng.derive(SEED_A, Rng.Stream.TERRAIN, "warp"), r.seed,
		"derive and substream disagree — noise seeding would diverge from generator seeding"
	)
