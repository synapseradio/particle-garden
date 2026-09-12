---
group: bodies
---

# Bodies

A body is an invisible shape in the world that particles can feel. Nothing
draws it: you see where one is by what the crowd does — a ring gathering on
its surface, a hollow nobody enters, a pocket nothing escapes. Bodies are
made by hand, one gesture at a time, and each lives out a fixed life and
goes. The strength slider leads the group because it decides how much of
what a body says lands at all; the rest describe the body your next gesture
makes.

- `bodiesStrength` — how much of a body's push reaches the particles. Zero
  removes bodies from the world without removing the bodies in it.
- `bodyRadius` — how big the next body is born. A living body keeps the
  size it was born with, so this is a setting for the next one.
- `bodyBand` — how far from its surface a body reaches. The size says
  where the surface is; this says how far the forces carry from it.
- `bodyProximity` — the pull toward the surface, from either side.
  Positive gathers particles into a skin on it; negative clears a gap
  either side of it.
- `bodyEnclosure` — the hold across the surface. Positive keeps particles
  in, negative keeps them out, zero does neither.
- `bodyLifetime` — how many seconds the next body lives, fading in through
  fading out. It is fixed when the body is born.
- `bodyIgnitionRate` — how many bodies a second the world makes on its own,
  somewhere you did not choose. Zero leaves every body to you.

Three more things a body is born with have no slider, because they belong to
the gesture that makes it rather than to the world: **anisotropy**, how far
from a circle it is stretched; **envelope skew**, whether it fades in slowly
and out fast or the other way about; and **sustain**, the level it holds at
after its fade-in before its fade-out. They are set as a body ignites and
never move while it lives.

A body change reaches you through the crowd, over a second or two: watch the
shape the particles take around where you made one, not any single particle.
