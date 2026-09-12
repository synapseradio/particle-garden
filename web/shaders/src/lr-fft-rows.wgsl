// =============================================================================
// LONG RANGE ROW TRANSFORM: one row of the mesh per workgroup
// =============================================================================
//
// WHY THIS EXISTS:
// The mesh solve is a convolution, and a convolution on a torus is a multiply
// in k-space. This is the first and the last pass of that round trip: forward
// along x on the way in, inverse along x on the way out.
//
// THE TWO ENTRY POINTS DIFFER IN THREE THINGS and nothing else: the twiddle's
// sign, where the line comes from, and where it goes. The forward pass reads
// the deposit's fixed-point charge and writes a spectrum; the inverse reads a
// spectrum and writes the real potential, discarding an imaginary part that is
// zero up to rounding because the input spectrum is conjugate-symmetric.
//
// ONE LINE PER WORKGROUP, one dispatch per pass rather than one per stage: the
// whole line lives in workgroup storage for the duration, so the log2(N)
// stages cost one barrier each instead of a global round trip each. A 512-point
// line is 2 * 512 * 8 = 8192 bytes, inside WebGPU's 16 384-byte guarantee.
//
// The workgroup stays at 256 invocations whatever the line length; each
// invocation strides over as many butterflies as the line has.
//
// PING-PONG IN ONE ARRAY of 2N entries: a stage reads the half at `readBase`
// and writes the half at `writeBase`, so the two halves never alias inside a
// stage and one barrier per stage is enough.
//
// Species ride the dispatch's z extent at the LIVE species count, so a world
// running four species pays for four.
//
// Structure after the standard GPU Stockham autosort formulation (Govindaraju
// et al., "High performance discrete Fourier transforms on graphics
// processors"). Mirrors src/long_range_core.nim's lrTransformLine, which
// tests/test_long_range_core.nim measures against a direct DFT.
//
// NEITHER DIRECTION NORMALIZES. The 1/(W*H) a round trip owes is folded into
// the kernel pass, where a multiply already happens; normalizing here too would
// apply it twice.
// =============================================================================

//! import lr_params
//! import lr_grid

@group(0) @binding(0) var<storage, read> srcSpectrum: array<vec2<f32>>;
@group(0) @binding(1) var<storage, read_write> dstSpectrum: array<vec2<f32>>;
@group(0) @binding(2) var<uniform> params: LrParams;
@group(0) @binding(3) var<storage, read> srcDensity: array<i32>;
@group(0) @binding(4) var<storage, read_write> dstPotential: array<f32>;

const PI: f32 = 3.141592653589793;
const INV_LR_DENSITY_SCALE: f32 = {{LR_INV_DENSITY_SCALE}};

// 2N entries at the largest line the declared mesh sizes allow. The extent is
// a compile-time maximum because WGSL requires one; the live line length comes
// from the uniform, and the tail past it is never touched.
var<workgroup> line: array<vec2<f32>, {{LR_FFT_SHARED}}u>;

// The butterfly stages over whatever the caller loaded into `line`, leaving the
// result in the half this returns the base of.
fn lrRunStages(n: u32, tid: u32, dirSign: f32) -> u32 {
  let half = n / 2u;
  var ns: u32 = 1u;
  var stage: u32 = 0u;
  while (ns < n) {
    let readBase = select(0u, n, (stage & 1u) == 1u);
    let writeBase = n - readBase;
    for (var j: u32 = tid; j < half; j = j + {{WORKGROUP_SIZE}}u) {
      let k = j & (ns - 1u);
      let angle = dirSign * PI * f32(k) / f32(ns);
      let twiddle = vec2<f32>(cos(angle), sin(angle));
      let v0 = line[readBase + j];
      let v1 = line[readBase + j + half];
      let w = vec2<f32>(v1.x * twiddle.x - v1.y * twiddle.y,
                        v1.x * twiddle.y + v1.y * twiddle.x);
      let dst = (j - k) * 2u + k;
      line[writeBase + dst] = v0 + w;
      line[writeBase + dst + ns] = v0 - w;
    }
    workgroupBarrier();
    ns = ns * 2u;
    stage = stage + 1u;
  }
  return select(0u, n, (stage & 1u) == 1u);
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn transformRows(@builtin(workgroup_id) groupId: vec3<u32>,
                 @builtin(local_invocation_id) localId: vec3<u32>) {
  let row = groupId.x;
  let species = groupId.z;
  if (row >= params.gridH || species >= params.speciesCount) {
    return;
  }
  let n = params.gridW;
  let base = lrSpeciesBase(species, params) + row * n;
  let tid = localId.x;

  // The deposit's accumulator is the only real-valued input in the chain, and
  // the only place its fixed-point scale is undone.
  for (var i: u32 = tid; i < n; i = i + {{WORKGROUP_SIZE}}u) {
    line[i] = vec2<f32>(f32(srcDensity[base + i]) * INV_LR_DENSITY_SCALE, 0.0);
  }
  workgroupBarrier();

  let finalBase = lrRunStages(n, tid, -1.0);
  for (var i: u32 = tid; i < n; i = i + {{WORKGROUP_SIZE}}u) {
    dstSpectrum[base + i] = line[finalBase + i];
  }
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn transformRowsInverse(@builtin(workgroup_id) groupId: vec3<u32>,
                        @builtin(local_invocation_id) localId: vec3<u32>) {
  let row = groupId.x;
  let species = groupId.z;
  if (row >= params.gridH || species >= params.speciesCount) {
    return;
  }
  let n = params.gridW;
  let base = lrSpeciesBase(species, params) + row * n;
  let tid = localId.x;

  for (var i: u32 = tid; i < n; i = i + {{WORKGROUP_SIZE}}u) {
    line[i] = srcSpectrum[base + i];
  }
  workgroupBarrier();

  let finalBase = lrRunStages(n, tid, 1.0);
  // The last pass of the round trip, so the potential lands real. The
  // imaginary part is zero up to rounding: the density was real, and every
  // stage since preserved the conjugate symmetry that makes it so.
  for (var i: u32 = tid; i < n; i = i + {{WORKGROUP_SIZE}}u) {
    dstPotential[base + i] = line[finalBase + i].x;
  }
}
