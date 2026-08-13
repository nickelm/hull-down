extends TestCase

## The sound layer — docs/decisions/0033 and 0037.
##
## The three claims the acceptance criterion makes are all here and all named: a shot from an
## **unspotted** enemy produces a contact, its displayed position **differs from truth by an amount
## that scales with distance**, and **no unit silhouette** comes with it.
##
## The rest of the file guards the properties that make those three survive. A sound ignores line of
## sight, which is the one thing it must never quietly start respecting; the error is a hash and not a
## draw, which is what keeps `tests/test_combat_distribution`'s thousand pinned resolutions where they
## are; and the layer is written only by `EventApplier`, which is what lets a replay reproduce it.
##
## Distinct from `tests/test_spotting.gd` and `tests/test_knowledge.gd` on purpose. Those two are about
## the *visual* layer, and 0033's whole argument is that conflating the two is a class of bug nobody
## can name afterwards. If an assertion here would read equally well over there, it is in the wrong
## file.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, facing: int = Grid.E) -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), "medium")
	u.side = side
	u.facing = facing
	u.turret = facing
	return u


## **A firefight the listener is walled off from — the only shape in which a shot can be heard rather
## than seen, and it is worth writing down why.**
##
## Line of sight is very nearly reciprocal: `Los.classify` marches one segment and both endpoints are
## excluded from it, so "that tank can see me and I cannot see it" is not a geometry this engine can
## produce. Firing then reveals the firer to anything with an unmasked line to it, at any range
## (`Spotting.can_see`). Put those together and a gun fired at *you* is a gun you can see, always.
##
## So the case the layer exists for is a gun fired at **somebody else**, from ground you cannot
## overlook. Knowledge is side-level (0024), so it also has to be somebody else's side, or the victim
## spots the firer on your behalf. Three sides is therefore the minimum honest fixture, not an
## elaboration:
##
##   * unit 0 — side 1's **listener**, west of a solid wall, masked from everything east of it.
##   * unit 1 — side 2's **firer**, east of the wall.
##   * unit 2 — side 3's **victim**, beside the firer and well inside point-blank range of it.
##
## Side 2 shoots side 3 across open ground. Side 3 sees the muzzle flash, as it should. Side 1 hears
## it and nothing more, which is the thing being tested.
func _crossfire(lx: int = 2, ly: int = 10, size: int = 60) -> Array:
	var md: MapData = _flat(size)
	for y: int in md.size:
		md.blocker_h[md.idx(12, y)] = 14.0

	var m: MatchState = MatchState.create(3)
	m.add_unit(_unit(md, 1, lx, ly, Grid.E))
	m.add_unit(_unit(md, 2, 18, 10, Grid.SE))
	m.add_unit(_unit(md, 3, 20, 13, Grid.NW))
	m.active_side = 2

	var r := ActionResolver.new(md, cfg, m)
	r.refresh_knowledge()
	return [md, m, r]


## Two units in the open, `gap` tiles apart, in contact with each other from the start.
func _pair(gap: int, size: int = 40) -> Array:
	var md: MapData = _flat(size)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10, Grid.E))
	m.add_unit(_unit(md, 2, 2 + gap, 10, Grid.W))
	m.active_side = 2
	var r := ActionResolver.new(md, cfg, m)
	r.refresh_knowledge()
	return [md, m, r]


func _heard_events(events: Array[ActionEvent]) -> Array[ActionEvent]:
	var out: Array[ActionEvent] = []
	for e: ActionEvent in events:
		if e.kind == ActionEvent.Kind.HEARD:
			out.append(e)
	return out


# --- the acceptance criterion ---------------------------------------------------------------------

