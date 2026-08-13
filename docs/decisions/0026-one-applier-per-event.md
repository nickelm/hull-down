# 0026 — One applier per event: resolve interleaves it, commit loops it

Amends 0022.

## Context

0022 established that an action resolves, inside `sim/`, to an ordered list of events, and that
`MoveAction.commit` walks that list into the state. It predicted its own next move: *"an interruption
that stops the unit at the sixth tile is the remaining events not being applied, and needs no special
case anywhere."*

That prediction is true about the **mover** and false about everything else, and iteration 2 is where
the difference bites.

An overwatch shot fired at the mover's sixth tile has to see the armour the shot at its fourth tile
shredded. The spotting check on its seventh tile has to see that the mover is dead. A watcher that
fires has to have its ammunition already spent when the next tile is tested. None of that is
expressible by a function that builds the entire list and *then* walks it, because at the moment the
list is being built the world is still in its pre-action state — the resolver is asking "who can see
this tank now?" of a `MatchState` that says the tank has not moved.

The obvious fix is to have the resolver mutate as it goes. The obvious problem with the obvious fix
is that there would then be two places that know how an event changes the world — the resolver's
inline mutations and `commit`'s `match` — and they would drift. They would drift *silently*, because
in the uninterrupted case both run over the same list and produce the same answer, so the divergence
only shows up in the interrupted case, which is the case that is hard to test.

## Decision

**`EventApplier.apply(cfg, md, state, ev)` is the single function that knows how one event changes
the world.** `MoveAction.commit` becomes a loop over it. The resolver's weave calls the same function
as it appends each event.

Three things follow.

**The resolver applies as it walks.** By the time the check for tile seven runs, tiles one through six
have already happened to the `MatchState`. `Spotting` and `Overwatch` therefore need no tile-override
parameter and no shadow copy of the board — they read the live state and answer about now. That keeps
their signatures the shape a future AI wants for speculative queries, which is the shape they would
have lost if every one of them had grown an "except pretend this unit is over there" argument.

**Arms that are not arithmetic must be idempotent.** The resolver applies an event when it appends it
and `commit` may apply the same list again, so an arm that adds rather than assigns charges twice.
`STEP` and `TURN` assign absolute snapshots — `ev.mp_left` is what the unit has *after* the event,
never what the event cost — which is what makes a movement stream safe to replay any number of times.
The genuinely non-idempotent arms that combat adds (spending a round, shredding a plate) are guarded
by `ActionResult.committed`, exactly as they were before.

**Truncation stays what 0022 said it was.** An interruption is still the remaining events not being
appended. What 0022 did not say, and what turns out to be needed, is that the *tail* has to be
rebuilt at wherever the walk stopped: `MoveAction.close_stream` emits the `ACTIVATED`-if-spent test
and the `END` against the tile the unit actually reached. The result is a complete, self-consistent
account of a shorter action, and `commit` never learns that an interruption happened.

## Consequences

**"The event stream is the authoritative account of what happened" stops being a comment and becomes
a test.** Restore the pre-action state, loop `EventApplier.apply_all` over the final stream, and the
result must equal what resolving produced. That assertion was not previously possible to write, not
because it was false but because there was only one code path — `commit` agreed with the path because
`commit` *was* the path, and a thing can always be shown to agree with itself. Two paths that must
agree is what makes the agreement worth checking, and the interrupted case is where it earns its keep.

`MoveAction.commit` gains `cfg` and `md` parameters. `md` is there because a destroyed unit writes
cover into the map (0031) and `cfg` because some arms read a rule. Both are unused by the movement
kinds today. Two call sites changed.

`ActionResult` gains `interrupted`. Nothing about replaying a stream needs it — that is the whole
point — but the controller has to be able to tell the player why the tank stopped short.

The default arm stays `pass` rather than an error, so a stream carrying kinds a consumer does not
recognise replays harmlessly instead of aborting. This is what lets each batch add kinds without
touching the batches that came before.
