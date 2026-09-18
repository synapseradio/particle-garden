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
  Interacts with: the other fluid sliders (dims them at zero); Substeps
  (they run only while the fluid is on); Long Range (fluid loosens its
  clusters and makes it cheaper); MIDI and audio (move it).
- `sphRadiusFraction` — how far the fluid feels its neighbors, as a
  fraction of the interaction radius. Smaller fractions make a finer,
  choppier fluid.
  Interacts with: Interaction Radius (it is a fraction of it); Stiffness
  (sets its safe ceiling).
- `sphRestDensity` — the crowding level the fluid treats as comfortable.
  Below it, no pressure; above it, push-back.
  Interacts with: Stiffness (how hard it pushes past this level).
- `sphStiffness` — how hard the fluid resists compression. Its usable
  ceiling depends on the fluid's reach, the substeps, and the time scale,
  so the slider shades the range the current settings cannot hold.
  Interacts with: Fluid Scale, Interaction Radius, Substeps and Time Scale
  (all move its ceiling); Rest Density.
- `sphViscosity` — how much neighbors drag on each other. Higher values
  make honey; lower values make water.
  Interacts with: Fluid (scales it); Time Scale.
- `sphSubsteps` — how many smaller steps each frame takes for the fluid.
  More substeps hold a stiffer fluid steady at more cost.
  Interacts with: every push, not only the fluid (each substep reruns them
  all); Stiffness (raises its ceiling); Fluid (only counts while on).

A fluid change spreads through the population over a second or two — watch
for the texture of the motion to change, more than for any single particle.
