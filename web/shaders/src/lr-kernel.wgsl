// =============================================================================
// LONG RANGE KERNEL: the species mix, in k-space
// =============================================================================
//
// WHY THIS EXISTS:
// This is the solve. Everything around it is transform. One bin at a time:
//
//   Phi_r(k) = G(k) * sum over s of A[r][s] * rho_s(k)
//
// where A is the same attraction matrix the neighbour sweep reads, so one
// matrix entry names one relationship acting at two ranges.
//
// THE RECEIVER INDEXES THE ROW, the source the column — the convention
// forces.wgsl already reads (thisSpecies * MAX_SPECIES + otherSpecies).
// Reading the column instead swaps who is pulled toward whom, silently.
//
// BECAUSE THE MATRIX IS ASYMMETRIC there is no single potential every species
// reads, and the long-range term therefore does not conserve momentum. That is
// a stated property of this coupling, not a defect to patch: symmetrizing the
// matrix here would make Red attracting Blue mean Blue attracting Red, which
// is the one thing the matrix exists to distinguish.
//
// ONE THREAD PER BIN, out of place. The thread holds every source species in
// registers and writes every receiver from them, so the S x S matvec costs S
// reads and S writes per bin rather than S reads per receiver. Out of place
// because its output cannot alias its input: every receiver reads every
// source.
//
// THE KERNEL MULTIPLIES THE MIXED SUM, not each source before it. Both orders
// give the same answer — the kernel is a scalar and the mix is linear — and
// this one costs one multiply per receiver instead of one per source.
//
// The 1/(W*H) the round trip owes rides inside G, where a multiply already
// happens. Mirrors src/long_range_core.nim's lrMixBin and lrKernel.
// =============================================================================

//! import particle
//! import sim_params
//! import lr_params
//! import lr_grid

@group(0) @binding(0) var<storage, read> srcSpectrum: array<vec2<f32>>;
@group(0) @binding(1) var<storage, read_write> dstSpectrum: array<vec2<f32>>;
@group(0) @binding(2) var<uniform> params: LrParams;
@group(0) @binding(3) var<uniform> sim: SimParams;

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn mixSpectra(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let cells = params.gridW * params.gridH;
  let cell = globalId.x;
  if (cell >= cells) {
    return;
  }

  let bin = vec2<u32>(cell % params.gridW, cell / params.gridW);
  let kernel = lrKernel(lrWavenumber(bin, params), params);

  // Every source species at this bin, held while the receivers are written.
  var sources: array<vec2<f32>, {{MAX_SPECIES}}>;
  for (var s: u32 = 0u; s < params.speciesCount; s = s + 1u) {
    sources[s] = srcSpectrum[s * cells + cell];
  }

  for (var r: u32 = 0u; r < params.speciesCount; r = r + 1u) {
    var acc = vec2<f32>(0.0, 0.0);
    for (var s: u32 = 0u; s < params.speciesCount; s = s + 1u) {
      let matrixIdx = r * MAX_SPECIES + s;
      let entry = sim.attractionMatrix[matrixIdx / 4u][matrixIdx % 4u];
      acc = acc + entry * sources[s];
    }
    dstSpectrum[r * cells + cell] = acc * kernel;
  }
}