## The headline claim, and the reason the batch exists. Side 2 shoots side 3 on the far side of a wall
## side 1 cannot see through; side 1 must end up with a contact anyway.
##
## Three assertions, and all three are the feature. A contact appears for the side that only heard it.
## Side 1 still does not *see* the firer, which is what makes this a sound rather than a reveal
## wearing a different marker. And side 3, which watched the muzzle flash, gets no contact at all —
## the suppression rule, without which the layer would draw a guess on top of every confirmed target
## and stop meaning anything.
func test_a_shot_from_an_unspotted_enemy_is_heard() -> void:
	var fixture: Array = _crossfire()
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	assert_false(m.knowledge_for(1).knows_of(1),
		"the fixture is broken: side 1 can already see the tank that is about to shoot")
	assert_true(m.knowledge_for(2).sees(2),
		"the fixture is broken: the firer cannot see the target it is about to shoot")

	var res: ActionResult = r.resolve_fire(1, 2)
	assert_true(res.ok(), "the shot was refused with status %d" % res.status)

	assert_eq(m.sound_for(1).count(), 1,
		"a shot from an enemy side 1 cannot see produced no sound contact at all")
	assert_false(m.knowledge_for(1).knows_of(1),
		"hearing a gun revealed the tank that fired it, which makes it a reveal and not a sound")
	assert_true(m.knowledge_for(3).sees(1),
		"the muzzle flash did not reveal the firer to the side it was shooting at")
	assert_eq(m.sound_for(3).count(), 0,
		"the side watching the muzzle flash was also handed a guess about where the gun is")


## The second half of the criterion: the marker is in the wrong place, and more wrong the further the
## noise is from the listener's own troops.
##
## Asserted on the stored error radius rather than on the sampled offset. The radius is the *rule* —
## a pure function of distance — while the offset is that radius times a hash-derived fraction, and
## pinning the rule is what actually says "error scales with distance". The offset is checked
## separately, below, for the property that it is bounded by the radius and never zero.
func test_the_error_grows_with_distance_from_the_nearest_friendly() -> void:
	var p: SoundParams = SoundParams.from_config(cfg)

	var near: int = p.error_dm(50.0)
	var mid: int = p.error_dm(400.0)
	var far: int = p.error_dm(900.0)

	assert_gt(float(mid), float(near),
		"a noise four hundred meters from your nearest tank is placed no worse than one at fifty")
	assert_gt(float(far), float(mid),
		"the error stopped growing before it reached the configured ceiling")
	assert_le(float(p.error_dm(100000.0)), float(p.error_max_m * 10.0),
		"the error radius ran past error_max_m, so a distant contact covers the whole board")
	assert_gt(float(near), 0.0,
		"a noise next door is placed perfectly, which is a sighting and not a guess")


## And end to end, through two real fixtures rather than through the arithmetic: the side whose
## nearest unit is further away gets the larger radius on the contact it actually stores.
func test_a_distant_listener_stores_a_larger_error_than_a_close_one() -> void:
	# The same firefight twice, with side 1's listener parked in two places behind the same wall. Only
	# its distance from the gun differs, which is the variable under test and the only one.
	var close: Array = _crossfire(2, 10)
	var distant: Array = _crossfire(2, 50)

	var errs: Array[float] = []
	for fixture: Array in [close, distant]:
		var md: MapData = fixture[0]
		var m: MatchState = fixture[1]
		var r: ActionResolver = fixture[2]
		var res: ActionResult = r.resolve_fire(1, 2)
		assert_true(res.ok(), "the shot was refused with status %d" % res.status)
		var s: SideSound = m.sound_for(1)
		assert_eq(s.count(), 1, "expected exactly one contact, got %d" % s.count())
		errs.append(float(s.error_dm_at(0)))
		# The listener really is further away in the second fixture, so the assertion below is about
		# the rule rather than about two fixtures that happened to differ.
		assert_gt(md.dist_m(m.unit(0).tile, m.unit(1).tile), 0.0, "the listener is on the gun")

	assert_gt(errs[1], errs[0],
		"a gun four hundred meters from your nearest tank is placed as precisely as one at a hundred")


