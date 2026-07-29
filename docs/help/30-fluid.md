---
group: fluid
---

# SPH Fluid

How much of the fluid acts, and what kind of fluid it is.

- `fluidStrength` — Fluid; zero means this world has no fluid.
- `sphRadiusFraction` — Fluid Scale, as a fraction of the interaction radius.
- `sphRestDensity` — Rest Density.
- `sphStiffness` — Stiffness; its live ceiling follows the kernel, substeps,
  and time scale.
- `sphViscosity` — Viscosity.
- `sphSubsteps` — Substeps.
