// =============================================================================
// MODULE: render_params
// =============================================================================
// RenderParams: shared uniform struct for the render/glow pipelines.
//
// Source of truth: src/gpu_types.nim (RENDER_* field indices,
// RENDER_PARAMS_F32_COUNT = 12 -> 48 bytes / 3 vec4s). Both render.wgsl and
// glow.wgsl bind the same renderParamsBuffer at @binding(1); this is the one
// declaration both import, so the two can no longer drift out of sync with
// each other or with the Nim-side layout.
// =============================================================================

struct RenderParams {
  resolution: vec2f,       // Canvas width, height in pixels
  worldSize: vec2f,        // World width, height (physics domain)
  baseSize: f32,           // Base particle size in pixels
  glowIntensity: f32,      // Base glow multiplier
  velocityGlowScale: f32,  // 0=off, 1=full velocity influence
  maxVelocity: f32,        // For velocity normalization
  trailLengthScale: f32,   // Motion blur elongation factor (0 = no blur; unused by glow)
  _pad1: f32,
  _pad2: f32,
  _pad3: f32,
};
