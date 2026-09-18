---
group: glow
---

# Glow

Every particle carries a soft halo. These controls shape it.

- `glowIntensity` — how bright the halo burns.
  Interacts with: Velocity Sweep; Bloom Intensity (folds it back); audio
  (high band, off by default).
- `velocityGlowScale` — how much speed brightens a particle, so movers
  stand out from sitters.
  Interacts with: Max Velocity (speed is measured against it); Halo Radius
  (speed grows the halo too); Intensity.
- `glowRadiusScale` — how far the halo spreads beyond the particle.
  Interacts with: Particle Size (multiplies it); Velocity Sweep; Zoom.
- `glowFalloff` — how sharply the halo fades at its edge.
  Interacts with: Intensity; Halo Radius.
- `glowWarmth` — tilts halo color between cool and warm.
  Interacts with: crowd density (only dense crowds warm); Palette colors.
