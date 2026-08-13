extends TestCase

## What a side is entitled to see — docs/decisions/0034.
##
## **This suite is the iteration 2a acceptance check.** The spec asks that an unspotted enemy be absent
## from the rendered scene, and a rendered scene cannot be asserted headlessly. So the decision lives in
## `ViewState` and this file pins it; `game/` is a mechanical consumer with no discretion, and
## `tests/test_determinism.gd` is what keeps it that way.
##
## No spotting happens here. Whether a tank *can* see another tank is `tests/test_spotting.gd`'s
## problem and knowledge is driven by hand below, for the reason `tests/test_knowledge.gd` gives:
## separating the two is what makes a failure here unambiguous.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


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


## One unit a side. Index 0 is side 1's, index 1 is side 2's, and neither side knows anything yet.
func _pair(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 10))
	m.add_unit(_unit(md, 2, 14, 10))
	return m


# --- the headline claim ---------------------------------------------------------------------------

## The acceptance check itself: an enemy nobody has spotted is `HIDDEN`, and `HIDDEN` draws nothing.
##
## Not dimmed, not a marker, not a silhouette at reduced alpha. Absent. A renderer that drew a faded
## tank here would still be handing the player the position, which is the whole of what was wrong.
func test_an_unspotted_enemy_is_absent() -> void:
	var m: MatchState = _pair(_flat())

	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.HIDDEN, "an unspotted enemy is not hidden")
	assert_false(ViewState.is_drawn(ViewState.of(m, 1, 1)), "an unspotted enemy is drawn")
	assert_eq(ViewState.pose(m, 1, 1), Vector3i(-1, -1, -1),
		"an unspotted enemy reported a position")


## Knowledge is side-level and asymmetric (0024), and so is what gets drawn. Side 1 spotting side 2
## must give side 2 nothing at all — the two answers come from different `SideKnowledge` instances and
## a renderer keyed on the wrong one would quietly show each player the other's intelligence.
func test_what_is_drawn_is_asymmetric() -> void:
	var m: MatchState = _pair(_flat())
	m.knowledge_for(1).mark_seen(1)

	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.SEEN, "side 1 cannot see what it has spotted")
	assert_eq(ViewState.of(m, 2, 0), ViewState.Kind.HIDDEN,
		"side 1 spotting side 2 also revealed side 1")


# --- the four visible kinds -----------------------------------------------------------------------

## A live contact draws at the unit's actual tile and with its actual turret bearing, because that is
## what `SEEN` means. The turret is the point of the assertion: it is the most legible thing on a tank
## and it is information a sighting genuinely buys.
func test_a_seen_enemy_draws_at_its_true_pose() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md)
	m.unit(1).turret = Grid.NW
	m.knowledge_for(1).mark_seen(1)

	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.SEEN, "a spotted enemy is not seen")
	assert_eq(ViewState.pose(m, 1, 1), Vector3i(md.idx(14, 10), Grid.E, Grid.NW),
		"a seen enemy is not drawn at its true pose")
	assert_almost_eq(ViewState.fade(m, 1, 1, 2), 0.0, 0.0001, "a live contact is fading")


## A ghost stays where contact was lost while the unit drives away, and it fades. The tile assertion is
## the one that matters: a ghost that followed its unit around would be perfect intelligence wearing a
## dim color, which is the failure `MatchState.contact` was centralised to prevent.
func test_a_ghost_stays_where_contact_was_lost_and_fades() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md)
	var k: SideKnowledge = m.knowledge_for(1)
	var lost_at: int = md.idx(14, 10)

	k.mark_seen(1)
	k.mark_lost(1, lost_at, Grid.S, 2)

	# The unit drives on after contact is broken. The ghost must not.
	m.unit(1).tile = md.idx(18, 10)
	m.unit(1).facing = Grid.N

	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.GHOST, "a lost contact is not a ghost")
	assert_eq(ViewState.pose(m, 1, 1), Vector3i(lost_at, Grid.S, Grid.S),
		"the ghost followed its unit instead of staying where it was lost")
	assert_almost_eq(ViewState.fade(m, 1, 1, 2), 0.0, 0.0001, "a fresh ghost is already stale")

	k.decay()
	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.GHOST, "the ghost went cold a turn early")
	assert_almost_eq(ViewState.fade(m, 1, 1, 2), 0.5, 0.0001, "the ghost is not half way through its life")

	k.decay()
	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.HIDDEN, "a cold ghost is still drawn")
	assert_eq(ViewState.pose(m, 1, 1), Vector3i(-1, -1, -1), "a cold ghost reported a position")


