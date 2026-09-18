---
group: render
---

# Particles On Screen

The drawn size of each particle and the trail it leaves.

- `particleSize` — the radius each particle draws at, in pixels at zoom 1.
  Interacts with: Halo Radius (the halo is a multiple of this size); Zoom;
  crowd density (dense particles draw a little larger).
- `trailLength` — how long motion lingers, in particle diameters. Zero
  clears every frame; long trails turn fast worlds into ribbons. The
  Trails button above turns the effect on and off.
  Interacts with: the Trails button (turning it on lifts zero to 25);
  particle speed (stretches the dots); the chemical field (trails drift
  along it); Zoom.
