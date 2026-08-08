class_name NoiseField
extends RefCounted

## Noise primitives for terrain generation.
##
## FastNoiseLite is used only as a single-octave sampler (FRACTAL_NONE). Its built-in
## FRACTAL_RIDGED is *not* ridged multifractal: it sums |noise| octaves without the per-octave
## weighting term, so every octave contributes everywhere and the result is the field of isotropic
## lumps that 4.2's acceptance check exists to reject. The weighting is the whole point — it makes
## fine detail appear only near the ridge lines the coarse octaves established, which is what
## produces long connected crests.


## One FastNoiseLite per octave, each at its own frequency, each with its own derived seed.
static func build_octaves(
	master_seed: int, tag: String, octaves: int, base_freq: float, lacunarity: float
) -> Array[FastNoiseLite]:
	var out: Array[FastNoiseLite] = []
	var freq: float = base_freq
	for o: int in octaves:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
		n.seed = Rng.derive(master_seed, Rng.Stream.TERRAIN, "%s.oct%d" % [tag, o])
		n.frequency = freq
		out.append(n)
		freq *= lacunarity
	return out


## Ridged multifractal.
##
## Each octave is (offset - |noise|)^2 — a ridge where the noise crosses zero — scaled by a weight
## carried forward from the previous octave. Where the previous octave was in a valley the weight
## is near zero and the finer detail is suppressed; where it was on a crest the detail comes
## through at full strength. Result is unbounded above; callers normalize.
static func ridged_multifractal(
	oct: Array[FastNoiseLite], x: float, y: float, gain: float, offset: float, h_exp: float
) -> float:
	# Named `sig` rather than `signal`, which is a GDScript keyword.
	var sig: float = offset - absf(oct[0].get_noise_2d(x, y))
	sig *= sig
	var result: float = sig
	var freq_w: float = 1.0

	for o: int in range(1, oct.size()):
		var weight: float = clampf(sig * gain, 0.0, 1.0)
		sig = offset - absf(oct[o].get_noise_2d(x, y))
		sig *= sig
		sig *= weight
		freq_w *= h_exp
		result += sig * freq_w

	return result


## Two low-frequency fields used to displace the sample point before the multifractal is evaluated.
## Straight noise gives ridges that run in whatever direction the lattice suggests; warping the
## domain bends them into something that looks folded rather than generated.
static func build_warp(master_seed: int, tag: String, freq: float) -> Array[FastNoiseLite]:
	var out: Array[FastNoiseLite] = []
	for k: int in 2:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
		n.seed = Rng.derive(master_seed, Rng.Stream.TERRAIN, "%s.warp%d" % [tag, k])
		n.frequency = freq
		out.append(n)
	return out


static func warp_offset(warp: Array[FastNoiseLite], x: float, y: float, amp: float) -> Vector2:
	return Vector2(warp[0].get_noise_2d(x, y) * amp, warp[1].get_noise_2d(x, y) * amp)


## A single low-frequency field, for masks that want smooth large-scale variation — forest
## patchiness, tectonic band modulation.
static func build_single(master_seed: int, tag: String, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	n.seed = Rng.derive(master_seed, Rng.Stream.TERRAIN, tag)
	n.frequency = freq
	return n