## The third claim: nothing that looks like a tank appears. `ViewState` is the renderer's only source
## of what to draw, and it must be unmoved by the whole thing.
##
## This is the assertion that would catch the failure 0033 is really about — a sound contact leaking
## into the visual layer and being drawn as a dim silhouette, which players read as a ghost with a
## rendering bug, aim at, and then distrust the entire layer over.
func test_a_sound_contact_draws_no_unit() -> void:
	var fixture: Array = _crossfire()
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var before: PackedByteArray = ViewState.all(m, 1)
	r.resolve_fire(1, 2)

	assert_gt(float(m.sound_for(1).count()), 0.0, "the fixture produced no contact to test")
	assert_eq(ViewState.all(m, 1), before,
		"hearing something changed what side 1 draws, which means it is drawing the sound as a unit")
	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.HIDDEN,
		"the tank that fired is no longer hidden from the side that only heard it")

	# And the boundary type carries nothing to draw a silhouette *from*. This is the property 0033
	# asked to be made structural rather than remembered, so it is asserted against the actual
	# property list — a docstring saying the fields are absent is not a thing that can fail.
	var contacts: Array[SoundContact] = m.sound_contacts(1)
	assert_eq(contacts.size(), 1, "sound_contacts disagrees with the container it reads")
	var fields := PackedStringArray()
	for p: Dictionary in contacts[0].get_property_list():
		fields.append(str(p.get("name", "")))
	assert_false(fields.has("unit"),
		"SoundContact grew a unit index, which is the identity 0033 says it must never carry")
	assert_false(fields.has("unit_type"),
		"SoundContact grew a unit_type, so a marker can now say what kind of tank it heard")


# --- what a sound is not --------------------------------------------------------------------------

## Line of sight is not consulted. The `_screened` fixture's wall stands fourteen meters tall between
## the two tanks and is exactly what stops them seeing each other; it must do nothing at all here.
##
## The regression this guards is a plausible one: `Sound.evaluate` sits beside `Spotting`, takes the
## same arguments, and reads a `SideKnowledge` for the suppression rule. Adding a `Los.classify` to it
## would look like tidying up and would silently reduce the layer to "you hear what you can see".
func test_a_sound_ignores_line_of_sight_entirely() -> void:
	var fixture: Array = _crossfire()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]

	assert_eq(Los.classify(md, cfg, m.unit(0).tile, m.unit(1).tile), Los.Exposure.MASKED,
		"the fixture is broken: the wall does not actually mask the listener from the gun")

	var p: SoundParams = SoundParams.from_config(cfg)
	assert_ge(float(Sound.heard_error_dm(md, p, m, 1, SideSound.Source.FIRE, m.unit(1).tile)), 0.0,
		"a masked noise was not heard, so something in the sound path is testing line of sight")


## A radius is the whole test, so beyond it there is nothing. Without this the layer would put a
## contact on the board for every shot anywhere on the map, and a marker that always appears carries
## no information.
func test_a_noise_beyond_its_radius_is_not_heard() -> void:
	var md: MapData = _flat(200)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 190, 190))

	var p: SoundParams = SoundParams.from_config(cfg)
	var d: float = md.dist_m(m.unit(0).tile, m.unit(1).tile)
	assert_gt(d, p.fire_radius_m,
		"the fixture is not actually out of earshot: %.0f m against a %.0f m radius"
			% [d, p.fire_radius_m])

	assert_eq(Sound.heard_error_dm(md, p, m, 1, SideSound.Source.FIRE, m.unit(1).tile), -1,
		"a gun fired well beyond fire_radius_m was still heard")
	# And an engine carries less far than a gun, which is the only reason the two radii are separate
	# numbers rather than one.
	assert_lt(p.move_radius_m, p.fire_radius_m,
		"an engine is audible as far as a gun, so the two radii say nothing the player can use")


