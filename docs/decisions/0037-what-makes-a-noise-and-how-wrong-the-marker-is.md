# 0037 — What makes a noise, and how wrong the marker is

## Context

0033 reserved the *shape* of the sound layer — a sibling container with its own arrays and its own
slot on `MatchState`, never a fourth `SideKnowledge.State` — and explicitly deferred the rules: "when
the layer lands it will want its own decision record for the rules it actually adopts — how the
positional error scales, what counts as noisy movement, whether a sound contact can be fired at
speculatively." This is that record. 0033 still governs where the layer lives; this governs what it
does.

One finding reframed the whole batch and belongs at the top, because it changes what the feature is
*for*.

**A gun fired at you is a gun you can see.** `Los.classify` marches one segment with both endpoints
excluded, so line of sight is reciprocal — "that tank can see me and I cannot see it" is not a
geometry this engine can produce. And `Spotting.can_see` reveals a firer to anything with an unmasked
line to it, at any range, deliberately ahead of the range early-out. Put those together and the
obvious mental model for this feature — *you are shot at from the dark and get a vague marker* — is
unreachable. If it shot at you, you see it.

So the sound layer is not about being ambushed. It is about **fights you are not in**: a gun on the
far side of a ridge shooting at somebody else, an engine you never got eyes on. That is a smaller
claim than the iteration prompt implies and a more honest one, and it is what the rules below are
shaped around. It is also why the test fixture needs three sides — with two, any shot is either at you
(and visible) or at nobody.

## Decision

**What makes a noise.** Firing, always, including overwatch reaction fire — each watcher that gets a
round off makes its own noise from its own tile, so two ambushers are two contacts rather than one.
And movement that spent at least `sound.noisy_mp_frac` of the unit's allowance.

**A move makes one contact, at the tile it ended on.** Not one per step. The rule is about information
and not about cost: a ripple per tile draws the exact line the tank drove, and a sound is entitled to
say roughly *where* something is, never *which way it came*. The evaluation therefore sits after the
weave's walk loop rather than inside it, which also means it runs exactly once and reads the tile the
walk actually stopped on — so an overwatch truncation needs no special case anywhere.

**A radius is the whole test.** No line of sight, no cover, no ray. `sound.fire_radius_m` is 1200 m
against optics of 320–500 m, deliberately: a radius inside optics range would make the layer
decoration.

**A side that can already see the noisemaker hears nothing.** A guess drawn over a tank you are
looking at says strictly less than the tank does, and worse, it teaches the player that a ripple
sometimes means a confirmed target — after which the marker's honesty, which is the entire design, is
gone. A side holding only a **ghost** still hears: the ghost is a memory of where it was and the noise
is evidence about now. That is the one place the two layers touch and it is the one place they could
most easily have been conflated.

**The error scales with distance from the hearing side's nearest living unit** —
`min(error_base_m + error_per_100m × d/100, error_max_m)`. The closer your own troops, the better they
place it, which makes a screen of scouts worth something beyond what it can see. The floor is
non-zero, because an error of zero is a sighting; the ceiling exists because a contact covering the
whole board says nothing while claiming everything.

**The displacement is a hash, not a draw.** `Rng.fnv1a` over the true tile, the hearing side, the turn
and the source. Three things follow, and they are why this beats a fifth `Rng.Stream`:

- The sound layer advances no generator, so it cannot reshuffle a combat roll. That is a stronger
  guarantee than the COMBAT/CRITS split buys, and it means `test_combat_distribution`'s thousand
  pinned resolutions are provably unmoved by this batch.
- A replay recomputes the same wrong position by construction, rather than by remembering to record it.
- Two sides listening to one gun disagree about where it is, and a tank firing from the same spot on
  two turns is misplaced differently each time. Both are right, and both are free.

**The displacement is never zero.** When the rounded offset collapses to the origin tile the dominant
axis is pushed a tile regardless. A marker sitting exactly on the tank is a sighting, and a player who
sees one land dead on once will aim at the next.

**Identity is never stored.** `SideSound` is list-shaped, not unit-indexed: there is nowhere to put a
unit index, so no consumer can recover one and no marker can quietly acquire one later. `SoundContact`
carries no `unit` and no `unit_type`, and a test asserts that against the actual property list rather
than trusting a docstring. The `HEARD` event's `other` is always -1 — the slot every other consumer
reads for "who" — and its `tile` is the errored one, so the true position never enters the stream that
crosses into `game/`.

**Expiry is charged to the hearing side, as it takes over**, exactly as ghost decay is. `sound.turns`
is 2 ticks, which is one full turn of that side's own. At 1 it would be aged away by the very
hand-over that gives that side its turn and nobody would ever see it.

**`Sound` mutates nothing.** Unlike `Spotting`, which has to mutate as it decides because the weave's
next step reads the board back, nothing ever reads a sound contact back — so the layer is purely
event-driven and `EventApplier` is its only writer. "The stream is the account of what happened" then
needs no argument for it at all here.

**The marker is a ripple sized to the error radius.** Not a silhouette at any alpha, because that is
read as a tank — 0033's central presentation argument. Not a wedge, because a wedge points down a
bearing this layer does not store. Concentric rings drawn at the *diameter* of the error, so the
outermost ring lands on the edge of the ground the tank could be on: the size **is** the uncertainty,
rather than a legend the player has to learn. Fire and engine are one hue at two saturations, which is
the deliberate opposite of the near/far movement bands — those are two different questions and split
by hue, whereas a gun and an engine are two answers to the same one and should read as one layer.

**No speculative fire.** 0033 asked whether a sound contact can be shot at the way a ghost can. It
cannot, and nothing in this batch adds a path to it. Firing requires `sees()`, and a contact with no
identity has nothing for a shot to resolve against.

## Consequences

`sound.*` and `look.sound.*` in `data/rules.json`; `SideSound`, `SoundContact`, `SoundParams` and
`Sound` in `sim/`; `ActionEvent.Kind.HEARD = 16` with its error radius packed into `flags` rather than
`cost` — `cost` is under the `mp_left == previous - cost` invariant a whole stream is walked to check,
and `flags` is the field already designated for kind-scoped payloads.

`ViewState.filter` gains the one arm that deliberately breaks its own default rule: every other kind
survives only if its actor is visible, and a `HEARD` survives *because* its actor is not. It changes no
visibility, so nothing else leaks through behind it.

Three things this does not do, stated rather than left to be discovered:

- **A sound tells you nothing about what it was.** Gun versus engine is the only distinction, and it
  is a fact about the noise rather than about who made it.
- **The suppression rule means the layer goes quiet exactly when the board is busiest.** Once both
  sides are in contact almost nothing is heard, because almost everything is seen. That is correct and
  it is also why the mechanic will matter most in the approach phase — which is what 2f and 2g are.
- **Nothing decays gradually.** A contact is at full confidence until it vanishes. Ghosts fade over
  their life and these do not, because a sound contact is only ever one turn old and there is no
  gradient to express.

The fixture that proves any of this needs three sides, per the context above. That is a real cost:
the two-sided fixtures every other knowledge test uses cannot express the situation this layer exists
for, and a future reader who simplifies `_crossfire` to two sides will find the acceptance test
quietly unable to fail.
