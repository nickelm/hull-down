class_name Sound
extends RefCounted

## Who hears what, and how wrong they are about where it came from — docs/decisions/0037.
##
## The sibling of `Spotting`, and the differences are the interesting part. `Spotting` casts rays,
## because a sighting needs line of sight; nothing here consults `Los` at any point, and a radius is
## the whole test. `Spotting` mutates `SideKnowledge` and reports what changed, because it is the
## authority on the knowledge model; **nothing here mutates anything.** This only appends events, and
## `EventApplier` is the single writer of the sound layer.
##
## That asymmetry is deliberate and it is worth the inconsistency. `Spotting` has to mutate as it
## decides because the weave's next step reads the live board. A noise reads nothing back — no later
## check depends on whether an earlier contact was recorded — so the layer can be purely event-driven,
## and being purely event-driven means "the stream is the account of what happened" needs no
## argument for it at all.
##
## **Nothing here touches an RNG.** The positional error comes out of a hash of the situation rather
## than a draw from a stream, so the sound layer advances no generator, cannot reshuffle a combat
## roll, and reproduces the same wrong position on every replay by construction. That is a stronger
## version of the guarantee the COMBAT/CRITS split buys, and it is why no fifth `Rng.Stream` member
## was added for this.

## Distance from a noise at `true_tile` to the nearest **living** unit of `side`, or -1.0 if that side
## has none left. Linear over a handful of units; there is no index to keep in sync, and this is the
## same shape as `MatchState.unit_at`.
##
## Living, because a wreck does not listen. It goes on blocking and concealing — 0031 — and it stops
## being a reason your side places a noise well.
static func nearest_listener_m(
	md: MapData, state: MatchState, side: int, true_tile: int
) -> float:
	var best: float = -1.0
	for k: int in state.units.size():
		var u: UnitState = state.units[k]
		if u.side != side or not u.alive or u.tile < 0:
			continue
		var d: float = md.dist_m(true_tile, u.tile)
		if best < 0.0 or d < best:
			best = d
	return best


## Where the marker actually goes: `true_tile` pushed off by up to `error_dm` decimeters, on a bearing
## nobody can predict and everybody can reproduce.
##
## The offset is derived from `Rng.fnv1a` over the situation — the true tile, whose ears heard it,
## which turn, and what kind of noise — and not from a generator. Two consequences follow, and both
## are load-bearing. Adding this layer advances no stream, so `tests/test_combat_distribution`'s
## thousand pinned resolutions are unmoved by it. And a replay of the same stream recomputes the same
## displacement, so the errored tile in the event and the errored tile a fresh evaluation would
## produce are the same tile.
##
## Keying on the turn rather than on nothing means a unit that fires from the same spot on two
## consecutive turns is misplaced differently each time, which is right: each report is its own guess.
## Keying on the hearing side means two sides listening to the same gun disagree about where it is,
## which is also right, and is free.
##
## **The displacement is never zero.** A marker sitting exactly on the tank would be a sighting, and
## the player would read it as one; when the rounded offset collapses to the origin tile the dominant
## axis is pushed a tile regardless. Clamped into the map, because a guess may point at the edge of
## the world but a tile index may not.
static func displace(
	md: MapData, true_tile: int, error_dm: int, side: int, turn: int, source: int
) -> int:
	if true_tile < 0 or true_tile >= md.n:
		return true_tile
	if error_dm <= 0:
		return true_tile

	var h: int = Rng.fnv1a("sound %d %d %d %d" % [true_tile, side, turn, source])
	# Two independent draws out of one hash. `mix` avalanches, so the bearing and the radius do not
	# correlate — without it, a hash whose low bits chose the angle would leave the distance to the
	# same bits and every contact would be misplaced along a spiral.
	var bearing: int = Rng.ushr(Rng.mix(h, 1), 11) % 3600
	var reach: int = Rng.ushr(Rng.mix(h, 2), 11) % 1000

	var angle: float = deg_to_rad(float(bearing) * 0.1)
	# Bounded away from zero. A guess that happens to land dead on reads as certainty, and the whole
	# presentation argument in 0033 is that the marker must look like what it is.
	var frac: float = 0.35 + 0.65 * (float(reach) / 1000.0)
	var offset_m: float = float(error_dm) * 0.1 * frac

	var dx: int = int(round(cos(angle) * offset_m / md.tile_m))
	var dy: int = int(round(sin(angle) * offset_m / md.tile_m))
	if dx == 0 and dy == 0:
		# Sub-tile offsets round to nothing. Push a whole tile along whichever axis the bearing
		# favored, so "the marker is not on the tank" holds at every error radius rather than at most
		# of them.
		if absf(cos(angle)) >= absf(sin(angle)):
			dx = 1 if cos(angle) >= 0.0 else -1
		else:
			dy = 1 if sin(angle) >= 0.0 else -1

	var x: int = clampi(md.tx(true_tile) + dx, 0, md.size - 1)
	var y: int = clampi(md.ty(true_tile) + dy, 0, md.size - 1)
	return md.idx(x, y)


## Whether `side` would hear a noise of `source` made at `true_tile` — and if so, how badly placed.
## Returns the error radius in decimeters, or -1 for a side that hears nothing.
##
## Separate from `evaluate` because it is the pure half: a preview, a test, or a future AI can ask
## "would that be heard" without an event list to append to.
static func heard_error_dm(
	md: MapData, p: SoundParams, state: MatchState, side: int, source: int, true_tile: int
) -> int:
	var d: float = nearest_listener_m(md, state, side, true_tile)
	if d < 0.0 or d > p.radius_m(source):
		return -1
	return p.error_dm(d)


## Turn a noise into one `HEARD` event per side that heard it, appended to `out`.
##
## The noisemaker's own side is skipped: you do not report your own tank to yourself, and there is
## nothing a side could learn from a contact it could place exactly.
##
## **A side that already sees the noisemaker is skipped too**, and that is a rule rather than an
## optimisation. A ripple drawn over a tank you are looking at is clutter that says less than the tank
## does, and worse, it teaches the player that a ripple sometimes means a confirmed target. A side
## holding only a *ghost* of it still gets the contact: the ghost is a memory of where it used to be
## and the noise is evidence about now, which is exactly the case the layer exists for.
static func evaluate(
	md: MapData, p: SoundParams, state: MatchState,
	noisemaker: int, source: int, true_tile: int, mp: int, out: Array[ActionEvent]
) -> void:
	var n: UnitState = state.unit(noisemaker)
	if n == null or true_tile < 0 or true_tile >= md.n:
		return

	for side: int in range(1, state.side_count + 1):
		if side == n.side:
			continue
		var k: SideKnowledge = state.knowledge_for(side)
		if k != null and k.sees(noisemaker):
			continue

		var err: int = heard_error_dm(md, p, state, side, source, true_tile)
		if err < 0:
			continue

		out.append(ActionEvent.heard(
			noisemaker,
			side,
			displace(md, true_tile, err, side, state.turn, source),
			source,
			err,
			mp
		))
