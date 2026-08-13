class_name EventApplier
extends RefCounted

## The one function that knows how an event changes the world.
##
## docs/decisions/0026, which sharpens 0022 rather than weakening it. 0022 said an action resolves to
## an ordered list of events and `commit` walks that list into the state. That was one function doing
## two jobs — deciding what an event means, and being the mechanism by which an action takes effect —
## and reaction fire needs those separated.
##
## An overwatch shot fired at the mover's sixth tile has to see the damage the shot at its fourth
## tile did, and the spotting check at its seventh has to see that the mover is dead. A function that
## builds the whole list and *then* walks it cannot express that; a resolver that builds and applies
## in lockstep can, and it needs somewhere to put "and now apply this one". That somewhere is here.
##
## What this buys, and it is the reason to do it this way rather than inlining the same `match` in
## two places: "the event stream is the authoritative account of what happened" stops being a comment
## and becomes a test. Restore the pre-action state, loop `apply_all` over the final stream, and the
## result must equal what resolving produced. `tests/test_actions.gd` does exactly that.
##
## **The arms that are not arithmetic must be idempotent.** The resolver applies an event as it
## appends it and `MoveAction.commit` may apply the same list again, so an arm that adds rather than
## assigns is an arm that charges twice. `STEP` and `TURN` assign absolute snapshots — `ev.mp_left`
## is what the unit has *after* the event, not what the event cost — which is what makes replaying a
## movement stream safe any number of times.