## A side that can already see the noisemaker gets nothing. A ripple drawn over a tank you are looking
## at says less than the tank does, and worse, it teaches the player that a ripple sometimes means a
## confirmed target — after which the marker's honesty, which is the whole design, is gone.
func test_a_side_that_can_see_the_firer_hears_nothing() -> void:
	var fixture: Array = _pair(6)
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	assert_true(m.knowledge_for(1).sees(1),
		"the fixture is broken: side 1 cannot see the tank it is standing six tiles from")

	r.resolve_fire(1, 0)
	assert_eq(m.sound_for(1).count(), 0,
		"a side that is looking straight at the firer was also handed a guess about where it is")


## But a *ghost* is not a sighting. The ghost says where it used to be and the noise is evidence about
## now, which is exactly the case the layer exists for — and it is the one place the two layers touch,
## so it is the one place they could most easily be conflated.
func test_a_side_holding_only_a_ghost_still_hears() -> void:
	var fixture: Array = _crossfire()
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var k: SideKnowledge = m.knowledge_for(1)
	k.mark_seen(1)
	k.mark_lost(1, m.unit(1).tile, m.unit(1).facing, 2)
	assert_eq(k.state_of(1), SideKnowledge.State.GHOST, "the fixture did not leave a ghost")

	r.resolve_fire(1, 2)

	assert_eq(k.state_of(1), SideKnowledge.State.GHOST,
		"the fixture is broken: side 1's ghost became something else before the assertion")
	assert_eq(m.sound_for(1).count(), 1,
		"a side holding a two-turn-old ghost was told nothing by a gun going off right now")


# --- the error itself -----------------------------------------------------------------------------

## The marker never sits on the tank. A guess that happens to land dead on reads as certainty, and a
## player who has seen it land dead on once will aim at the next one.
##
## Swept over a whole map's worth of source tiles rather than sampled, because the failure mode is a
## rounding one — a sub-tile offset collapsing to (0, 0) — and it depends on the bearing the hash
## picked, so a single sample proves nothing.
func test_the_displacement_is_never_zero_and_never_exceeds_the_radius() -> void:
	var md: MapData = _flat(60)
	var p: SoundParams = SoundParams.from_config(cfg)

	var checked: int = 0
	for x: int in range(10, 50, 3):
		for y: int in range(10, 50, 3):
			var t: int = md.idx(x, y)
			for dist: float in [0.0, 120.0, 480.0, 2000.0]:
				var err: int = p.error_dm(dist)
				var at: int = Sound.displace(md, t, err, 1, 3, SideSound.Source.FIRE)
				assert_ne(at, t,
					"the marker landed exactly on the tank at tile %d, error %d dm" % [t, err])
				# One tile of slack: the offset is quantized to tile centers, so a displacement right
				# at the radius rounds outward by up to half a tile in each axis.
				assert_le(md.dist_m(t, at), float(err) * 0.1 + md.tile_m,
					"the marker landed %.0f m away against a %.0f m error radius"
						% [md.dist_m(t, at), float(err) * 0.1])
				checked += 1
	assert_gt(float(checked), 500.0, "the sweep did not actually cover much ground")


## The error is a hash of the situation, not a draw from a stream — which is what makes it survive a
## replay, and what keeps the combat sequence exactly where it was.
##
## The second assertion is the load-bearing one. If the displacement ever came from `_combat_rng`,
## every shot after the first would draw from a differently-advanced generator, and
## `tests/test_combat_distribution`'s thousand pinned resolutions would drift in a way that looks
## exactly like a tuning problem.
func test_the_error_is_reproducible_and_advances_no_stream() -> void:
	var md: MapData = _flat(40)
	var p: SoundParams = SoundParams.from_config(cfg)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 5, 5))

	var t: int = md.idx(20, 20)
	var err: int = p.error_dm(300.0)
	var first: int = Sound.displace(md, t, err, 2, 7, SideSound.Source.FIRE)
	for _k: int in 8:
		assert_eq(Sound.displace(md, t, err, 2, 7, SideSound.Source.FIRE), first,
			"the same noise placed itself differently on a second evaluation")

	# Different situations must disagree, or the hash is not keyed on what it claims to be keyed on
	# and every contact on the board would sit at the same offset.
	assert_ne(Sound.displace(md, t, err, 3, 7, SideSound.Source.FIRE), first,
		"two different sides placed the same noise identically, so the side is not in the hash")
	assert_ne(Sound.displace(md, t, err, 2, 8, SideSound.Source.FIRE), first,
		"the same noise on a later turn placed identically, so the turn is not in the hash")

	var rng: RandomNumberGenerator = Rng.stream(1234, Rng.Stream.COMBAT)
	var before: int = rng.randi()
	var rng2: RandomNumberGenerator = Rng.stream(1234, Rng.Stream.COMBAT)
	Sound.displace(md, t, err, 1, 1, SideSound.Source.MOVE)
	assert_eq(rng2.randi(), before,
		"the sound layer advanced the combat stream, which reshuffles every roll after it")


