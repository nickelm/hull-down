extends TestCase

## `SideKnowledge` as a state machine — docs/decisions/0024.
##
## No map and no units in most of this file, deliberately. Whether a tank can *see* another tank is
## `tests/test_spotting.gd`'s problem; this is only about what a side remembers once it has been told,
## and separating the two is what makes a failure here unambiguous.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _k(units: int = 4) -> SideKnowledge:
	return SideKnowledge.create(1, units)


# --- the state machine ----------------------------------------------------------------------------

func test_a_side_starts_knowing_nothing() -> void:
	var k: SideKnowledge = _k()
	for u: int in 4:
		assert_eq(k.state_of(u), SideKnowledge.State.UNKNOWN, "unit %d starts known" % u)
		assert_false(k.sees(u), "unit %d starts visible" % u)
		assert_false(k.knows_of(u), "unit %d starts remembered" % u)
	assert_eq(k.known_units().size(), 0, "a fresh side knows of something")


## The return value is what drives `SPOT` emission, so it has to mean *news* and not *true*. A second
## call for a contact already in hand must be silent, or the stream fills with duplicate reveals and
## the presentation layer flashes a marker that never went away.
func test_seeing_something_twice_is_news_only_once() -> void:
	var k: SideKnowledge = _k()
	assert_true(k.mark_seen(2), "the first sighting was not reported as news")
	assert_false(k.mark_seen(2), "the second sighting was reported as news again")
	assert_true(k.sees(2), "the contact is not held")


func test_losing_something_never_seen_is_not_an_event() -> void:
	var k: SideKnowledge = _k()
	assert_false(k.mark_lost(1, 10, Grid.N, 2), "losing an unknown unit was reported as a loss")
	assert_eq(k.state_of(1), SideKnowledge.State.UNKNOWN, "an unknown unit became a ghost")


func test_a_lost_contact_becomes_a_ghost_where_it_was() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(0)
	assert_true(k.mark_lost(0, 137, Grid.SE, 2), "losing a held contact was not reported")

	assert_eq(k.state_of(0), SideKnowledge.State.GHOST, "a lost contact is not a ghost")
	assert_false(k.sees(0), "a ghost still reads as visible")
	assert_true(k.knows_of(0), "a ghost is not remembered at all")
	assert_eq(k.ghost_tile(0), 137, "the ghost is not where the unit was lost")
	assert_eq(k.ghost_facing(0), Grid.SE, "the ghost does not remember which way it was pointing")
	assert_eq(k.ghost_turns_left(0), 2, "the ghost did not start with its full life")


## A `SEEN` contact's position is deliberately not stored — it is the unit's own, and a second copy is
## a second thing to go stale (docs/decisions/0014 on `ap_left`). Asking anyway must return nothing
## rather than a number that happens to be lying around.
func test_a_live_contact_has_no_remembered_position() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(3)
	assert_eq(k.ghost_tile(3), -1, "a live contact reported a remembered tile")
	assert_eq(k.ghost_facing(3), -1, "a live contact reported a remembered facing")
	assert_eq(k.ghost_turns_left(3), 0, "a live contact is ageing")


## The stale position stays stale. That is the whole point of a ghost: it says where something *was*,
## and a ghost that quietly followed its unit would be perfect intelligence wearing a dim color.
func test_a_ghost_does_not_follow_the_unit_it_remembers() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(0)
	k.mark_lost(0, 137, Grid.SE, 2)
	k.decay()
	assert_eq(k.ghost_tile(0), 137, "the ghost moved between turns")


# --- decay ----------------------------------------------------------------------------------------

## Ghosts age in turns and go cold on schedule. `decay` returns the ones that expired, because the
## side has to be told a marker is gone as specifically as it was told one appeared.
func test_a_ghost_goes_cold_after_its_allotted_turns() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(0)
	k.mark_lost(0, 137, Grid.N, 2)

	assert_eq(k.decay().size(), 0, "a ghost expired one turn early")
	assert_eq(k.ghost_turns_left(0), 1, "the ghost did not age")
	assert_eq(k.state_of(0), SideKnowledge.State.GHOST, "the ghost went cold early")

	var expired: PackedInt32Array = k.decay()
	assert_eq(expired.size(), 1, "the expiry was not reported")
	assert_eq(expired[0], 0, "the wrong contact expired")
	assert_eq(k.state_of(0), SideKnowledge.State.UNKNOWN, "an expired ghost is still remembered")
	assert_eq(k.ghost_tile(0), -1, "an expired ghost kept its position")


