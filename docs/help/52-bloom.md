---
group: bloom
---

# Bloom & Grade

With Bloom on, the glow renders in high dynamic range, blurs, and passes
through a color grade before reaching the screen. All five sliders act
inside that path, so each is dormant while Bloom is off.

- `bloomIntensity` — how much of the blurred glow folds back into the
  image.
  Interacts with: Intensity and the glow sliders (what it blurs).
- `exposure` — the overall brightness of the graded image.
  Interacts with: Saturation, Contrast, Temperature (applied after it);
  Field Opacity (also grades the field with Bloom off).
- `saturation` — how vivid the colors stay through the grade.
  Interacts with: Exposure (before it); Palette Saturation; Field Opacity
  (also grades the field with Bloom off).
- `contrast` — how hard the grade separates dark from light.
  Interacts with: Exposure and Saturation (before it); Field Opacity (also
  grades the field with Bloom off).
- `temperature` — tilts the grade between cool and warm.
  Interacts with: Warmth; Field Opacity (also grades the field with Bloom
  off).
