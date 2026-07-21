// =============================================================================
// MODULE: colormap — reaction-diffusion field colormaps
// =============================================================================
// applyColormap maps the RD field's two concentration channels (activator .r,
// inhibitor .g) to an RGB colour through one of three procedural ramps. Both
// the HDR tonemap pass and the bloom-off LDR field-composite pass import this
// module, so the field looks identical under either present path.
//
// The polynomial ramp coefficients, the two-tone constants, and the field
// scalar gain are substituted from src/colormap_core.nim (the single
// native-tested authority) via the COLORMAP_ placeholders below. The ramp
// math here mirrors that module's evalColormap exactly.
//
// RAMPS: 0 inferno, 1 viridis (both perceptually-uniform matplotlib fits driven
// by a single scalar from the inhibitor channel); 2 two-tone (an original
// complementary ramp reading both channels distinctly).
// =============================================================================

const COLORMAP_INFERNO = array<vec3f, {{COLORMAP_POLY_TERMS}}>(
  {{COLORMAP_INFERNO_COEFFS}}
);
const COLORMAP_VIRIDIS = array<vec3f, {{COLORMAP_POLY_TERMS}}>(
  {{COLORMAP_VIRIDIS_COEFFS}}
);
const COLORMAP_FIELD_GAIN: f32 = {{COLORMAP_FIELD_GAIN}};
const COLORMAP_TWO_TONE_WARM: vec3f = {{COLORMAP_TWO_TONE_WARM}};
const COLORMAP_TWO_TONE_COOL: vec3f = {{COLORMAP_TWO_TONE_COOL}};
const COLORMAP_TWO_TONE_INHIBITOR_GAIN: f32 = {{COLORMAP_TWO_TONE_INHIBITOR_GAIN}};
const COLORMAP_TWO_TONE_COOL_LEVEL: f32 = {{COLORMAP_TWO_TONE_COOL_LEVEL}};

// Horner evaluation of a 7-term polynomial ramp, clamped into the unit cube
// (the fits overshoot slightly at the ends and the display is LDR).
fn colormapPolyEval(coeffs: array<vec3f, {{COLORMAP_POLY_TERMS}}>, rampT: f32) -> vec3f {
  let clampedT = clamp(rampT, 0.0, 1.0);
  var channels = coeffs[{{COLORMAP_POLY_TERMS}} - 1];
  for (var term: i32 = {{COLORMAP_POLY_TERMS}} - 2; term >= 0; term = term - 1) {
    channels = coeffs[term] + clampedT * channels;
  }
  return clamp(channels, vec3f(0.0), vec3f(1.0));
}

// The [0,1] ramp parameter the single-scalar ramps read, from the inhibitor
// (pattern) channel.
fn colormapFieldScalar(inhibitor: f32) -> f32 {
  return clamp(inhibitor * COLORMAP_FIELD_GAIN, 0.0, 1.0);
}

// The original complementary ramp: warm amber scaled by the inhibitor pattern,
// plus a dim cool azure tint scaled by the activator substrate.
fn colormapTwoTone(activator: f32, inhibitor: f32) -> vec3f {
  let warmLevel = clamp(inhibitor * COLORMAP_TWO_TONE_INHIBITOR_GAIN, 0.0, 1.0);
  let coolLevel = clamp(activator, 0.0, 1.0) * COLORMAP_TWO_TONE_COOL_LEVEL;
  return clamp(COLORMAP_TWO_TONE_WARM * warmLevel + COLORMAP_TWO_TONE_COOL * coolLevel,
               vec3f(0.0), vec3f(1.0));
}

// Dispatch on the colormap index; an out-of-range index falls back to inferno,
// matching colormap_core.evalColormap.
fn applyColormap(colormapIndex: u32, activator: f32, inhibitor: f32) -> vec3f {
  if (colormapIndex == 1u) {
    return colormapPolyEval(COLORMAP_VIRIDIS, colormapFieldScalar(inhibitor));
  }
  if (colormapIndex == 2u) {
    return colormapTwoTone(activator, inhibitor);
  }
  return colormapPolyEval(COLORMAP_INFERNO, colormapFieldScalar(inhibitor));
}
