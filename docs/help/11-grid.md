---
group: grid
---

# Neighborhood

One radius decides how far any particle can feel another — the species
forces and the fluid both search inside it.

- `interactionRadius` — the reach of every interaction, in world units.
  While you drag it, a ring at the cursor draws that reach at world scale,
  so you can compare it against the structures on screen. Small radii make
  tight local rules; large radii let distant clusters tug on each other,
  and cost more to simulate.
