---
group: glossary
---

# Glossary

## Words the panel uses

- *coupling* — an influence between parts of the world (species force,
  fluid, field deposit, field steering), each behind a strength slider
  whose range includes zero.
- *dormant* — a control whose consumer cannot act right now. It dims and
  names what would wake it, and it stays movable so you can set a value in
  advance.
- *settling* — the quiet note shown while the world is still answering a
  move, on controls whose response arrives over seconds.
- *regime* — a feed/kill coordinate where the field grows a characteristic
  pattern; the named buttons visit them.

## The reaction and its named patterns

The field runs the Gray-Scott reaction-diffusion system: chemical U feeds
in everywhere and converts to V where V already exists, and V decays. Its
patterns and the phase map behind them come from Pearson (1993), "Complex
Patterns in a Simple System", Science 261, which classifies the regions
graphically. The buttons' coordinates — Waves, Mitosis, Labyrinth, Spots,
Worms, Coral — follow a practitioner summary of representative points
(mysimulator.uk, "Gray-Scott Reaction-Diffusion"); Pearson publishes no
numeric boundaries, so these mark the map without fencing it. A widely
used replot of Pearson's map lives at mrob.com's Xmorphia pages.

## The force models

The polynomial model follows the particle-life family of simulations:
piecewise curves with close-range repulsion, mid-range attraction, and a
finite reach. The exponential model builds the same push-and-pull from two
decaying exponentials instead of joints.

## The fluid

The fluid uses smoothed-particle hydrodynamics (SPH), with pressure from
the Tait equation of state at the classic water exponent of 7 (Monaghan's
formulation) and XSPH velocity smoothing for viscosity.
