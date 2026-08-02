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
- `forceWeatherSpeed` — how fast Force Weather walks its waypoints, in tours
  per minute. It appears once Force Weather is on.

Force Weather makes the world wander on its own. Switch it on and force
strength, interaction radius and friction travel a closed loop of settled
configurations, easing between them so nothing jumps. The sliders move as it
goes, so what you see on the panel stays the truth about what the world is
doing. It starts off, and it never moves anything until you ask.

It runs independently of the Weather under Reaction-Diffusion: either can be
on without the other, and each keeps its own speed and its own place on its
own loop.

Watch the motion settle for a moment after moving any of these: the world
answers as particles redistribute, so the panel shows a brief "settling"
note rather than an instant change.