## Apply one event. `md` is here because a destroyed unit writes cover into the map, and `cfg`
## because some arms read a rule; both are unused by the movement kinds and that is fine.
static func apply(cfg: Config, md: MapData, state: MatchState, ev: ActionEvent) -> void:
	if ev == null:
		return
	var u: UnitState = state.unit(ev.unit)
	if u == null:
		return
	# `u` is the actor. Kinds that change something about a *second* unit — a spot, a shot — read
	# `ev.other` for themselves, because `ev.unit` is who did it and not who it happened to.

	match ev.kind:
		ActionEvent.Kind.STEP:
			u.tile = ev.tile
			u.facing = ev.facing
			u.mp_left = ev.mp_left
			u.mp_moved = maxi(u.mp_max - ev.mp_left, u.mp_moved)
			# rules.md 2.4: crossing a rough transition costs the unit its shot for the turn.
			# Latching rather than assigning, so one bad step earlier in a path is not undone by a
			# smooth one after it — and setting a flag that is already set is idempotent.
			if ev.is_rough():
				u.fire_blocked = true
			# Moving digs the tank out, permanently — 2f, docs/decisions/0041. One-way, so replays
			# are idempotent; here rather than in the resolver so a scripted or replayed stream
			# enforces it identically.
			u.entrenched = false
		ActionEvent.Kind.TURN:
			u.facing = ev.facing
			u.mp_left = ev.mp_left
			# Turning the hull breaks the camouflage exactly as driving does (0041). Traversing the
			# turret emits TURRET, not TURN, and deliberately does not reach this.
			u.entrenched = false
			# `maxi` over the event's own absolute snapshot, never `+= ev.cost`. Adding would charge
			# twice on the second application, and every arm has to survive being replayed — the
			# resolver applies as it appends and `commit` may walk the same list again (0026).
			#
			# Reading `ev.mp_left` rather than `u.mp_left` is not redundant: it says this depends on
			# the event and not on which assignment above happened to run first.
			#
			# Only `STEP` and `TURN` feed this, which is what keeps it *movement* rather than spend.
			# Firing forfeits the rest of the action in progress (0021) and emits neither, so a tank
			# that stood still and shot does not read as having driven. It is revealed anyway, by
			# `fired_this_turn`, and for a better reason. Traversing the turret is free and moves
			# `mp_left` not at all, and emits `TURRET` rather than `TURN`, so it never reaches here.
			u.mp_moved = maxi(u.mp_max - ev.mp_left, u.mp_moved)
		ActionEvent.Kind.WATCH:
			u.overwatch_dir = ev.facing
			u.overwatch_shots_left = ev.value
			# Laying overwatch costs a whole action point and therefore forfeits the unused remainder
			# of the one in progress (0021), exactly as firing does. An absolute snapshot, computed by
			# the planner; the re-lay a turret order emits carries the unit's unchanged figure and so
			# costs nothing, which is what 0035 wants.
			u.mp_left = ev.mp_left
		ActionEvent.Kind.TURRET:
			u.turret = ev.facing
		ActionEvent.Kind.SPOT:
			# Idempotent by construction: `mark_seen` on a contact already held changes nothing and
			# reports nothing. The resolver has usually applied this already — `recompute_side` is
			# the authority on the knowledge model and mutates as it decides — so replaying the
			# stream has to be a no-op there and a real change when starting from the pre-action
			# state. Both work, because the event carries everything the change needs.
			var seen: SideKnowledge = state.knowledge_for(ev.value)
			if seen != null:
				seen.mark_seen(ev.other)
		ActionEvent.Kind.LOST:
			var lost: SideKnowledge = state.knowledge_for(ev.value)
			if lost != null:
				lost.mark_lost(ev.other, ev.tile, ev.facing, cfg.i("spotting.ghost_turns", 2))
		ActionEvent.Kind.HEARD:
			# The **only** writer of the sound layer — docs/decisions/0037. `Sound` decides and
			# appends and mutates nothing, unlike `Spotting`, which has to mutate as it decides
			# because the weave's next step reads the board back. Nothing ever reads a sound contact
			# back, so this layer gets to be purely event-driven — and "the stream is the account of
			# what happened" then needs no argument for it at all here.
			#
			# Idempotent through `add`, which treats a second noise of the same source at the same
			# errored tile as a refresh rather than a second contact. `ev.tile` is already the errored
			# tile: there is nothing to re-derive here and no `SoundParams` to do it with, which is
			# the point — the applier cannot disagree with the resolver about where the guess landed.
			var heard: SideSound = state.sound_for(ev.value)
			if heard != null:
				heard.add(ev.tile, ev.sound_source(), ev.sound_error_dm(), cfg.i("sound.turns", 1))
		ActionEvent.Kind.FIRE:
			# Absolute snapshots throughout, never decrements. `cost` carries the rounds remaining
			# and `mp_left` what the firer has after forfeiting the rest of the action in progress
			# (0021) — both computed by the resolver so that applying this twice lands in the same
			# place, and so the preview can show the price before the shot is taken.
			u.ammo = ev.cost
			u.mp_left = ev.mp_left
			u.fired_this_turn = true
			if ev.is_overwatch():
				u.overwatch_shots_left = maxi(u.overwatch_shots_left - 1, 0)
		ActionEvent.Kind.MISS, ActionEvent.Kind.HIT:
			# Neither changes anything. A hit's consequence is the event that follows it, which is
			# what makes "there are no null results" checkable by counting rather than by reading.
			pass
		ActionEvent.Kind.SHRED:
			Armor.shred(cfg, state.unit(ev.other), ev.plate(), ev.value)
		ActionEvent.Kind.SHAKEN:
			var shaken: UnitState = state.unit(ev.other)
			if shaken != null:
				# `maxi`, so a second shake does not stack and a replay does not extend it.
				shaken.shaken_turns = maxi(shaken.shaken_turns, ev.value)
		ActionEvent.Kind.CRITICAL:
			var hurt: UnitState = state.unit(ev.other)
			if hurt != null:
				if ev.component() == HitResolver.Component.IMMOBILISED:
					hurt.immobilised = true
				else:
					hurt.gun_damaged = true
		ActionEvent.Kind.DESTROYED:
			var dead: UnitState = state.unit(ev.other)
			if dead != null and dead.alive:
				dead.alive = false
				# The wreck stays where it died: the tile is still blocked, and it now carries cover
				# between the hull line and the turret line — a burning tank is a hull-down position.
				# docs/decisions/0031. Written to `blocker_dyn`, which is match state and is
				# deliberately outside `content_hash`, so no pinned seed moves.
				if dead.tile >= 0 and dead.tile < md.blocker_dyn.size():
					md.blocker_dyn[dead.tile] = cfg.f("combat.wreck_blocker_h_m", 2.0)
		ActionEvent.Kind.ACTIVATED:
			state.mark_activated(ev.unit)
		_:
			# BEGIN and END are bookends and carry no consequence. An unrecognized kind is inert
			# rather than an error, so a stream written by a newer batch replays harmlessly here.
			pass


static func apply_all(
	cfg: Config, md: MapData, state: MatchState, events: Array[ActionEvent]
) -> void:
	for ev: ActionEvent in events:
		apply(cfg, md, state, ev)
