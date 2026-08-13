class_name Policy
extends RefCounted

## The interface an AI side implements — docs/decisions/0038.
##
## One question, asked repeatedly: what should this unit do next? The runner asks it for the same
## unit until the answer is PASS, the unit is out of the turn, or the order cap trips — so a policy
## never plans a whole turn at once and never needs to. It sees the board fresh after every order,
## through the `AiView` and only through the `AiView`.
##
## Files in `sim/ai/` other than the two boundary objects (`AiRunner`, `AiView`) are scanned by
## `tests/test_ai_scaffold.gd` for reaches into ground truth — no `MatchState`, no resolver, no
## `._` access into the view. A policy that needs a new fact teaches `AiView` to serve it, which
## keeps the question "what does the AI actually know" answerable by reading one file.
##
## Policies are constructed per match and live for the match, so they may keep memory between turns
## (an intent layer does). Anything random in a policy draws from `Rng.stream(seed, Rng.Stream.AI)`
## — reserved since 0005, and separate so an AI decision can never reshuffle a combat roll.


## What should this unit do next? The base answer is to stand it down.
func decide(_view: AiView, unit_index: int) -> AiOrder:
	return AiOrder.pass_order(unit_index)
