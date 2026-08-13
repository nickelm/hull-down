# 0038 — The AI plays through a view of its own knowledge

## Context

2e-i asks for a `Policy` interface, a turn executor, and a guarantee: "the AI reads only its own
side's `Knowledge`. No access to sim ground truth anywhere in the AI code path." The renderer
solved the same problem in 0034, and it solved it structurally — not "`game/` promises not to
peek" but "`TankView` does not hold the thing it must not read". Iteration 2a proved what the
alternative looks like: a complete, tested knowledge model sitting beside a code path that never
consulted it.

An AI is more exposed to that failure than a renderer. A renderer that peeks draws a tank it
should not; an AI that peeks *wins* with clairvoyant flanking moves, and nothing about the match
looks broken. The bug is invisible in exactly the place it is worst.

## Decision

Policies decide through an `AiView` and nothing else. The view serves: the map, config, and
objectives (the briefing — public); the side's own units as live `UnitState`s (a side knows its
own tanks); enemies only as the `Contact` and `SoundContact` lists the side's `SideKnowledge` and
`SideSound` already hold; and planning services (`plan_move`, `preview_fire`, `reachable`)
delegated to the resolver, all of which are pure and all of which refuse before they reveal —
`preview_fire` at an unseen enemy returns `NOT_VISIBLE` and no geometry.

`AiRunner` is the executor: it walks the active side's units in deployment order and asks the
policy "what should this unit do next" until the answer is PASS, the unit's turn is spent, or a
per-unit order cap trips. Every order resolves through the same `ActionResolver` entry points a
click goes through, so the AI obeys the player's rules by construction rather than by a second
copy of the legality tables. An `AiOrder`'s vocabulary is deliberately the player's vocabulary —
PASS, MOVE, FIRE, OVERWATCH, TURRET — one kind per resolver entry point.

`AiRunner` and `AiView` are the only files under `sim/ai/` entitled to hold a `MatchState`.
`tests/test_ai_scaffold.gd` scans every other file there for the class names that hold or take
ground truth, and for `._` reaches through another object's private members — GDScript has no
`private`, so the underscore convention plus the scan is the wall. The scan covers policy files
that do not exist yet, which is the same argument `test_determinism` made for its RNG scan.

Pure geometry over public data — `Los`, `Grid`, `Armour.bearing` on *tiles* — is deliberately not
banned. Classifying the ground between two named points is knowable by anyone with the map, and
the policy can only name tiles it got from its own units, its contacts, or the map itself. The
line is information, not arithmetic.

## Consequences

- A policy cannot be written that cheats quietly. It can still be written badly.
- `AiView` grows a method every time a policy legitimately needs a new fact, which is the point:
  "what does the AI know" stays answerable by reading one file.
- The runner never calls `end_turn`; the caller owns the boundary, so a game layer can replay the
  collected streams before hand-over and a headless loop can interleave victory checks.
- A policy that answers with an illegal order has that unit stood down for the turn rather than
  re-asked — the resolver's refusal is the diagnostic, and looping on it would hide the bug the
  cap exists to surface.
- The AI RNG stream (reserved in 0005) is drawn only inside policies, for tie-breaking; the
  scaffolding itself is deterministic and draws nothing.
