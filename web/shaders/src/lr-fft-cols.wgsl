// =============================================================================
// LONG RANGE COLUMN TRANSFORM: one column of the mesh per workgroup
// =============================================================================
//
// WHY THIS EXISTS:
// The second axis of the two-dimensional transform. The row pass leaves each
// row transformed; this carries the same lines down the columns, after which
// the grid is in k-space and the kernel pass can multiply.
//
// SEPARATE FROM THE ROW PASS because the stride differs: a row is contiguous
// and a column steps by the live width. Running one file over both axes would
// mean a stride in a uniform and a transpose or an indirection on the hot path;
// two files keep each addressing visible where it is used. Forward and inverse
// share this file because they differ only in the twiddle's sign.
//
// No transpose pass. The strided reads cost coalescing on the column pass and
// buy back a full read and write of both spectra, which the spike measured as
// the cheaper arrangement at these sizes
// (openspec/changes/fft-mesh-spike/design.md).
//
// One line per workgroup, 2N complex values in workgroup storage, one barrier
// per stage, species on the dispatch's z extent at the LIVE species count.
// Mirrors src/long_range_core.nim's lrTransformLine.
//
// NEITHER DIRECTION NORMALIZES: the round trip's 1/(W*H) rides in the kernel.
// =============================================================================

//! import lr_params
//! import lr_grid

@group(0) @binding(0) var<storage, read> srcSpectrum: array<vec2<f32>>;
@group(0) @binding(1) var<storage, read_write> dstSpectrum: array<vec2<f32>>;
@group(0) @binding(2) var<uniform> params: LrParams;

const PI: f32 = 3.141592653589793;

// 2N entries at the largest line the declared mesh sizes allow; the live
// length comes from the uniform and the tail past it is never touched.
var<workgroup> line: array<vec2<f32>, {{LR_FFT_SHARED}}u>;

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

// One column: `column` picks the x, and consecutive entries step by the live
// width.
fn lrTransformColumn(groupId: vec3<u32>, localId: vec3<u32>, dirSign: f32) {
  let column = groupId.x;
  let species = groupId.z;
  if (column >= params.gridW || species >= params.speciesCount) {
    return;
  }
  let n = params.gridH;
  let base = lrSpeciesBase(species, params) + column;
  let stride = params.gridW;
  let tid = localId.x;

  for (var i: u32 = tid; i < n; i = i + {{WORKGROUP_SIZE}}u) {
    line[i] = srcSpectrum[base + i * stride];
  }
  workgroupBarrier();

  let finalBase = lrRunStages(n, tid, dirSign);
  for (var i: u32 = tid; i < n; i = i + {{WORKGROUP_SIZE}}u) {
    dstSpectrum[base + i * stride] = line[finalBase + i];
  }
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn transformCols(@builtin(workgroup_id) groupId: vec3<u32>,
                 @builtin(local_invocation_id) localId: vec3<u32>) {
  lrTransformColumn(groupId, localId, -1.0);
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn transformColsInverse(@builtin(workgroup_id) groupId: vec3<u32>,
                        @builtin(local_invocation_id) localId: vec3<u32>) {
  lrTransformColumn(groupId, localId, 1.0);
}