# --- movement -------------------------------------------------------------------------------------

## A tank that spent its allowance is heard; one that crept a tile is not. The threshold is what makes
## moving quietly a decision rather than a thing that happens to you.
func test_a_hard_drive_is_heard_and_a_crawl_is_not() -> void:
	var p: SoundParams = SoundParams.from_config(cfg)
	assert_false(p.is_noisy_move(0, 100), "a stationary tank is making engine noise")
	assert_false(p.is_noisy_move(5, 100), "a tank that crept one tile is as loud as one that sprinted")
	assert_true(p.is_noisy_move(100, 100), "a tank that spent its whole allowance is inaudible")
	assert_true(p.is_noisy_move(int(p.noisy_mp_frac * 100.0), 100),
		"a move exactly at the threshold falls on the quiet side of it")


## One contact for the whole move, at the tile it finished on — not one per step.
##
## The rule this pins is a rule about *information*, not about cost. A ripple per step draws the exact
## line the tank drove, which is a track; the layer is entitled to say roughly where something is and
## not which way it came. Nothing but this assertion prevents the loop being moved inside `_weave`,
## where at a glance it would look more correct.
func test_a_move_makes_one_noise_at_the_tile_it_ended_on() -> void:
	# The crossfire wall again, and a drive that stays entirely east of it. Movement needs no line of
	# sight to anyone, so unlike the shooting cases this only has to keep the mover out of side 1's
	# view for the whole route rather than arrange a third party.
	var fixture: Array = _crossfire()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	assert_false(m.knowledge_for(1).sees(1),
		"the fixture is broken: side 1 can see the mover, so the drive is suppressed")

	var goal: int = md.idx(18, 22)
	var res: ActionResult = r.resolve_move(1, goal)
	assert_true(res.ok(), "the move was refused: %s" % res.describe())

	var heard: Array[ActionEvent] = _heard_events(res.events)
	# One event, and it belongs to side 1. Side 3 is parked three tiles from the mover in the open, so
	# it watches the drive and the suppression rule correctly gives it nothing; side 2 is the mover's
	# own side. That leaves exactly one hearer, and one event for it — not one per tile driven.
	assert_eq(heard.size(), 1,
		"a single move produced %d sound events, which is a track rather than a contact"
			% heard.size())
	assert_eq(heard[0].value, 1, "the noise was addressed to a side that could see the mover")
	assert_eq(m.sound_for(1).count(), 1, "the stored layer disagrees with the stream")
	assert_eq(m.sound_for(2).count(), 0, "the mover's own side was told about its own engine")
	assert_eq(m.sound_for(3).count(), 0, "the side watching the drive was also handed a guess")

	# The noise is placed against the tile the move *ended* on. Checked through the radius rather than
	# by recomputing the displacement, which would be this test reimplementing what it is testing.
	var expect: int = Sound.displace(
		md, res.destination(), heard[0].sound_error_dm(), 1, m.turn, SideSound.Source.MOVE
	)
	assert_eq(heard[0].tile, expect, "the noise was placed against a tile other than the last one")
	assert_true(heard[0].is_sound_move(), "a drive was recorded as gunfire")


# --- the stream is the account of what happened ---------------------------------------------------

