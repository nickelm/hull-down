class_name ActionEvent
extends RefCounted

## One thing that happened during an action, in the order it happened.
##
## An action resolves to an ordered list of these — docs/decisions/0022. The simulation applies the
## whole list instantly; the presentation layer replays it at whatever speed it likes. Nothing about
## the timing of that replay can reach back here, because there is nothing here to reach.
##
## This is one class with a `kind` discriminant rather than a hierarchy, and deliberately so.
## Iteration 2 interleaves *other units'* reactions into the same stream — an overwatch shot fired
## at the mover halfway along its path is an event between two of its steps — and a heterogeneous
## stream of subclasses would put an `is`-chain in every consumer. One dispatch table is enough.
##
## Every field means the same thing in every kind. Nothing is aliased per kind; a field that does
## not apply is left at its default. There are no speculative fields either: the shot events want an
## `other` and a `value` and they can have them when there are shots, because adding a field is one
## line and state nothing reads is a liability (docs/decisions/0014 on refusing `ap_left`).

## Kinds are **appended, never inserted.** `KIND_NAMES` is indexed by `kind` and feeds `describe()`,
## which feeds `ActionResult.fingerprint()`. Renumbering the enum would silently change the meaning of
## every fingerprint ever recorded, and a determinism check that quietly starts comparing different
## things is worse than no check.
enum Kind {
	## The unit is about to act. Carries its starting pose and what it has to spend.
	BEGIN = 0,
	## The **hull** turned on the spot. `facing` is what it now holds; `cost` is what the swing cost.
	TURN = 1,
	## Drove one tile. `tile` is the tile entered, `facing` the heading held while entering it.
	STEP = 2,
	## The unit has nothing left to do this turn.
	ACTIVATED = 3,
	## The action is over. Carries the final pose and what is left.
	END = 4,

	## The turret's absolute bearing changed. `facing` is the new bearing. Free; `cost` is 0.
	TURRET = 5,
	## Overwatch was laid along `facing`, or canceled when `facing` is -1.
	WATCH = 6,
	## `unit` newly saw `other`, for the side named in `value`. `tile` and `facing` are `other`'s pose.
	SPOT = 7,
	## The side named in `value` lost contact with `other`. `unit` is whoever's action broke it.
	LOST = 8,
	## A round left `unit`'s barrel at `other`. `value` is the shot's ordinal within the action.
	FIRE = 9,
	MISS = 10,
	## `flags` carries the plate struck and whether it was defeated.
	HIT = 11,
	## `value` millimeters came off `other`'s plate, on the facing in `flags`. Permanent — 0004.
	SHRED = 12,
	## `other`'s crew is shaken for `value` turns.
	SHAKEN = 13,
	## `flags` names the component. `other` is the unit crippled.
	CRITICAL = 14,
	DESTROYED = 15,

	## The side named in `value` heard `unit` — docs/decisions/0033 and 0037. `tile` is the
	## **errored** tile the contact is recorded at; the true one is not in this stream and cannot be
	## recovered from it. `other` is always -1: a noise names nobody.
	HEARD = 16,
}

## The step was driven backwards. The hull keeps its facing and slides along it.
const F_REVERSED: int = 1
## The step crossed a rough transition, so the unit cannot fire this turn.
const F_ROUGH: int = 2
## Bit 2 is spare. It was `F_FREE`, marking the free hull swivel 0032 gave and 0035 took away; the
## constant is gone rather than kept for a rainy day, because a flag nothing sets is a flag somebody
## eventually reads.
## The hit defeated the plate it struck.
const F_PENETRATED: int = 8
## The shot was reaction fire, not a deliberate action. Carried on every event of the chain so a
## consumer can tell an ambush from a turn taken — docs/decisions/0030.
const F_OVERWATCH: int = 512
## The noise was an engine rather than a gun. Means nothing outside a `HEARD`.
const F_SOUND_MOVE: int = 1024

## `flags` is a **kind-scoped** bitfield, which is what lets it carry the plate struck without
## aliasing `value` per kind — the thing this class's docstring refuses to do. `F_REVERSED` and
## `F_ROUGH` already mean nothing outside a `STEP`; these mean nothing outside a shot.
const PLATE_SHIFT: int = 4
const PLATE_MASK: int = 7 << PLATE_SHIFT
const COMPONENT_SHIFT: int = 7
const COMPONENT_MASK: int = 3 << COMPONENT_SHIFT

