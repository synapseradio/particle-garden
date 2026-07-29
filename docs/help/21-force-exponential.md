---
group: force-exponential
---

# Exponential Force Shape

The exponential model builds the force from two decaying curves: a sharp
repulsion that falls off quickly and a broader attraction that falls off
slowly. Their difference gives close-range push and mid-range pull without
any joints to place. Both controls dim while the species force is off.

- `expRepulsionAlpha` — how fast the repulsion decays. Higher values
  shrink the hard core each particle defends.
- `expAttractionBeta` — how fast the attraction decays. Lower values let
  the pull reach further across the interaction radius.
