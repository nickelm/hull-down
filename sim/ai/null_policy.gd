class_name NullPolicy
extends Policy

## Passes every unit, every turn — the 2e-i scaffolding check made runnable.
##
## Not a placeholder to be deleted once a real policy exists: a side that deliberately does nothing
## is the fixture every executor test wants, and it is the control an AI-versus-AI batch compares
## against. A utility policy that cannot beat NullPolicy is measuring something, too.


func decide(_view: AiView, unit_index: int) -> AiOrder:
	return AiOrder.pass_order(unit_index)