func test_decay_leaves_live_contacts_alone() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(1)
	for _turn: int in 5:
		assert_eq(k.decay().size(), 0, "a live contact expired")
	assert_true(k.sees(1), "a live contact decayed")


## Regaining a contact inside its ghost window puts it straight back to `SEEN` with a full life, and
## the stale position is dropped rather than kept alongside. Two answers to "where is it" is exactly
## the thing this class is shaped to avoid.
func test_seeing_a_ghost_again_makes_it_live() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(0)
	k.mark_lost(0, 137, Grid.N, 2)
	k.decay()

	assert_true(k.mark_seen(0), "regaining a ghost was not reported as news")
	assert_true(k.sees(0), "a regained contact is not live")
	assert_eq(k.ghost_tile(0), -1, "a regained contact kept its stale position")
	assert_eq(k.ghost_turns_left(0), 0, "a regained contact is still ageing")


## A ghost life of zero means no memory at all, and losing contact has to go straight to `UNKNOWN`
## rather than to a ghost that never ticks and therefore never expires.
func test_a_zero_ghost_life_leaves_nothing_behind() -> void:
	var k: SideKnowledge = _k()
	k.mark_seen(0)
	assert_true(k.mark_lost(0, 137, Grid.N, 0), "the loss was not reported")
	assert_eq(k.state_of(0), SideKnowledge.State.UNKNOWN, "a memoryless side kept a ghost")


# --- growth and identity --------------------------------------------------------------------------

## Units are only ever appended to `MatchState`, and growing the contact list must not disturb what is
## already in it — contacts are identified by unit index, so a resize that shifted anything would
## silently reattribute every sighting on the board.
func test_growing_the_roster_preserves_what_is_known() -> void:
	var k: SideKnowledge = _k(2)
	k.mark_seen(0)
	k.mark_lost(0, 55, Grid.W, 2)
	k.mark_seen(1)

	k.resize(5)
	assert_eq(k.size(), 5, "the contact list did not grow")
	assert_eq(k.state_of(0), SideKnowledge.State.GHOST, "an existing ghost was lost in the resize")
	assert_eq(k.ghost_tile(0), 55, "an existing ghost's position was lost in the resize")
	assert_true(k.sees(1), "an existing contact was lost in the resize")
	for u: int in range(2, 5):
		assert_eq(k.state_of(u), SideKnowledge.State.UNKNOWN, "a new slot arrived already known")


func test_known_units_reports_ghosts_and_sightings_in_order() -> void:
	var k: SideKnowledge = _k(6)
	k.mark_seen(4)
	k.mark_seen(1)
	k.mark_lost(1, 20, Grid.N, 2)

	var known: PackedInt32Array = k.known_units()
	assert_eq(known.size(), 2, "known_units did not report both")
	assert_eq(known[0], 1, "known_units is not ascending")
	assert_eq(known[1], 4, "known_units is not ascending")

	var seen: PackedInt32Array = k.seen_units()
	assert_eq(seen.size(), 1, "seen_units counted the ghost")
	assert_eq(seen[0], 4, "seen_units reported the wrong contact")


## Out-of-range indices answer rather than crash. A knowledge query runs against whatever unit index
## the caller has, and a resolver mid-weave is exactly where an off-by-one would land.
func test_an_index_outside_the_roster_is_simply_unknown() -> void:
	var k: SideKnowledge = _k(2)
	for u: int in [-1, 2, 999]:
		assert_eq(k.state_of(u), SideKnowledge.State.UNKNOWN, "index %d was not unknown" % u)
		assert_false(k.mark_seen(u), "index %d could be marked seen" % u)
		assert_false(k.mark_lost(u, 0, 0, 2), "index %d could be marked lost" % u)


# --- fingerprint ----------------------------------------------------------------------------------

