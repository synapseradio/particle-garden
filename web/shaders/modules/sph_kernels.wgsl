// =============================================================================
// MODULE: sph_kernels
// =============================================================================
// 2D smoothed-particle-hydrodynamics kernels and the Tait equation of state,
// the WGSL mirror of src/sph_core.nim. The Nim side is the analytic source of
// truth (tests/test_sph_core.nim pins the normalization constants by numeric
// integration); these functions reproduce the same closed forms so the compute
// path and the native tests agree.
//
// Every function takes the smoothing radius as a runtime parameter — nothing is
// precomputed against a fixed radius, so the same kernels serve any
// interactionRadius the user dials in.
// =============================================================================

const SPH_KERNEL_PI: f32 = 3.141592653589793;

// The 2D-normalized poly6 kernel W(r, h) = 4/(pi h^8) * (h^2 - r^2)^3, and 0
// for r >= h. The density-estimator weight. See sph_core.poly6Weight2d for the
// derivation of the 4/(pi h^8) constant. Müller, Charypar & Gross 2003:
// https://matthias-research.github.io/pages/publications/sca03.pdf
fn sphPoly6Weight2d(distance: f32, smoothingRadius: f32) -> f32 {
  if (distance >= smoothingRadius) {
    return 0.0;
  }
  let normalization = 4.0 / (SPH_KERNEL_PI * pow(smoothingRadius, 8.0));
  let radiusSq = smoothingRadius * smoothingRadius;
  let diff = radiusSq - distance * distance;
  return normalization * diff * diff * diff;
}

// Magnitude of the 2D spiky kernel's radial gradient, |dW/dr| = 30/(pi h^5) *
// (h - r)^2, and 0 for r >= h. Strictly positive and decreasing on (0, h): the
// non-negative repulsive magnitude the caller multiplies by a unit direction.
// Same source as poly6 above (Müller, Charypar & Gross 2003).
fn sphSpikyGradientMagnitude2d(distance: f32, smoothingRadius: f32) -> f32 {
  if (distance >= smoothingRadius) {
    return 0.0;
  }
  let normalization = 30.0 / (SPH_KERNEL_PI * pow(smoothingRadius, 5.0));
  let diff = smoothingRadius - distance;
  return normalization * diff * diff;
}

// Tait equation of state: P = stiffness * ((density/restDensity)^gamma - 1).
// P(restDensity) == 0, rises with compression, negative below rest. Callers
// keep density > 0 (the pow base must be non-negative). Monaghan 1994:
// https://ui.adsabs.harvard.edu/abs/1994JCoPh.110..399M/abstract
fn sphTaitPressure(density: f32, restDensity: f32, stiffness: f32, gamma: f32) -> f32 {
  return stiffness * (pow(density / restDensity, gamma) - 1.0);
}
