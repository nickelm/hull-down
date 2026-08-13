# 0036 — Overwatch arcs are an overlay channel, not geometry

## Context

`docs/hull-down-v2.md` 2c asks for overwatch arcs rendered "as translucent wedges clipped by LOS;
overlapping arcs render darker". Before this, `overwatch_dir` reached the screen as the string
`watching NE` on the unit card and nowhere else — a unit's standing orders were legible only by
selecting it and reading a word.

Two ways to draw a wedge. As 3D geometry: build a fan mesh per watching unit, from the tile out to
range, and rebuild it whenever anything changes. Or as data in the overlay texture the terrain shader
already samples.

The deciding argument is the clipping. "Clipped by LOS" is a per-tile question, and `VisionField`
already answers it per tile for a given observer — it is the same call the visibility overlay makes.
A mesh would have to be cut against that answer anyway, which means computing the per-tile field and
then building geometry from it, rather than computing the per-tile field and stopping. And 0023
already established the cost ratio for exactly this decision: repainting the overlay texture is one
`PackedByteArray` write and an `ImageTexture.update()`, a millisecond or two for the whole map,
against thirty to eighty to rebuild an overlay mesh.

## Decision

**`OverlayLayer` becomes `FORMAT_RGBA8` and the alpha channel carries overwatch arc density.**

R, G and B were taken — movement range, exposure, highlight. Alpha was the unused fourth channel of a
texture that was already the right shape, the right size, and already sampled at the right place.

**The channel carries a count, not an enumerated state.** Every other channel is decoded by range
against thresholds, because every other channel holds one of a few named states; this one holds the
number of the viewing side's arcs covering that tile, and the shader reads it as a number. That is the
whole of "overlapping arcs render darker" — density accumulates per arc and saturates at
`overlay.overwatch_max_overlaps`, past which more tanks covering the same valley stop making it
darker and it would only turn to mud.

**Drawn as a fill, and it is the only overlay that is.** 0023's argument for outlines is that a flat
tint recolours the terrain and competes with the thing it annotates — a blue movement range reads as a
lake. That argument holds for overlays that annotate ground a tank *might* stand on. An arc is a
different kind of claim: it says this volume of ground is covered, and how heavily is the information.
A wedge drawn only as an outline would say where the cover stops while saying nothing about it. So the
fill carries the density and the union additionally gets a border, which is what gives a wedge a
definite edge instead of fading out into ground that merely looks a bit warm.

**Own-side arcs only.** An enemy's watch bearing is precisely the information the ambush mechanic
exists to withhold — 0030 makes overwatch a per-tile interrupt whose whole value is that the mover
does not know it is there. Drawing enemy arcs would undo that rule with a rendering feature. Six of
your own tanks covering one valley is where the overlap shading earns its keep anyway, and that is a
question about your own dispositions.

**Range is optics, not a separate weapon range.** `Overwatch.triggers` will not fire at something the
side has not spotted, so ground the gun could theoretically reach beyond spotting range is ground it
cannot actually engage. Drawing it would promise cover that is not there.

## Consequences

Arcs are drawn under every overlay mode rather than being one of the things `V` cycles between. They
are not a query the player ran; they are standing orders their own tanks are under, and a wedge that
vanishes when you switch to the movement overlay is one you forget about at exactly the moment it
matters.

`_recompute_overwatch` runs one `VisionField.compute` per watching unit, in `refresh_all` alongside
the movement and visibility recomputes, and caches a per-tile count the repaint uploads. The three
clipping rules are applied cheapest-first: line of sight, then range, then the arc.

A fresh `OverlayLayer` must read zero in alpha, not the 255 an RGBA image would naturally suggest.
Nothing about the format guarantees that — the buffer is explicitly zeroed and
`tests/test_mesh.gd` asserts it, because a texture whose "no arcs here" value was full opacity would
paint the entire map as covered ground.

The alpha channel is spent. A fifth overlay wants either a second texture or a genuine packing scheme,
and packing two states into the ranges of one channel — which R and G both already do — is the cheaper
answer and should be preferred before adding a sampler.