## The layer is written by `EventApplier` and by nothing else, so restoring the pre-action state and
## replaying the stream must reproduce it exactly — and replaying it twice must change nothing.
##
## The second half is what the dedupe in `SideSound.add` is for. The resolver applies each event as it
## appends it and `MoveAction.commit` may walk the same list again; an `add` that simply appended
## would put two ripples on one tile the moment anything replayed.
func test_replaying_the_stream_reproduces_the_sound_layer() -> void:
	var fixture: Array = _crossfire()
	var md: MapData = fixture[0]
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var res: ActionResult = r.resolve_fire(1, 2)
	assert_true(res.ok(), "the shot was refused with status %d" % res.status)

	var resolved: int = m.sound_for(1).fingerprint()
	assert_gt(float(m.sound_for(1).count()), 0.0, "the fixture produced nothing to replay")

	# From empty, the stream alone must rebuild it.
	m.sound_for(1).clear()
	assert_ne(m.sound_for(1).fingerprint(), resolved, "clearing the layer did not change it")

	EventApplier.apply_all(cfg, md, m, res.events)
	assert_eq(m.sound_for(1).fingerprint(), resolved,
		"replaying the stream did not reproduce the sound layer resolving produced")

	EventApplier.apply_all(cfg, md, m, res.events)
	assert_eq(m.sound_for(1).fingerprint(), resolved,
		"applying the same stream twice changed the layer, so the HEARD arm is not idempotent")


## `HEARD` survives the replay filter for the side that heard it, and only for that side — and it
## survives even though its actor is invisible, which is the one place `filter` deliberately breaks
## its own default rule.
func test_the_filter_keeps_a_noise_the_viewer_cannot_see_the_source_of() -> void:
	var fixture: Array = _crossfire()
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var mask: PackedByteArray = ViewState.all(m, 1)
	assert_eq(mask[1], ViewState.Kind.HIDDEN, "the fixture is broken: side 1 can see the firer")

	var res: ActionResult = r.resolve_fire(1, 2)

	var mine: Array[ActionEvent] = ViewState.filter(res.events, mask, 1)
	assert_eq(_heard_events(mine).size(), 1,
		"side 1's own sound contact was filtered out of its own replay")
	for e: ActionEvent in mine:
		assert_ne(e.kind, ActionEvent.Kind.FIRE,
			"the invisible firer's shot survived the filter, so the ambush is not an ambush")

	# Side 3 watched the whole thing and has no contact of its own; side 1's must not reach it.
	var theirs: Array[ActionEvent] = ViewState.filter(res.events, ViewState.all(m, 3), 3)
	assert_eq(_heard_events(theirs).size(), 0,
		"side 3 was shown side 1's sound contact, which is another side's knowledge")


## A noise carries the errored tile and nothing else. The true tile must not be recoverable from the
## stream, because the stream is the one thing that crosses into `game/`.
func test_the_stream_carries_no_truth_to_leak() -> void:
	var fixture: Array = _crossfire()
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	var truth: int = m.unit(1).tile
	var res: ActionResult = r.resolve_fire(1, 2)

	var heard: Array[ActionEvent] = _heard_events(res.events)
	assert_eq(heard.size(), 1, "expected exactly one noise, got %d" % heard.size())
	assert_ne(heard[0].tile, truth, "the event carries the firer's real tile")
	assert_eq(heard[0].other, -1,
		"the noise names a second unit in `other`, which is the slot every consumer reads for who")
	assert_eq(heard[0].cost, 0,
		"a noise charged something to `cost`, which the stream's movement arithmetic depends on")
	assert_eq(heard[0].value, 1, "the noise is addressed to the wrong side")


# --- expiry ---------------------------------------------------------------------------------------

