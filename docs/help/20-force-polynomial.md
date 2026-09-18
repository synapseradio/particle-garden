---
group: force-polynomial
---

# Polynomial Force Shape

The polynomial model pushes particles apart at very close range, pulls them
together at middle distances, and fades to nothing at the edge of the
interaction radius. These two controls place the joints of that curve. Both
dim while the species force is off.

- `repulsionEnd` — where pushing-apart ends and pulling-together begins, as
  a fraction of the interaction radius. Move it outward and clusters hold
  more personal space.
  Interacts with: Attraction Peak (the other joint); Interaction Radius
  (it is a fraction of it); Force Strength (dims it at zero).
- `attractionPeak` — where the pull is strongest. Closer to the repulsion
  end makes tight, springy clusters; further out makes loose, slow-orbiting
  ones.
  Interacts with: Repulsion End (the other joint); Interaction Radius (it
  is a fraction of it); Force Strength (dims it at zero).

The Force Model buttons above these switch between this curve and the
exponential one; only the active model's controls show.
