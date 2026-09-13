---
group: midi
---

# MIDI

A controller becomes mappings the world can be played through — a knob
turned into a slider, a pad turned into a tap, a program button turned into
a regime. Nothing about the world changes kind; a mapping just gives a
gesture on hardware the same reach a mouse already has.

- **Connect** — asks the browser for MIDI access, once, in the same click.
  The browser remembers your answer, so later visits connect without asking
  again. Turning it off releases every port. While connected, the ports your
  browser can see are listed underneath.

A **mapping** is one row: a control on your hardware bound to one thing it
moves here — a slider, a button, or a pad. The panel lists every mapping
that ships or that you have added, each as one line naming its source and
its target.

## The four knobs the app ships mapped

Out of the box, four knobs common to most controllers arrive already bound,
on channel 1:

- `forceStrength` — CC 7 (Volume) moves Force Strength, how hard particles
  pull and push each other.
- `fluidStrength` — CC 1 (Mod wheel) moves Fluid, how much of the fluid's
  verdict on a particle's motion actually lands.
- `rdFieldForce` — CC 74 (Cutoff) moves Scent-following, how hard the field
  pattern steers particles.
- `rdDeposit` — CC 71 (Resonance) moves Secretion Rate, how much scent every
  particle lays down.

Turning Volume or Cutoff reads the same as turning up the room through
Listen: level and brightness mean the same thing whether they arrive from a
knob or from the microphone.

## Program buttons and the pad grid

Six program-change buttons, ordinals 0 through 5 on channel 1, fire the six
named regimes in order: **regime:waves**, **regime:mitosis**,
**regime:labyrinth**, **regime:spots**, **regime:worms**, and
**regime:coral** — the same regimes the Reaction-Diffusion section's own
buttons apply.

Notes on channel 1, source **midi:notes:1**, lay a 4-by-4 grid of pads over
the visible view, starting at note 36 (the corner most pad controllers put
their bottom-left pad on). Each pad blasts the particles under it, row-major
from the bottom left, the same gesture a tap on the canvas gives.

Two tours ride the frame clock rather than any button: **climate** and
**forceWeather**, the same drifting regimes and forces the Weather and Force
Weather switches already run, now rows a mapping document can carry rank and
presence for.

## Learn

To map a control by hand: choose what it should move, press **Map this
control**, then move the control on your hardware. The next move that
qualifies binds — a knob or fader for a slider, a button or pad for an
event. Press **Cancel** to give up without binding anything. Learn ignores
whatever a listening microphone or a stuck knob was already sending in the
moment before you pressed the button, so a live room never binds itself by
accident.

## Soft takeover, and why a knob waits

A hardware knob starts wherever it physically sits, which is rarely where
the slider it now controls already reads. Turning it takes over only once
its travel crosses the slider's current position (or comes within a step of
it) — until then, moving the knob does nothing, so the parameter cannot
jump the moment you touch the control. A mapping made through learn, or a
mapping between two rows sharing a target, ranks in the order shown; the
higher rank wins a frame both move in, so a hand on a knob is heard over
ambient drift the moment it takes over.

## Handing a mapping to another player

Export copies the whole mapping — every row, in order — as text. Send that
text to another player, or save it; Import reads it back and takes over the
mapping here, refusing (and leaving your mapping unchanged) if the text
does not parse as one. The mapping you are running persists between visits
on its own, so exporting is for handing it to someone else or keeping a copy
outside the browser, not for the ordinary case of returning to your own
garden.