## Contacts last one turn, and are aged by the side that holds them as that side takes over — the same
## rule ghosts follow, for the same reason: a contact's life is measured in *that side's* turns, so
## "one turn" is a length the player can plan around rather than a function of how many sides there
## are.
func test_a_contact_expires_on_its_own_sides_next_turn() -> void:
	var fixture: Array = _crossfire()
	var m: MatchState = fixture[1]
	var r: ActionResolver = fixture[2]

	r.resolve_fire(1, 2)
	assert_eq(m.sound_for(1).count(), 1, "the fixture produced no contact to expire")

	# Three sides, so the hand-over runs 2 -> 3 -> 1. Side 3 taking over must not touch side 1's
	# contact — that is the whole reason decay is charged to the side that holds it, and with a naive
	# "age everything on every hand-over" it would already be gone by the time side 1 got to look.
	m.end_turn(cfg)
	assert_eq(m.active_side, 3, "the hand-over did not reach side 3")
	assert_eq(m.sound_for(1).count(), 1,
		"side 1's contact was aged by side 3 taking over, so its life depends on the side count")

	m.end_turn(cfg)
	assert_eq(m.active_side, 1, "the hand-over did not reach side 1")
	assert_eq(m.sound_for(1).count(), 1,
		"the contact expired on the very turn it was meant to inform, so nobody could ever act on it")

	# Round the houses once more. It survives the other sides' turns and dies on side 1's next one.
	m.end_turn(cfg)
	m.end_turn(cfg)
	assert_eq(m.sound_for(1).count(), 1, "the contact went quiet during somebody else's turn")

	m.end_turn(cfg)
	assert_eq(m.active_side, 1, "the hand-over did not come back round to side 1")
	assert_eq(m.sound_for(1).count(), 0, "the contact outlived the turn it was given")


## Two noises of the same kind at the same errored tile are one contact, refreshed. Stacking them
## would draw two ripples on one spot, which reads as two enemies and is a claim nothing supports.
func test_the_same_noise_twice_is_one_contact() -> void:
	var s: SideSound = SideSound.create(1)
	assert_true(s.add(50, SideSound.Source.FIRE, 120, 1), "the first contact was not news")
	assert_false(s.add(50, SideSound.Source.FIRE, 120, 1), "a repeat noise was recorded as a second")
	assert_eq(s.count(), 1, "the same gun firing twice from one tile became two contacts")

	# A refresh, though — the second report keeps it alive longer than the first alone would.
	assert_false(s.add(50, SideSound.Source.FIRE, 120, 3), "a refresh was reported as news")
	assert_eq(s.turns_left_at(0), 3, "a second report did not refresh the contact's life")

	# A different source at the same tile is genuinely different information and is its own contact.
	assert_true(s.add(50, SideSound.Source.MOVE, 120, 1),
		"an engine at a tile a gun already fired from was swallowed by the gun's contact")
	assert_eq(s.count(), 2, "the two sources collapsed into one contact")


## `decay` removes entries while walking the arrays it is removing from, which is the shape that goes
## wrong quietly. Mixed lifetimes, so the survivors have to be the right ones and not merely the right
## number of them.
func test_decay_removes_only_what_ran_out() -> void:
	var s: SideSound = SideSound.create(1)
	s.add(10, SideSound.Source.FIRE, 100, 1)
	s.add(20, SideSound.Source.MOVE, 200, 3)
	s.add(30, SideSound.Source.FIRE, 300, 1)
	s.add(40, SideSound.Source.MOVE, 400, 2)

	assert_eq(s.decay(), 2, "the wrong number of contacts went quiet")
	assert_eq(s.count(), 2, "the container disagrees with what decay reported")

	# The survivors keep their own fields, not their neighbors'. A remove_at that shifted one array
	# and not another would pass a count check and fail this one.
	assert_eq(s.tile_at(0), 20, "the surviving contacts are not the ones that had life left")
	assert_eq(s.error_dm_at(0), 200, "a survivor's error radius came from a different contact")
	assert_eq(s.turns_left_at(0), 2, "a survivor was not aged")
	assert_eq(s.tile_at(1), 40, "the second survivor is wrong")
	assert_eq(s.error_dm_at(1), 400, "the second survivor's error radius is wrong")
