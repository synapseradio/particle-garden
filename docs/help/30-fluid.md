---
group: fluid
---

# SPH Fluid

The fluid treats particles as drops of water: where they crowd past a rest
density, pressure pushes them apart, and viscosity smooths their motion.
The strength slider leads the group because it decides whether this world
has a fluid at all; the rest shape what kind of fluid it is, and all of
them dim while the world has no fluid.

- `fluidStrength` — how much of the fluid's push reaches the particles.
  Zero removes the fluid from the world.
- `sphRadiusFraction` — how far the fluid feels its neighbors, as a
  fraction of the interaction radius. Smaller fractions make a finer,
  choppier fluid.
- `sphRestDensity` — the crowding level the fluid treats as comfortable.
  Below it, no pressure; above it, push-back.
- `sphStiffness` — how hard the fluid resists compression. Its usable
  ceiling depends on the fluid's reach, the substeps, and the time scale,
  so the slider shades the range the current settings cannot hold.
- `sphViscosity` — how much neighbors drag on each other. Higher values
  make honey; lower values make water.
- `sphSubsteps` — how many smaller steps each frame takes for the fluid.
  More substeps hold a stiffer fluid steady at more cost.

A fluid change spreads through the population over a second or two — watch
for the texture of the motion to change, more than for any single particle.