## A `HEARD`'s positional error, in decimeters, packed clear of every flag above. Twelve bits reaches
## 409.5 m against a `sound.error_max_m` of 200.
##
## Here rather than in `cost` deliberately, even though `FIRE` sets that precedent by carrying its
## ammunition there. `cost` is under an invariant the rest of the stream depends on —
## `mp_left == previous - cost`, which `tests/test_actions` walks a whole stream to check — and
## `flags` is the field this class has already designated for kind-scoped payloads.
const SOUND_ERR_SHIFT: int = 16
const SOUND_ERR_MASK: int = 0xFFF << SOUND_ERR_SHIFT

const KIND_NAMES: Array[String] = [
	"BEGIN", "TURN", "STEP", "ACTIVATED", "END",
	"TURRET", "WATCH", "SPOT", "LOST",
	"FIRE", "MISS", "HIT", "SHRED", "SHAKEN", "CRITICAL", "DESTROYED",
	"HEARD",
]

var kind: int = Kind.BEGIN
## Index into `MatchState.units`. Identity is positional in iteration 1.
var unit: int = -1
## The tile the event happens on. For `STEP`, the tile being entered.
var tile: int = -1
## The facing held once this event has happened. Hull on a `TURN`, turret on a `TURRET` or `WATCH`.
var facing: int = -1
## Movement points this event alone spent.
var cost: int = 0
## The unit's remaining movement points after this event. A snapshot, so a replay can drain a status
## bar from the stream without reading the simulation.
var mp_left: int = 0
var flags: int = 0
## The second unit the event involves: the target of a shot, the subject of a spot. -1 when none.
var other: int = -1
## The event's magnitude, in the unit natural to its kind — millimeters shredded, turns shaken, the
## side whose knowledge changed, a shot's ordinal. The kind says which. 0 when none.
var value: int = 0


static func make(
	k: int, u: int, t: int, f: int, c: int, mp: int, fl: int = 0, o: int = -1, v: int = 0
) -> ActionEvent:
	var e := ActionEvent.new()
	e.kind = k
	e.unit = u
	e.tile = t
	e.facing = f
	e.cost = c
	e.mp_left = mp
	e.flags = fl
	e.other = o
	e.value = v
	return e


static func begin(u: int, t: int, f: int, mp: int) -> ActionEvent:
	return make(Kind.BEGIN, u, t, f, 0, mp)


static func turn(u: int, t: int, f: int, c: int, mp: int) -> ActionEvent:
	return make(Kind.TURN, u, t, f, c, mp)


static func step(u: int, t: int, f: int, c: int, mp: int, fl: int) -> ActionEvent:
	return make(Kind.STEP, u, t, f, c, mp, fl)


static func activated(u: int, t: int, f: int, mp: int) -> ActionEvent:
	return make(Kind.ACTIVATED, u, t, f, 0, mp)


## Named `finish` rather than `end` because `end` reads as a keyword at every call site.
static func finish(u: int, t: int, f: int, mp: int) -> ActionEvent:
	return make(Kind.END, u, t, f, 0, mp)


## The turret swung to an absolute bearing. Free, so it carries no cost and does not move `mp_left`.
##
## The constructors for the shot and knowledge kinds land with the code that produces them. The
## *enum* is complete now because it is one edit to one list and renumbering it later is the one
## change this class cannot survive; a factory for an event nobody emits is just a guess about a
## signature.
static func turret(u: int, t: int, bearing: int, mp: int) -> ActionEvent:
	return make(Kind.TURRET, u, t, bearing, 0, mp)


## Overwatch laid along `bearing`, or canceled when `bearing` is -1. `value` is the shots remaining
## afterwards — an absolute snapshot, for the reason above.
static func watch(u: int, t: int, bearing: int, mp: int, shots_left: int) -> ActionEvent:
	return make(Kind.WATCH, u, t, bearing, 0, mp, 0, -1, shots_left)


## Side `side` newly saw `target`. `u` is whoever's action revealed it — usually the mover, which may
## well be the target itself walking into view.
##
## `tile` and `facing` are the **target's** pose, not the actor's, so a replay can put a marker down
## without reading the simulation. Every other kind names the actor's tile; this one cannot, because
## the interesting position is the one being revealed.
static func spot(u: int, target: int, side: int, tile: int, facing: int, mp: int) -> ActionEvent:
	return make(Kind.SPOT, u, tile, facing, 0, mp, 0, target, side)


## Side `side` lost contact with `target`. `tile` and `facing` are where the ghost is left.
static func lost(u: int, target: int, side: int, tile: int, facing: int, mp: int) -> ActionEvent:
	return make(Kind.LOST, u, tile, facing, 0, mp, 0, target, side)


