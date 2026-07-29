---
group: chemistry
---

# Species Chemistry

Each species gets its own relationship to the field, one value per species
in the grid beside the attraction matrix. Both columns are signed, so a
species can build the field or erode it, chase its trail or flee it.

- `secretion` — this species' share of the Secretion Rate. Positive builds
  the field where the species travels; negative erodes it. Dormant while
  nothing deposits into the field.
- `tropism` — how this species answers the field's pull. Positive chases
  the pattern, negative flees it. Dormant while the field pushes nothing.

Try one species secreting while another erodes: the field becomes a map of
their territories.