## Your own units are yours to know, wherever they are and whatever they have been doing.
func test_your_own_units_are_always_your_own() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md)
	m.unit(0).turret = Grid.SW

	assert_eq(ViewState.of(m, 1, 0), ViewState.Kind.OWN, "a side cannot see its own unit")
	assert_eq(ViewState.pose(m, 1, 0), Vector3i(md.idx(4, 10), Grid.E, Grid.SW),
		"a side's own unit is not drawn at its own pose")


## **A wreck is terrain.** 0031 puts a destroyed unit into `MapData.blocker_dyn`, which reaches `Los`
## for every side with no knowledge gate; and `Spotting.can_see` refuses dead units, so its contact
## goes ghost and then cold. Gating the visual on knowledge would make a burning hulk wink out while it
## went on blocking line of sight — the view disagreeing with the model.
##
## So: never spotted, never known, still drawn.
func test_a_wreck_is_terrain_and_needs_no_contact() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md)
	m.unit(1).alive = false

	assert_false(m.knowledge_for(1).knows_of(1), "the fixture spotted the wreck after all")
	assert_eq(ViewState.of(m, 1, 1), ViewState.Kind.WRECK, "an unknown wreck is not drawn")
	assert_eq(ViewState.pose(m, 1, 1), Vector3i(md.idx(14, 10), Grid.E, Grid.E),
		"a wreck is not drawn where it died")
	assert_almost_eq(ViewState.fade(m, 1, 1, 2), 0.0, 0.0001, "a wreck is fading like a ghost")


## A wreck of your own is a wreck, not an `OWN` tank. The dead check runs before the side check, and
## this is what says so.
func test_your_own_wreck_is_a_wreck() -> void:
	var m: MatchState = _pair(_flat())
	m.unit(0).alive = false
	assert_eq(ViewState.of(m, 1, 0), ViewState.Kind.WRECK, "a side's own wreck still reads as a tank")


# --- the bulk form --------------------------------------------------------------------------------

func test_all_answers_for_every_unit_in_index_order() -> void:
	var md: MapData = _flat()
	var m: MatchState = _pair(md)
	m.add_unit(_unit(md, 2, 16, 10))
	m.knowledge_for(1).mark_seen(1)

	var kinds: PackedByteArray = ViewState.all(m, 1)
	assert_eq(kinds.size(), 3, "the mask does not cover every unit")
	assert_eq(kinds[0], ViewState.Kind.OWN, "unit 0 is not own")
	assert_eq(kinds[1], ViewState.Kind.SEEN, "unit 1 is not seen")
	assert_eq(kinds[2], ViewState.Kind.HIDDEN, "unit 2 is not hidden")

	for k: int in kinds.size():
		assert_eq(kinds[k], ViewState.of(m, 1, k), "the bulk answer disagrees for unit %d" % k)


func test_an_out_of_range_unit_is_hidden_rather_than_an_error() -> void:
	var m: MatchState = _pair(_flat())
	assert_eq(ViewState.of(m, 1, 99), ViewState.Kind.HIDDEN, "a nonexistent unit is drawn")
	assert_eq(ViewState.of(m, 7, 1), ViewState.Kind.HIDDEN, "a nonexistent side sees something")


# --- the replay filter ----------------------------------------------------------------------------
#
# Hand-built streams here; `tests/test_replay_filter.gd` runs the same rules over streams a resolver
# actually produced. Both are worth having — this one says what the rule is, that one says the rule
# survives contact with the weave.


func _mask(kinds: Array[int]) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(kinds.size())
	for k: int in kinds.size():
		out[k] = kinds[k]
	return out


## An unspotted enemy driving past must contribute nothing at all to what the player watches.
func test_an_unseen_movers_whole_stream_is_dropped() -> void:
	var events: Array[ActionEvent] = [
		ActionEvent.begin(1, 100, Grid.E, 200),
		ActionEvent.step(1, 101, Grid.E, 10, 190, 0),
		ActionEvent.step(1, 102, Grid.E, 10, 180, 0),
		ActionEvent.finish(1, 102, Grid.E, 180),
	]
	var out: Array[ActionEvent] = ViewState.filter(
		events, _mask([ViewState.Kind.OWN, ViewState.Kind.HIDDEN]), 1
	)
	assert_eq(out.size(), 0, "an unspotted enemy's move was replayed")


