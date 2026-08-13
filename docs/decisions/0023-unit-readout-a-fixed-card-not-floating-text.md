# 0023 — The unit readout is a fixed card, not floating text

## Context

Iteration 1 has no per-unit affordance at all. Which tank is selected is legible only from a line of
text in the top-left status block, and nothing on the map distinguishes a unit that has acted from
one that has not. That was tolerable with one tank and stopped being tolerable at four.

The obvious fix — draw the unit's details over the unit — does not survive this camera. The tactical
camera spans 25 m to 1400 m ([0001](0001-godot-4-desktop-only.md)'s free-flying camera, tuned to the
"inspect any part of the map in under three seconds" target), the ground is terraced and
flat-shaded, and the terrain shader deliberately keeps the ground's own colour rather than tinting
it ([0014](0014-movement-in-two-action-points.md) and the outline scheme it drives). World-anchored
text over that has to survive both a 25 m close-up and a 900 m overview against a background of hard
value steps, and the outline weight it needs to do that becomes its own visual noise.

The related question is where the *path preview's* decorations live. The overlay texture is one
texel per tile and is already the cheapest thing in the renderer — a `PackedByteArray` write and an
`ImageTexture.update()`, one or two milliseconds for the whole map, against thirty to eighty to
rebuild an equivalent mesh.

## Decision

**Anything with a numeral in it lives in a fixed screen corner.** The unit card is a `Control`
anchored top-right, owned by `Hud` so it inherits the viewport-resize and font-scaling machinery
that already exists there rather than growing a second copy of it.

**World-anchored markers carry only what survives at 400 m: a shape and a bar length.** A billboarded
arrow over the selected unit, and a compact bar over every unit. Both are `Sprite3D` with
`fixed_size`, so they hold constant screen size; both hang off *one* world anchor and are separated
by `SpriteBase3D.offset`, which is in texture pixels — a world-space gap between them would shrink
with distance and they would overlap at 900 m. The marker is a child of the tank, so it follows a
move for free, with no update logic and no per-frame position code.

**Path decoration is pooled 3D nodes, not overlay-texture bands.** The overlay expresses *region
membership* — the reachable set, the two action bands, the path ribbon — and it does that well. It
cannot express sub-tile geometry: a facing arrow needs three more bits of direction and the
highlight channel has one free value band, and the image is RGB8. More decisively, the journal
records that the packed-range decode is fragile enough that the hull-down region was invisible from
the day it was written and nobody noticed, because a missing region looks exactly like an empty one.
A third band per channel invites the same failure for a feature that touches about twenty-five tiles.

**No placeholder state is added to `UnitState`.** Condition, ammo, criticals and crew do not exist,
and the repo's standing position — the dead `_selected: bool` the controller used to hold,
[0014](0014-movement-in-two-action-points.md) refusing an `ap_left` counter — is that state nothing
reads is worse than no state. Instead the card's *layout* is final today: every iteration-2 row is
drawn now, with a placeholder glyph in a dimmed colour. Iteration 2 changes a value expression, and
nothing on screen moves.

The card does show real numbers that already exist and were not being displayed: the armour, gun and
optics blocks in `data/units.json`, which have been defined and unread since the roster was written.
They are class data rather than per-unit state, and the card says so.

## Consequences

- Selection is visible on the map at every zoom the camera allows, and the detail is legible because
  it is never fighting the terrain for contrast.
- The overlay's fragile packed-range decoding does not grow a third band per channel.
- Iteration 2 fills in values, not layout. The card does not reflow when hp becomes real.
- The marker is three or four nodes per unit. That is nothing at four units and fine at a few
  hundred; at the "dozens per side" the spec eventually wants, the answer is a `CanvasLayer` driven
  by `Camera3D.unproject_position`, and it replaces the marker nodes without touching anything else.
  Noted, not built.
- The selection arrow draws with depth testing off, so a selected unit stays findable behind a
  ridge. It therefore shows through hills. That is the right trade for a selection marker
  specifically, and it is why only the arrow does it — the bar and the path decoration are occluded
  normally.