## A round left the barrel. `value` is the shot's ordinal within the action, `mp_left` what the firer
## has after paying for it, and `cost` carries the **ammunition remaining** — the one place `cost`
## means something other than movement, and it means it because a shot's cost is a round.
static func fire(
	u: int, target: int, ordinal: int, tile: int, bearing: int, mp: int, ammo_left: int, fl: int = 0
) -> ActionEvent:
	return make(Kind.FIRE, u, tile, bearing, ammo_left, mp, fl, target, ordinal)


static func miss(u: int, target: int, tile: int, mp: int, fl: int = 0) -> ActionEvent:
	return make(Kind.MISS, u, tile, -1, 0, mp, fl, target, 0)


static func hit(
	u: int, target: int, tile: int, mp: int, plate: int, penetrated: bool, fl: int = 0
) -> ActionEvent:
	var flags: int = fl | ((plate & 7) << PLATE_SHIFT)
	if penetrated:
		flags |= F_PENETRATED
	return make(Kind.HIT, u, tile, -1, 0, mp, flags, target, 0)


static func shred(
	u: int, target: int, tile: int, mp: int, plate: int, mm: int, fl: int = 0
) -> ActionEvent:
	return make(Kind.SHRED, u, tile, -1, 0, mp, fl | ((plate & 7) << PLATE_SHIFT), target, mm)


static func shaken(u: int, target: int, tile: int, mp: int, turns: int, fl: int = 0) -> ActionEvent:
	return make(Kind.SHAKEN, u, tile, -1, 0, mp, fl, target, turns)


static func critical(
	u: int, target: int, tile: int, mp: int, component: int, fl: int = 0
) -> ActionEvent:
	return make(
		Kind.CRITICAL, u, tile, -1, 0, mp, fl | ((component & 3) << COMPONENT_SHIFT), target, 0
	)


static func destroyed(u: int, target: int, tile: int, mp: int, fl: int = 0) -> ActionEvent:
	return make(Kind.DESTROYED, u, tile, -1, 0, mp, fl, target, 0)


## Side `side` heard `u` and placed it, wrongly, at `errored_tile`.
##
## Deliberately **not** given the target-pose treatment `spot` and `lost` get. Those carry the
## subject's real tile because the viewer has earned it; this carries a tile the simulation knows to
## be wrong, and the true one is never an argument here, never a field, and so is never one edit away
## from being shipped to a renderer. `other` stays -1 for the same reason: it is the slot every
## consumer reads for "who", and a noise has no who.
##
## `cost` stays 0 and `mp_left` carries the ordinary snapshot, so the stream's movement arithmetic is
## untouched by a kind that has nothing to do with movement.
static func heard(
	u: int, side: int, errored_tile: int, source: int, error_dm: int, mp: int
) -> ActionEvent:
	var fl: int = (clampi(error_dm, 0, 0xFFF) << SOUND_ERR_SHIFT)
	if source == SideSound.Source.MOVE:
		fl |= F_SOUND_MOVE
	return make(Kind.HEARD, u, errored_tile, -1, 0, mp, fl, -1, side)


func is_sound_move() -> bool:
	return (flags & F_SOUND_MOVE) != 0


func sound_source() -> int:
	return SideSound.Source.MOVE if is_sound_move() else SideSound.Source.FIRE


func sound_error_dm() -> int:
	return (flags & SOUND_ERR_MASK) >> SOUND_ERR_SHIFT


func is_overwatch() -> bool:
	return (flags & F_OVERWATCH) != 0


func is_reversed() -> bool:
	return (flags & F_REVERSED) != 0


func is_rough() -> bool:
	return (flags & F_ROUGH) != 0


func penetrated() -> bool:
	return (flags & F_PENETRATED) != 0


func plate() -> int:
	return (flags & PLATE_MASK) >> PLATE_SHIFT


func component() -> int:
	return (flags & COMPONENT_MASK) >> COMPONENT_SHIFT


## A mechanical dump, for tests and logs. Not UI text — `sim/` carries no English the player reads.
##
## Every field, unconditionally, including the ones sitting at their defaults. A fingerprint has to be
## sensitive to a field that *should* have been set and was not, and serialising only what differs
## from the default makes "nobody set it" and "it is legitimately zero" the same string.
func describe() -> String:
	var name: String = KIND_NAMES[kind] if kind >= 0 and kind < KIND_NAMES.size() else "?"
	return "%s u%d o%d t%d f%d c%d v%d mp%d fl%d" % [
		name, unit, other, tile, facing, cost, value, mp_left, flags
	]