## The replay checks in later batches compare knowledge with one integer rather than an element-wise
## walk, so the fingerprint has to move for every field it covers. A digest that ignored a field is
## one that reports agreement it did not check.
func test_the_fingerprint_moves_for_every_field_it_covers() -> void:
	var base: SideKnowledge = _k()
	assert_eq(_k().fingerprint(), base.fingerprint(), "two identical sides fingerprint differently")

	var seen: SideKnowledge = _k()
	seen.mark_seen(1)
	assert_ne(seen.fingerprint(), base.fingerprint(), "a sighting did not move the fingerprint")

	var ghost: SideKnowledge = _k()
	ghost.mark_seen(1)
	ghost.mark_lost(1, 40, Grid.N, 2)
	assert_ne(ghost.fingerprint(), seen.fingerprint(), "losing contact did not move the fingerprint")

	var elsewhere: SideKnowledge = _k()
	elsewhere.mark_seen(1)
	elsewhere.mark_lost(1, 41, Grid.N, 2)
	assert_ne(elsewhere.fingerprint(), ghost.fingerprint(),
		"a ghost one tile over fingerprints the same")

	var turned: SideKnowledge = _k()
	turned.mark_seen(1)
	turned.mark_lost(1, 40, Grid.S, 2)
	assert_ne(turned.fingerprint(), ghost.fingerprint(),
		"a ghost facing the other way fingerprints the same")

	var aged: SideKnowledge = _k()
	aged.mark_seen(1)
	aged.mark_lost(1, 40, Grid.N, 2)
	aged.decay()
	assert_ne(aged.fingerprint(), ghost.fingerprint(), "ageing did not move the fingerprint")


# --- the turn boundary ----------------------------------------------------------------------------

func _flat(size: int = 20) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int) -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), "medium")
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


## Every side gets a contact list, sized to the roster, and adding a unit grows all of them. A side
## whose list was short would answer `UNKNOWN` for the newest unit on the board forever.
func test_every_side_has_a_contact_list_that_tracks_the_roster() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	assert_eq(m.knowledge.size(), 2, "a two-sided match did not get two contact lists")

	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 5, 5))
	for side: int in [1, 2]:
		assert_eq(m.knowledge_for(side).size(), 2,
			"side %d's contact list did not grow with the roster" % side)

	assert_eq(m.knowledge_for(0), null, "there is no side 0")
	assert_eq(m.knowledge_for(3), null, "there is no side 3 in a two-sided match")


## A ghost's life is measured in *that side's* turns, so it ages once per hand-over back to it and not
## once per hand-over. In a two-sided match that is every other call, and getting it wrong makes
## `ghost_turns: 2` quietly mean one round.
func test_a_ghost_ages_on_its_own_sides_turn_and_not_the_enemys() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 18, 18))

	var k: SideKnowledge = m.knowledge_for(1)
	k.mark_seen(1)
	k.mark_lost(1, 300, Grid.N, 2)

	m.end_turn(cfg)  # side 2's turn: side 1's ghost must not age
	assert_eq(k.ghost_turns_left(1), 2, "a ghost aged during the enemy's turn")

	m.end_turn(cfg)  # back to side 1
	assert_eq(k.ghost_turns_left(1), 1, "a ghost did not age when its own side took over")


## The reveal flag has exactly one place it can be cleared, and it is the firer's own `begin_turn`.
## That is what makes it survive the enemy's entire turn — a flag cleared at the end of the firing
## turn would be a muzzle flash nobody was looking at yet.
func test_firing_reveals_a_unit_until_its_own_next_turn() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 2))
	m.add_unit(_unit(md, 2, 18, 18))

	var firer: UnitState = m.unit(0)
	firer.fired_this_turn = true

	m.end_turn(cfg)
	assert_true(firer.fired_this_turn, "the reveal flag cleared before the enemy had their turn")

	m.end_turn(cfg)
	assert_false(firer.fired_this_turn, "the reveal flag survived the firer's own next turn")


func test_beginning_a_turn_clears_what_the_unit_did_last_turn() -> void:
	var md: MapData = _flat()
	var u: UnitState = _unit(md, 1, 2, 2)
	u.mp_moved = 90
	u.fired_this_turn = true
	u.mp_left = 4
	u.activated = true

	u.begin_turn(cfg)
	assert_eq(u.mp_moved, 0, "begin_turn did not clear the distance driven")
	assert_false(u.fired_this_turn, "begin_turn did not clear the reveal flag")
	assert_eq(u.mp_left, u.mp_max, "begin_turn did not restore movement points")
	assert_false(u.activated, "begin_turn left the unit marked as having acted")
