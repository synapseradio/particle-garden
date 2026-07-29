---
group: species
---

# Species Forces

Each species attracts or repels each other species according to the
attraction matrix further down the panel. These controls scale and season
those rules.

- `forceStrength` — how strongly the matrix acts. At zero the species force
  is off entirely: particles drift through each other, and every control
  that shapes the force dims until you bring it back.
- `crowdingStrength` — how much a dense crowd weakens its own attraction.
  Repulsion never weakens, so crowding loosens clumps without letting them
  overlap. Dormant while the species force is off.
- `ruleTemperature` — how wild a freshly randomized rule set runs. It acts
  when you press New Rules, so the world answers at the next roll of the
  dice rather than immediately.

After changing the strength or crowding, give the colonies a few seconds:
clusters re-form rather than snap into place.
