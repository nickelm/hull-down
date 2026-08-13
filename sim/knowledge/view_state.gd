class_name ViewState
extends RefCounted

## What one side is entitled to see on screen — docs/decisions/0034.
##
## The renderer used to walk `MatchState.units` and draw all of it. The simulation has had full fog of
## war since 0024 and the presentation layer had none, which meant every enemy position was on screen
## the whole time and the spotting model was decoration. This is the rule that fixes that, and it lives
## here rather than in `game/` for one reason: "an unspotted enemy is absent from the rendered scene"
## cannot be asserted headlessly, and a decision that cannot be tested is one that drifts back.
##
## So the *decision* is pure code in `sim/` and the renderer is a mechanical consumer of it. What
## `game/` gets is a byte per unit and no discretion.
##
## Nothing here re-derives a rule that already has an owner. `MatchState.contact` owns "a live contact
## sits at the unit's tile, a ghost at a remembered one"; `Contact.staleness` owns ghost ageing;
## `SideKnowledge` owns the state machine. This only answers which of them applies.

## What to draw for one unit, from one side's point of view.
##
## `OWN` and `SEEN` are deliberately different values even though both draw a tank at its true tile.
## Only one of them may be posed from `UnitState` — see `MatchState.contact` — and a renderer that
## collapsed them would have no way left to tell the difference.
enum Kind {
	## Draw nothing. Not dimmed, not a marker: absent.
	HIDDEN = 0,
	## This side's own living unit. Posed from `UnitState`, because it is this side's to know.
	OWN = 1,
	## A living enemy in contact right now. Posed from its `Contact`, never from `UnitState`.
	SEEN = 2,
	## A remembered enemy at the tile it was lost on, fading over `spotting.ghost_turns`.
	GHOST = 3,
	## A wreck. Terrain, not a contact — see the note on `of`.
	WRECK = 4,
}

const KIND_NAMES: Array[String] = ["HIDDEN", "OWN", "SEEN", "GHOST", "WRECK"]


## What `viewing_side` may see of `unit_index`.
##
## The wreck arm is checked before the side arm and before knowledge, and that ordering is the rule.
## **A wreck is terrain.** 0031 puts a destroyed unit into `MapData.blocker_dyn`, where it blocks and
## conceals for *every* side with no knowledge gate anywhere in `Los`; and `Spotting.can_see` refuses
## dead units outright, so a wreck's contact goes ghost and then cold two turns later. Gating the
## visual on knowledge would therefore make a burning hulk wink out while it went on blocking line of
## sight — the view disagreeing with the model, which is the failure this whole class exists to stop.
## A hull that is still smoking is not a contact anybody has to earn.
static func of(state: MatchState, viewing_side: int, unit_index: int) -> int:
	var u: UnitState = state.unit(unit_index) if state != null else null
	if u == null:
		return Kind.HIDDEN
	# A wave that has not arrived is absent for everyone, its own side included — 2g. Checked before
	# the wreck arm because an off-board unit cannot be one; it has never stood anywhere.
	if not u.on_board:
		return Kind.HIDDEN
	if not u.alive:
		return Kind.WRECK
	if u.side == viewing_side:
		return Kind.OWN

	var k: SideKnowledge = state.knowledge_for(viewing_side)
	if k == null:
		return Kind.HIDDEN

	match k.state_of(unit_index):
		SideKnowledge.State.SEEN:
			return Kind.SEEN
		SideKnowledge.State.GHOST:
			return Kind.GHOST
		_:
			return Kind.HIDDEN


## Every unit at once, one byte each, indexed by unit. What a repaint walks.
##
## Packed rather than an `Array[int]` for the reason everything in `sim/` is: this is read once per
## repaint over every unit on the board, and boxing each entry as a Variant to hold a value that fits
## in a byte is the habit CLAUDE.md forbids even where it would not yet hurt.
##
## Reads knowledge only — no line of sight, no rays. `Spotting.recompute_side` is the expensive one and
## it already ran; this is a lookup.
static func all(state: MatchState, viewing_side: int) -> PackedByteArray:
	var out := PackedByteArray()
	if state == null:
		return out
	out.resize(state.units.size())
	for k: int in state.units.size():
		out[k] = of(state, viewing_side, k)
	return out


## Whether a kind puts anything on screen at all.
static func is_drawn(kind: int) -> bool:
	return kind != Kind.HIDDEN


