// =============================================================================
// MODULE: tonemap_grade
// =============================================================================
// The single authority for the HDR-light -> display-color transform: exposure,
// the Narkowicz ACES filmic tonemap, then the saturation / contrast /
// temperature grade. Both consumers of TonemapParams run their light through
// tonemapGrade — tonemap.wgsl (bloom on) and field-composite.wgsl (bloom off)
// — so toggling bloom never shifts the field's tonality.
// =============================================================================

//! import tonemap_params

fn luminance(color: vec3f) -> f32 {
  return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

// Narkowicz 2015 ACES filmic tonemap fit — maps unbounded HDR into [0,1].
// https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve
fn acesFilmic(hdr: vec3f) -> vec3f {
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  return clamp((hdr * (a * hdr + b)) / (hdr * (c * hdr + d) + e),
               vec3f(0.0), vec3f(1.0));
}

// Exposure -> ACES -> saturation around the pixel's own luminance -> contrast
// around a mid-grey 0.5 pivot -> signed temperature (positive warms) -> clamp.
fn tonemapGrade(light: vec3f, params: TonemapParams) -> vec3f {
  let hdr = light * params.exposure;
  var color = acesFilmic(hdr);

  let lum = luminance(color);
  color = mix(vec3f(lum), color, params.saturation);

  color = (color - 0.5) * params.contrast + 0.5;

  color = color * vec3f(1.0 + params.temperature * 0.1, 1.0,
                        1.0 - params.temperature * 0.1);

  return clamp(color, vec3f(0.0), vec3f(1.0));
}
