---
group: simulation
---

# Simulation

These controls set how much world there is and how fast it runs.

- `particleCount` — how many particles live in the world. Committing a new
  count rebuilds the population, so expect a fresh start rather than a
  resized crowd.
  Interacts with: every force's cost (more particles, more work); Secretion
  Rate (each particle deposits); Long Range (clusters cost more when
  crowded).
- `speciesCount` — how many kinds of particle exist. Each species gets its
  own color and its own row and column in the attraction matrix; changing
  the count redraws those rules.
  Interacts with: the attraction matrix (its size); Species Chemistry (one
  row each); Mesh Size (cost grows with every species).
- `friction` — how quickly motion drains away. Low values leave particles
  gliding; high values make every push die out close to where it started.
  Interacts with: every push at once (species, fluid, long range, field,
  bodies); Force Weather (moves it).
- `timeScale` — how much simulated time passes per frame. Raising it speeds
  everything up at once, including the field's growth.
  Interacts with: every push's size per frame; Stiffness (lowers its safe
  ceiling); the field (more steps, more cost). Weather and Drift keep
  real time.
- `maxVelocity` — a soft cap on how fast any particle may travel. Lower it
  if fast movers streak past the structures you want to watch. On a long
  frame with a live body, the world serves a lower cap than the one you set,
  so nothing crosses a body's band without meeting it.
  Interacts with: every push at once (the cap applies to their sum);
  Velocity Sweep (glow measures speed against it); Band (a narrow band lowers
  the cap the world serves on a long frame).
- `forceWeatherSpeed` — how fast Force Weather walks its waypoints, in tours
  per minute. It appears once Force Weather is on.
  Interacts with: Force Strength, Interaction Radius and Friction (Force
  Weather moves all three).

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