## The reveal lands on the step that earned it (0025), so the filtered stream must contain no position
## for the mover before the `SPOT` — and the `SPOT` itself must survive, because it carries the tile
## the tank is entitled to appear at.
func test_a_mid_path_reveal_hides_everything_before_it() -> void:
	var events: Array[ActionEvent] = [
		ActionEvent.begin(1, 100, Grid.E, 200),
		ActionEvent.step(1, 101, Grid.E, 10, 190, 0),
		ActionEvent.spot(1, 1, 1, 101, Grid.E, 190),
		ActionEvent.step(1, 102, Grid.E, 10, 180, 0),
		ActionEvent.finish(1, 102, Grid.E, 180),
	]
	var out: Array[ActionEvent] = ViewState.filter(
		events, _mask([ViewState.Kind.OWN, ViewState.Kind.HIDDEN]), 1
	)

	assert_eq(out.size(), 3, "the filtered stream is not reveal, step, end")
	assert_eq(out[0].kind, ActionEvent.Kind.SPOT, "the stream does not open on the reveal")
	assert_eq(out[0].tile, 101, "the reveal does not carry the tile it was earned at")
	assert_eq(out[1].kind, ActionEvent.Kind.STEP, "the step after the reveal was dropped")
	assert_eq(out[1].tile, 102, "the wrong step survived")

	for e: ActionEvent in out:
		assert_ne(e.tile, 100, "a tile from before the reveal survived the filter")


## Losing contact keeps the `LOST` — it is what puts the ghost down — and drops everything after it.
func test_losing_contact_mid_stream_stops_the_replay_there() -> void:
	var events: Array[ActionEvent] = [
		ActionEvent.begin(1, 100, Grid.E, 200),
		ActionEvent.step(1, 101, Grid.E, 10, 190, 0),
		ActionEvent.lost(1, 1, 1, 101, Grid.E, 190),
		ActionEvent.step(1, 102, Grid.E, 10, 180, 0),
		ActionEvent.finish(1, 102, Grid.E, 180),
	]
	var out: Array[ActionEvent] = ViewState.filter(
		events, _mask([ViewState.Kind.OWN, ViewState.Kind.SEEN]), 1
	)

	assert_eq(out.size(), 3, "the filtered stream is not begin, step, lost")
	assert_eq(out[2].kind, ActionEvent.Kind.LOST, "the stream does not end on the loss")
	assert_eq(out[2].tile, 101, "the loss does not carry the tile the ghost is left on")

	for e: ActionEvent in out:
		assert_ne(e.tile, 102, "a tile from after contact was lost survived the filter")


## Another side's knowledge is not yours to watch. A `SPOT` addressed to side 2 must neither be
## replayed to side 1 nor reveal anything to it.
func test_another_sides_knowledge_change_is_dropped_whole() -> void:
	var events: Array[ActionEvent] = [
		ActionEvent.spot(0, 1, 2, 101, Grid.E, 190),
		ActionEvent.step(1, 102, Grid.E, 10, 180, 0),
	]
	var out: Array[ActionEvent] = ViewState.filter(
		events, _mask([ViewState.Kind.OWN, ViewState.Kind.HIDDEN]), 1
	)
	assert_eq(out.size(), 0, "side 2's reveal was replayed to side 1, or revealed the unit to it")


## A round out of nowhere is the correct experience of being ambushed: the shot events of a firer the
## player cannot see are dropped along with its movement. What lands is the wreck, because of what
## `of` says about wrecks.
func test_an_unseen_firers_shots_are_dropped_but_the_wreck_is_not() -> void:
	var events: Array[ActionEvent] = [
		ActionEvent.fire(1, 0, 0, 200, Grid.W, 0, 5),
		ActionEvent.hit(1, 0, 200, 0, Armor.Facing.FRONT, true),
		ActionEvent.destroyed(1, 0, 200, 0),
	]
	var out: Array[ActionEvent] = ViewState.filter(
		events, _mask([ViewState.Kind.OWN, ViewState.Kind.HIDDEN]), 1
	)

	assert_eq(out.size(), 1, "an unspotted firer's shot was replayed")
	assert_eq(out[0].kind, ActionEvent.Kind.DESTROYED, "the kill was not the event that survived")


## The mask is a snapshot taken once, and the stream carries every change after that. Filtering must
## not mutate what it was handed, or a second viewer of the same turn would be filtered against the
## first viewer's outcome.
func test_filtering_does_not_disturb_the_mask_it_was_given() -> void:
	var mask: PackedByteArray = _mask([ViewState.Kind.OWN, ViewState.Kind.HIDDEN])
	var events: Array[ActionEvent] = [ActionEvent.spot(1, 1, 1, 101, Grid.E, 190)]

	ViewState.filter(events, mask, 1)

	assert_eq(mask[1], ViewState.Kind.HIDDEN, "the filter wrote through to the caller's mask")
