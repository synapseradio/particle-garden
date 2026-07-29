---
group: simulation
---

# Simulation

These controls set how much world there is and how fast it runs.

- `particleCount` — how many particles live in the world. Committing a new
  count rebuilds the population, so expect a fresh start rather than a
  resized crowd.
- `speciesCount` — how many kinds of particle exist. Each species gets its
  own color and its own row and column in the attraction matrix; changing
  the count redraws those rules.
- `friction` — how quickly motion drains away. Low values leave particles
  gliding; high values make every push die out close to where it started.
- `timeScale` — how much simulated time passes per frame. Raising it speeds
  everything up at once, including the field's growth.
- `maxVelocity` — a soft cap on how fast any particle may travel. Lower it
  if fast movers streak past the structures you want to watch.

Watch the motion settle for a moment after moving any of these: the world
answers as particles redistribute, so the panel shows a brief "settling"
note rather than an instant change.