## Where to draw a unit, as `(tile, hull facing, turret bearing)`. All -1 when it is not drawn.
##
## This is here, and not at the call site, for the same reason `MatchState.contact` exists: choosing
## between `UnitState` and `Contact` *is* the fog-of-war rule, and a renderer allowed to make that
## choice is a renderer one line away from making it wrong. `game/` asks where, not which.
##
## `OWN` and `WRECK` pose from `UnitState`; both are entitled to. Your own tank's position is yours,
## and a wreck is terrain — see `of`. `SEEN` and `GHOST` pose from the contact, which is where the
## live-tile-versus-remembered-tile rule already lives.
##
## A `Vector3i` rather than three calls because each call would build its own `Contact`, and this runs
## over every unit on every repaint.
static func pose(state: MatchState, viewing_side: int, unit_index: int) -> Vector3i:
	var kind: int = of(state, viewing_side, unit_index)
	if kind == Kind.HIDDEN:
		return Vector3i(-1, -1, -1)

	if kind == Kind.OWN or kind == Kind.WRECK:
		var u: UnitState = state.unit(unit_index)
		return Vector3i(u.tile, u.facing, u.turret)

	var c: Contact = state.contact(viewing_side, unit_index)
	if c == null:
		return Vector3i(-1, -1, -1)
	return Vector3i(c.tile, c.facing, c.turret)


## How faded a ghost is, 0.0 fresh to 1.0 about to go cold. Zero for everything else — a live contact
## is not ageing and a wreck does not fade. `ghost_turns` is `spotting.ghost_turns`, passed in because
## `sim/` classes do not reach for a `Config` they were not handed.
static func fade(state: MatchState, viewing_side: int, unit_index: int, ghost_turns: int) -> float:
	if of(state, viewing_side, unit_index) != Kind.GHOST:
		return 0.0
	var c: Contact = state.contact(viewing_side, unit_index)
	return c.staleness(ghost_turns) if c != null else 0.0


## The subset of an event stream `viewing_side` is entitled to watch — docs/decisions/0034.
##
## The replay is filtered **before** it reaches the player, not while it plays. That is the whole
## design: `ActionPlayer` holds no `MatchState` by construction (0022), so the one way it could leak a
## position is by being handed one, and the one place to stop that is here. A visibility branch inside
## the replayer would be a branch that has to be right in four `match` arms and stay right forever.
##
## `kinds` is a `ViewState.all` snapshot from the moment the stream begins. It is not consulted again:
## the stream carries its own knowledge changes, and walking them is what makes a reveal land on the
## step that earned it (0025) instead of at the end.
##
## The mask evolves on three kinds and three only:
##
##   * `SPOT` for this side turns a unit on. The event is kept because it carries the *target's* pose —
##     the tile the reveal was earned at, which the viewer is entitled to — so the replayer can put the
##     tank down there rather than sliding it in from wherever it was last drawn.
##   * `LOST` for this side turns it off, leaving a ghost.
##   * `DESTROYED` turns it on unconditionally, because of what `of` says about wrecks.
##
## Another side's `SPOT`/`LOST` is that side's knowledge and is dropped whole. Everything else survives
## only if its actor is visible, which drops an unspotted enemy's shots along with its movement: a round
## out of nowhere is the correct experience of being ambushed, and it is what iteration 2.5's sound
## contacts (0033) exist to complete.
static func filter(
	events: Array[ActionEvent], kinds: PackedByteArray, viewing_side: int
) -> Array[ActionEvent]:
	var out: Array[ActionEvent] = []

	var n: int = kinds.size()
	var visible := PackedByteArray()
	visible.resize(n)
	for k: int in n:
		visible[k] = 1 if is_drawn(kinds[k]) else 0

	for ev: ActionEvent in events:
		match ev.kind:
			ActionEvent.Kind.SPOT:
				if ev.value != viewing_side:
					continue
				if ev.other >= 0 and ev.other < n:
					visible[ev.other] = 1
				out.append(ev)
			ActionEvent.Kind.LOST:
				if ev.value != viewing_side:
					continue
				out.append(ev)
				if ev.other >= 0 and ev.other < n:
					visible[ev.other] = 0
			ActionEvent.Kind.DESTROYED:
				if ev.other >= 0 and ev.other < n:
					visible[ev.other] = 1
				out.append(ev)
			ActionEvent.Kind.HEARD:
				# The one arm that deliberately breaks the rule below, and the reason the sound layer
				# exists — docs/decisions/0033 and 0037. Every other kind survives only if its actor
				# is visible; this one survives *because* its actor is not. Gating a noise on seeing
				# who made it would mean you only ever hear what you can already see, which is the
				# layer doing nothing at all.
				#
				# It changes no visibility. A sound is not a reveal: hearing a gun does not put the
				# tank on screen, and `visible` is untouched on purpose so that nothing else in the
				# stream leaks through behind it.
				if ev.value == viewing_side:
					out.append(ev)
			_:
				if ev.unit >= 0 and ev.unit < n and visible[ev.unit] == 1:
					out.append(ev)

	return out


## A mechanical name, for tests and logs. `sim/` carries no English the player reads.
static func describe(kind: int) -> String:
	return KIND_NAMES[kind] if kind >= 0 and kind < KIND_NAMES.size() else "?"
