extends TestCase

## The camera's arithmetic, where it is pure enough to check without a viewport.
##
## Most of the camera is easing and input and can only be judged on screen. Two pieces are not: the
## zoom-sensitivity law in the gunner view, and the tunables both cameras are built from.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


# --- gunner optic sensitivity ---------------------------------------------------------------------

## At the field of view the optic starts at, the scaling is exactly 1 — so `gunner_look_sensitivity`
## keeps meaning what it meant before any of this existed, and the tuned value did not need touching.
func test_the_look_scale_is_neutral_at_the_starting_zoom() -> void:
	var base: float = cfg.f("camera.gunner_fov_deg", 28.0)
	assert_almost_eq(CameraDirector.look_scale(base, base, 1.0), 1.0, 0.0001,
		"the sensitivity is not unchanged at the zoom it was tuned at")


## The law itself: degrees per pixel proportional to the field of view. That is the only factor that
## moves the *image* by a constant number of screen pixels whatever the magnification.
func test_the_look_scale_is_linear_in_the_field_of_view() -> void:
	assert_almost_eq(CameraDirector.look_scale(14.0, 28.0, 1.0), 0.5, 0.0001,
		"halving the field of view must halve the sensitivity")
	assert_almost_eq(CameraDirector.look_scale(7.0, 28.0, 1.0), 0.25, 0.0001,
		"a quarter of the field of view must be a quarter of the sensitivity")
	assert_almost_eq(CameraDirector.look_scale(56.0, 28.0, 1.0), 2.0, 0.0001,
		"pulling back must speed the look up by the same law")


## Monotonic across the whole range the wheel can reach, which is the property that actually matters
## in the hand: no zoom step may make the view faster than the step before it.
func test_the_look_scale_never_rises_as_the_optic_magnifies() -> void:
	var base: float = cfg.f("camera.gunner_fov_deg", 28.0)
	var lo: float = cfg.f("camera.gunner_fov_min_deg", 6.0)
	var hi: float = cfg.f("camera.gunner_fov_max_deg", 45.0)
	var strength: float = cfg.f("camera.gunner_zoom_sens_scaling", 1.0)

	var previous: float = CameraDirector.look_scale(hi, base, strength)
	var steps: int = 24
	for k: int in range(1, steps + 1):
		var fov: float = lerpf(hi, lo, float(k) / float(steps))
		var now: float = CameraDirector.look_scale(fov, base, strength)
		assert_le(now, previous + 0.0001,
			"the look sped up between %.1f and %.1f degrees" % [previous, fov])
		previous = now

	assert_lt(CameraDirector.look_scale(lo, base, strength),
		CameraDirector.look_scale(hi, base, strength),
		"fully magnified is no slower than fully wide — the scaling is doing nothing")


## `strength` 0 is the escape hatch for anyone who wants flat sensitivity, and it has to be exactly
## flat rather than nearly so.
func test_zero_strength_leaves_the_sensitivity_alone() -> void:
	for fov: float in [6.0, 28.0, 45.0]:
		assert_almost_eq(CameraDirector.look_scale(fov, 28.0, 0.0), 1.0, 0.0001,
			"strength 0 changed the sensitivity at %.0f degrees" % fov)


## Out-of-range strength is clamped rather than extrapolated: 2.0 would overshoot into a law nobody
## chose, and a negative would speed the look up as it magnified.
func test_the_strength_is_clamped_to_its_range() -> void:
	assert_almost_eq(CameraDirector.look_scale(14.0, 28.0, 5.0),
		CameraDirector.look_scale(14.0, 28.0, 1.0), 0.0001, "strength above 1 was not clamped")
	assert_almost_eq(CameraDirector.look_scale(14.0, 28.0, -3.0),
		CameraDirector.look_scale(14.0, 28.0, 0.0), 0.0001, "strength below 0 was not clamped")


## A zero or negative reference would divide by nothing. It cannot happen from the data files, but
## the function is public and static and this is one line.
func test_a_degenerate_reference_is_survived() -> void:
	assert_almost_eq(CameraDirector.look_scale(14.0, 0.0, 1.0), 1.0, 0.0001,
		"a zero reference field of view should fall back to neutral")


# --- the zoom itself ------------------------------------------------------------------------------

## The wheel is multiplicative, so a notch is the same proportion at either end of the range. Walking
## the whole way down and back must land inside the limits rather than drifting past them.
func test_the_zoom_range_is_reachable_in_both_directions() -> void:
	var lo: float = cfg.f("camera.gunner_fov_min_deg", 6.0)
	var hi: float = cfg.f("camera.gunner_fov_max_deg", 45.0)
	var step: float = cfg.f("camera.gunner_zoom_step", 0.12)

	var fov: float = cfg.f("camera.gunner_fov_deg", 28.0)
	for _k: int in 60:
		fov = clampf(fov * (1.0 - step), lo, hi)
	assert_almost_eq(fov, lo, 0.0001, "the optic cannot be wound all the way in")

	for _k2: int in 60:
		fov = clampf(fov * (1.0 + step), lo, hi)
	assert_almost_eq(fov, hi, 0.0001, "the optic cannot be wound all the way back out")


## Not so coarse that the range is crossed in a couple of notches, which is what a fixed
## degrees-per-notch step feels like at the narrow end.
func test_the_zoom_takes_a_sensible_number_of_notches_end_to_end() -> void:
	var lo: float = cfg.f("camera.gunner_fov_min_deg", 6.0)
	var hi: float = cfg.f("camera.gunner_fov_max_deg", 45.0)
	var step: float = cfg.f("camera.gunner_zoom_step", 0.12)
	var notches: float = log(hi / lo) / log(1.0 + step)
	assert_in_range(notches, 6.0, 40.0,
		"%.0f notches from one end of the zoom to the other" % notches)
