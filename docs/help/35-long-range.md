---
group: long-range
---

# Long Range

The species forces and the fluid both stop at the interaction radius: past
it, one particle cannot feel another at all. The long-range mesh is how the
world carries a pull further than that. It spreads the whole population onto
a coarse grid, solves the pull everywhere at once, and hands each particle
back the force it feels from every other particle in the world, however far
away — the same attraction matrix, acting at a distance the neighbourhood
sweep never reaches.

The strength leads the group because it decides whether this world has a
long-range pull at all; the two below it say what kind of reach it has, and
both dim while the strength is at zero.

- `longRangeStrength` — how much of the mesh's pull reaches the particles.
  Zero removes the long-range coupling from the world, and costs nothing:
  the solve does not run at all. Raising it turns scattered clusters into a
  world that organizes at its own scale, drawing distant colonies toward or
  away from each other according to the same matrix that governs contact.
  Interacts with: the attraction matrix (shared); Reach and Mesh Size (dims
  them at zero); Particles and Interaction Radius (its clusters make the
  neighbour sweep costly); Fluid (loosens the clusters); Time Scale.
- `longRangeReach` — the distance past which the pull is screened away.
  Small reaches make the coupling a wider neighbourhood, barely past what
  the interaction radius already covers; large ones let one side of the
  world pull on the other. The slider travels logarithmically, so equal
  movement multiplies the reach rather than adding to it, and every part of
  the range gets the same amount of track.
  Interacts with: Mesh Size (a coarse mesh blurs short reaches); Long
  Range (dims it at zero).
- `longRangeGridIndex` — how finely the mesh resolves the world, and this
  coupling's cost knob. Each step up doubles the grid on both axes, so it
  quadruples the work the solve does per frame; in exchange the pull
  resolves detail at half the scale. Move it down if the frame rate suffers
  more than the picture gains.
  Interacts with: Species (cost grows with every species); Reach; Long
  Range (dims it at zero).

The mesh answers over seconds, not instantly: a change in strength or reach
redistributes the whole population, so watch how the clusters arrange
against each other rather than any single particle. Changing the mesh size
re-solves the world at a new resolution, so give the picture a moment to
settle before judging it.
