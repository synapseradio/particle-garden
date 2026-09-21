---
group: species
---

# Species Forces

Each species attracts or repels each other species according to the
attraction matrix further down the panel. These controls scale and season
those rules.

- `forceStrength` — how strongly the matrix acts. At zero the species force
  is off entirely: below a crowding onset, particles of different species
  still pass through each other, and every control that shapes the force
  dims until you bring it back. Above that onset, crowds push apart
  regardless — that resistance is fixed and does not turn off with this
  slider.
  Interacts with: Crowding and the force shape (dims them at zero); Fluid
  (its close-range push is what stops overlap while Fluid is off); Time
  Scale; Force Weather, MIDI and audio (move it).
- `crowdingStrength` — crowding shapes clump texture, and the pressure is
  what bounds collapse: this slider only weakens a dense crowd's own
  attraction. Repulsion never weakens, so crowding loosens clumps without
  letting them overlap. Dormant while the species force is off.
  Interacts with: Force Strength (dims it at zero); Interaction Radius
  (counts the crowd inside it); the attraction matrix (weakens only the
  pull).
- `ruleWildness` — how wild a freshly randomized rule set runs. It acts
  when you press New Rules, so the world answers at the next roll of the
  dice rather than immediately.
  Interacts with: New Rules only; the rules it rolls also drive Long
  Range.

After changing the strength or crowding, give the colonies a few seconds:
clusters re-form rather than snap into place.
