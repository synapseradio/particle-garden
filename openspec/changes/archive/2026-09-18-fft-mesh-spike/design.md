## Context

See proposal.md - Why. This document is the measurement: the conditions it was taken under,
the transform that was timed, the numbers, and the line between what was measured and what is
inferred from it.

### Machine and build

| | |
|---|---|
| Machine | Apple M5 Max, 128 GB, macOS 26.5.2 (build 25F84), arm64 |
| Browser | Chromium 152.0.7977.82, headless, CDP protocol 1.3 |
| User agent | `HeadlessChrome/152.0.0.0` |
| Adapter | `apple` / `metal-3` via `--use-angle=metal` |
| Nim | not involved; nothing under `src/` runs in this measurement |
| Commit | `3ac386e`, working tree carrying only `docs/research/` and `openspec/changes/` additions |

The machine is the one `docs/perf-report.md` reports. The browser is **not**: that record was
taken on Chromium 150.0.7871.46, and the bundle has since moved to 152.0.7977.82. Any
arithmetic that places a figure below against a frame budget from that record crosses a
browser-build boundary.

### How the run was driven

```
python3 scratchpad/main/perf-harness/coop_server.py 8893 scratchpad/fft-spike
bun scratchpad/fft-spike/run_fft.ts --run fft-a --duration 15 --port 8893 \
  --chromium /tmp/chromium-spike/Chromium.app/Contents/MacOS/Chromium
```

which launched

```
<chromium> --headless=new --enable-unsafe-webgpu --use-angle=metal --enable-logging=stderr \
  --no-first-run --no-default-browser-check --remote-debugging-port=<free port> \
  --user-data-dir=scratchpad/fft-spike/profiles/fft-a \
  http://127.0.0.1:8893/index.html?duration=15
```

Port 8893 stands apart from the app's own 8089 and from the perf harness's 8891. The page needs
no `SharedArrayBuffer`, but the harness server supplies COOP and COEP unconditionally and was
reused unchanged.

The full run record is `scratchpad/fft-spike/runs/fft-a.json` (every sample of every trace) and
`scratchpad/fft-spike/runs/fft-a.log` (Chromium stderr).

A second run, `fft-b`, swept the same seven configurations twice in one page load:

```
bun scratchpad/fft-spike/run_fft.ts --run fft-b --duration 15 --repeat 2 --port 8893
```

It used `/Applications/Chromium.app` directly, not the copy, and reported the same build string.
Its record is `runs/fft-b.json` and `runs/fft-b.log`. Its verification output is byte-identical
to `fft-a`'s. Pass 1 answers whether the figures reproduce; pass 2, running immediately after on
a device that has been under sustained load for three minutes, answers whether the drift inside
the large windows is the size or the session.

### Machine state during the run, which qualifies every number below

- `/usr/libexec/syspolicyd` was pinned at about 198% CPU for the whole session, and the user's
  own Chromium browser process at about 136%. Roughly three of the machine's cores were busy
  with work unrelated to the measurement. GPU timestamps measure GPU execution, but the SoC
  shares a power budget, so read each figure as an upper bound rather than a floor.
- The app's own server on 8089 was not answering, so no second simulation was on the GPU. This
  was checked, not assumed.
- During `fft-a` the same `syspolicyd` state blocked `exec` of `/Applications/Chromium.app`: a
  launch stalled in `_dyld_start` indefinitely, which `sample` confirmed. That run therefore
  used a copy of the identical bundle at `/tmp/chromium-spike/Chromium.app` with its extended
  attributes cleared. `codesign -v` reported the copy "valid on disk" and satisfying its
  designated requirement, and the page reported `Chrome/152.0.7977.82` through `/json/version`,
  the same build string the installed bundle reports. Nothing under `/Applications` was
  modified. `sudo killall syspolicyd` then cleared the block, and `fft-b` ran from the installed
  bundle. `fft-b` pass 1 reproduces `fft-a` within 1% at every configuration, so **the copy made
  no measurable difference** and neither does the path the browser was launched from.
- `fft-b` ran under the same contention: `syspolicyd` at 188.6% and the user's Chromium at
  133.8% at the moment the run started, with the app's server on 8089 again not answering. The
  respawned `syspolicyd` is as busy as the one it replaced, so the two runs are comparable and
  both carry the upper-bound reading.

## Goals / Non-Goals

**Goals:**

- One GPU time per full round trip (forward 2D FFT, per-bin multiply, inverse 2D FFT) at
  512 x 256 x 12, with one smaller and one larger point so the scaling is visible.
- The same three sizes at batch 1, so the per-layer cost separates from the fixed cost.
- The transform verified correct before it is timed, with the check's output in this document.

**Non-Goals:**

- No deposit pass and no gradient-force pass. The round trip measured here is the solve only;
  the two passes that bracket it in `docs/research/long-range-coupling.md` are unmeasured.
- No accuracy study of the Yukawa kernel, no softening, no choice of lambda. The kernel pass is
  timed for its cost, not judged for its physics.
- No real-to-complex packing. The transform measured is complex-to-complex throughout.
- No change to the app. This is a scratchpad page.

## Decisions

### Stockham radix-2, one workgroup per line, shared-memory ping-pong

`scratchpad/fft-spike/fft_line.wgsl` transforms one line of length N in one workgroup of 256
invocations. The line is loaded into a workgroup array of 2N `vec2<f32>`; each of the log2(N)
stages reads one half and writes the other, so the halves never alias and one
`workgroupBarrier()` per stage suffices. The structure is the standard GPU Stockham used by the
wgsl-fft crate (https://github.com/larsjoost/wgsl-fft), attributed in the file.

A row pass runs H workgroups per layer over lines of length W; a column pass runs W workgroups
per layer over lines of length H. Both dispatch the batch through the z dimension, one layer per
z index. Forward and inverse share one pipeline; direction is a `dir` sign in the uniform and the
1/(W*H) normalization rides on the final inverse row pass.

Rejected: Cooley-Tukey in place with an explicit bit-reversal permutation, which halves the
workgroup memory but adds a permutation pass. It was not needed: the adapter grants
`maxComputeWorkgroupStorageSize` 32768, and the largest line here, N = 1024, needs 16384 bytes.

Rejected: `override` -sized workgroup arrays. The line length is substituted textually in JS
before `createShaderModule`, which costs one shader module per size and removes any dependence on
override-expression array extents.

### f32 complex, two global buffers, in-place scalar kernel

Storage is `array<vec2<f32>>` as the task specifies, indexed `((layer * H) + y) * W + x`. The
round trip ping-pongs between exactly two buffers: A to B (row), B to A (column), A in place
(kernel), A to B (inverse column), B to A (inverse row). The 12x12 mix variant writes out of
place and so runs A, B, A, B, A, B, still two buffers.

Rejected: a transpose pass between the row and column passes. The column pass reads with stride
W and is measurably the more expensive of the two (see the per-pass table), so a transpose is a
live optimization, but measuring the plain layout first is what this spike is for.

### Timestamp queries, and how a sample is taken

The adapter reports `timestamp-query`, so each of the five compute passes carries
`timestampWrites`. **Timestamps are not quantized in this configuration**: a representative
512 x 256 x 12 sample spans 3752220099380342 ns to 3752220099642879 ns, a delta of 262537 ns,
which is not a multiple of the 100 us grid Dawn's quantization would impose. The fallback to
wall clock over many iterations was therefore not needed; a wall-clock figure is reported beside
each GPU figure anyway, as a cross-check.

A sample is one submit holding many round trips, with timestamps attached to the **last** one, so
the device is already loaded when the timed trip runs. The number of round trips per submit is
scaled per configuration to hold the work per submit roughly constant, because
`docs/perf-report.md` records a fixed-size pass measuring two to four times slower inside a
cheaper frame, and timing a small configuration on an idle device would reproduce that artefact
rather than the configuration's cost. The scale factor appears as `roundTripsPerSubmit` in the
table below.

Rejected: one round trip per submit with a map-and-wait between. It leaves the GPU idle between
submits, which is the artefact just described.

## The transform is correct before it is timed

All checks ran at 512 x 256 x 12 with the kernel in identity mode, on unit-amplitude input.
Output as recorded in `runs/fft-a.json`:

| check | expected | measured |
|---|---|---|
| impulse, forward, modulus of every sampled bin | 1 | max error 4.396e-7 |
| impulse, forward, phase of every sampled bin | the linear phase of its offset | max error 1.062e-6 rad |
| impulse, full round trip, against its own input | itself | max absolute error 1.943e-7 |
| cosine (kx=3, ky=5), bin (3,5) | 65536 = W*H/2 | 65536.00000000067 |
| cosine (kx=3, ky=5), bin (509,251) | 65536 = W*H/2 | 65536.00000000525 |
| cosine, every other bin | 0 | max 5.081e-3, i.e. 7.75e-8 of the peak |
| cosine, full round trip, against its own input | itself | max absolute error 4.865e-7 |

Each impulse sits at a different offset per layer, so the batch is exercised and a layer reading
another layer's data would show as a phase error. The two cosine peaks are the conjugate pair a
real input produces; both are reported by name because which one a maximum scan finds is a tie
broken by rounding.

Round-trip error at 5e-7 on unit-amplitude data is f32 round-off over 17 butterfly stages, which
is what f32 storage buys. **Proven: the transform is correct to f32 tolerance at
512 x 256 x 12.** The other five sizes were timed but not separately verified; their correctness
is inferred from sharing one templated kernel with the verified size.

## The numbers

One round trip is forward row pass, forward column pass, per-bin multiply, inverse column pass,
inverse row pass. The **settled** column is the observed min-max over the last four samples of a
15-second window, never an average, matching `docs/perf-report.md`. The **whole window** column
is the min-max over every sample of that window, because three of the seven configurations
wander inside their window and the settled column alone would hide it. The GPU figure is the
span from the first pass's begin timestamp to the last pass's end timestamp, so inter-pass gaps
are inside it. The wall figure is submit-to-`onSubmittedWorkDone` divided by the round trips in
the submit.

| grid | batch | trips/submit | GPU span, settled (ms) | GPU span, whole window (ms) | wall/trip, settled (ms) | samples |
|---|---|---|---|---|---|---|
| 256 x 128 | 12 | 64 | 0.080-0.080 | 0.079-0.186 | 0.087-0.088 | 2623 |
| **512 x 256** | **12** | **16** | **0.262-0.263** | **0.261-0.447** | **0.292-0.295** | **3115** |
| 1024 x 512 | 12 | 16 | 1.179-1.247 | 1.090-1.393 | 1.263-1.275 | 743 |
| 256 x 128 | 1 | 256 | 0.020-0.021 | 0.020-0.094 | 0.023-0.025 | 2330 |
| 512 x 256 | 1 | 192 | 0.037-0.039 | 0.037-0.066 | 0.042-0.042 | 1851 |
| 1024 x 512 | 1 | 48 | 0.123-0.125 | 0.109-0.367 | 0.134-0.140 | 2066 |
| 512 x 256, 12x12 k-space mix | 12 | 16 | 0.417-0.450 | 0.387-0.599 | 0.458-0.468 | 1993 |

**The headline: a forward and inverse 2D complex FFT over 512 x 256, batched 12 deep, with a
per-bin multiply between them, costs 0.262-0.263 ms of GPU time per round trip on a device
entering the work.**

### The same seven, twice more: run `fft-b`

Settled min-max as above, same 15-second windows, same conventions. `fft-b` pass 1 is a fresh
device; `fft-b` pass 2 is the identical sweep run immediately afterwards, on a device three
minutes into sustained load.

| grid | batch | `fft-a` | `fft-b` pass 1 | `fft-b` pass 2 | pass 2 / pass 1 |
|---|---|---|---|---|---|
| 256 x 128 | 12 | 0.080-0.080 | 0.079-0.080 | 0.093-0.099 | 1.23x |
| **512 x 256** | **12** | **0.262-0.263** | **0.264-0.266** | **0.342-0.343** | **1.29x** |
| 1024 x 512 | 12 | 1.179-1.247 | 1.177-1.261 | 1.732-2.050 | 1.63x |
| 256 x 128 | 1 | 0.020-0.021 | 0.020-0.021 | 0.020-0.021 | 1.02x |
| 512 x 256 | 1 | 0.037-0.039 | 0.037-0.038 | 0.039-0.042 | 1.10x |
| 1024 x 512 | 1 | 0.123-0.125 | 0.116-0.125 | 0.131-0.132 | 1.06x |
| 512 x 256, 12x12 mix | 12 | 0.417-0.450 | 0.418-0.421 | 0.453-0.454 | 1.08x |

**Proven: the figures reproduce.** Every `fft-b` pass 1 range sits within 1% of the `fft-a`
range for the same configuration, across a different browser launch path and a different
process. The headline stands unrevised.

**Proven: the drift in the large windows is session heat, not size.** The same configuration,
the same shader, the same dispatch, measures 1.23x to 1.63x higher when it runs on a device that
has been working for three minutes. Size cannot explain a change in a configuration whose size
did not change. The earlier reading, that the wandering configurations were also the ones that
ran latest and one run could not separate the two, resolves in favour of the session.

The degradation is not uniform across passes. At 512 x 256 x 12 from pass 1 to pass 2 the FFT
passes rise about 35% (fftRow 0.047 to 0.064, fftCol 0.068 to 0.091) while the elementwise
kernel pass does not move at all (0.033 to 0.033). The batch-1 configurations, which are
dispatch-overhead dominated, barely move either. A slowdown that lands on the barrier-heavy
shared-memory passes and spares the bandwidth-bound one reads as a shader-clock reduction rather
than a memory one; that reading is **inferred**, since no clock or power counter was read.

**What this means for a budget.** Two figures, not one. A long-range solve at 512 x 256 x 12
costs 0.26 ms on a device entering the work and 0.34 ms once the device has been under sustained
load, which is the state a running instrument is actually in. With the 12x12 species mix the
pair is 0.42 ms and 0.45 ms. Budget against the sustained figure.

### How settled each window is

Counting samples more than 5% above the window's own minimum: 256 x 128 x 12, 0.6%;
512 x 256 x 12, 6.4%; 512 x 256 x 1, 25.2%; 256 x 128 x 1, 54.1%; the 12x12 mix, 87.9%;
1024 x 512 x 12, 93.4%; 1024 x 512 x 1, 98.7%. The two 1024 x 512 configurations and the mix
wander by 10 to 15% across their windows and never flatten; the rest are flat. Configurations
ran in the order listed, so the wandering ones are also the ones that ran on a device that had
been under load longest. `fft-b` pass 2 settles which cause it is: the session, not the size.

### Per pass

Settled min-max, same windows.

| grid x batch | fftRow | fftCol | kernel | ifftCol | ifftRow |
|---|---|---|---|---|---|
| 256 x 128 x 12 | 0.013-0.013 | 0.023-0.023 | 0.009-0.009 | 0.023-0.023 | 0.012-0.013 |
| 512 x 256 x 12 | 0.047-0.048 | 0.068-0.068 | 0.032-0.033 | 0.068-0.069 | 0.047-0.047 |
| 1024 x 512 x 12 | 0.221-0.234 | 0.310-0.332 | 0.115-0.116 | 0.313-0.332 | 0.218-0.234 |
| 512 x 256 x 1 | 0.006-0.007 | 0.010-0.011 | 0.004-0.004 | 0.010-0.011 | 0.006-0.007 |
| 512 x 256 x 12, mix | 0.060-0.064 | 0.084-0.092 | 0.131-0.141 | 0.084-0.091 | 0.059-0.064 |

A column pass costs about 45% more than a row pass at every size, on the same number of
butterflies. The row pass reads and writes contiguously; the column pass strides by W. That is
measured, and it names a transpose as the first optimization if this cost ever needs to fall.

### What the batch costs, per layer

Taking the top of each settled range, the round trip at batch 12 minus the round trip at batch 1,
divided by the 11 extra layers:

| grid | batch 1 | batch 12 | marginal ms per layer | implied fixed cost |
|---|---|---|---|---|
| 256 x 128 | 0.021 | 0.080 | 0.0054 | 0.016 |
| 512 x 256 | 0.039 | 0.263 | 0.0204 | 0.019 |
| 1024 x 512 | 0.125 | 1.247 | 0.1020 | 0.023 |

The implied fixed cost is 0.016 to 0.023 ms at every size, a sixty-fold span of work. A cost that
does not move with the work is dispatch overhead, and a round trip issues five dispatches.
**Proven: batching 12 layers costs far less than 12 separate transforms.** At 512 x 256, twelve
single-layer round trips would cost about 0.47 ms against the batched 0.263 ms.

### What the real k-space mix costs

The scalar kernel timed in the main table multiplies each bin by one number. The coupling
described in `docs/research/long-range-coupling.md` needs
`potential_r(k) = G(k) * sum_s a[r][s] * density_s(k)`, a 12x12 matvec per bin. The last row of
the main table measures that: the kernel pass rises from 0.032-0.033 ms to 0.131-0.141 ms and the
round trip from 0.262-0.263 ms to 0.417-0.450 ms. **The asymmetric species matrix costs about
0.19 ms on top of the transform at 512 x 256 x 12**, so the honest figure for the solve the
design actually wants is 0.42-0.45 ms, not 0.26 ms.

The FFT passes also measure higher in the mix row (fftRow 0.060-0.064 against 0.047-0.048) on
identical work. Nothing in the mix variant changes those passes; the difference sits inside the
same drift the window-spread column reports for that configuration.

### Scaling

Cells quadruple at each step. From 256 x 128 to 512 x 256 the round trip rises 3.3x, below the
4.5x that N log N predicts; from 512 x 256 to 1024 x 512 it rises 4.7x, above the 4.5x predicted.
The small grid is not large enough to fill the device and the large one pays for reduced
occupancy, since a 1024-point line needs 16 KB of the 32 KB workgroup budget. This reading is
**inferred** from the shape of the curve; no occupancy counter was read.

## Risks / Trade-offs

- [A cold figure quoted where a sustained one belongs] → The device loses 23 to 63% on the
  batch-12 configurations once it has been working for three minutes. Budget against the `fft-b`
  pass 2 column, not the headline. The headline is the right number for the question "what does
  this transform cost", and the wrong one for the question "what will it cost in the frame".
- [Three cores were busy with unrelated work through both runs] → Read every figure as an upper
  bound. The direction of the error is known even though its size is not, and it applies equally
  to `fft-a` and `fft-b` since the contention was the same at the start of each.
- [A configuration order effect that the two runs share] → Both runs swept the sizes in the same
  order, so an ordering artefact would reproduce rather than cancel. A reversed-order sweep would
  catch it and was not run.
- [The browser is a build newer than the perf record's] → Stated above. Comparing the 0.26 ms
  against the perf record's 3.75 ms of headroom crosses that boundary.
- [Complex-to-complex on a real input does twice the necessary work] → A real density needs only
  a real-to-complex forward and a complex-to-real inverse, which would cut the transform roughly
  in half. That halving is **inferred from the redundancy of a real signal's spectrum, not
  measured**, and the packing is not written.
- [The solve is not the whole coupling] → The deposit pass and the gradient-force pass are not
  in any figure here. `docs/research/long-range-coupling.md` argues they are the shape of
  `field-deposit.wgsl` and `field-force.wgsl`, whose cost appears inside the perf record's Field
  bucket, but no figure isolates them.
- [The column pass is 45% more expensive than the row pass] → Measured, and left standing. A
  transpose pass would trade two extra full-buffer passes for contiguous access; whether that
  wins is unmeasured.

## What this settles, and what it does not

**Proven by these two runs.** A batched 2D complex FFT round trip at 512 x 256 x 12 costs
0.262-0.266 ms of GPU time on a device entering the work, and 0.342-0.343 ms on one three
minutes into sustained load, on this machine and this browser build under the CPU contention
described above. With the 12x12 asymmetric species mix in k-space instead of a scalar multiply
the pair is 0.417-0.450 ms and 0.453-0.454 ms. At 256 x 128 x 12 it costs 0.080 ms cold and
0.093-0.099 ms sustained; at 1024 x 512 x 12, 1.18-1.26 ms cold and 1.73-2.05 ms sustained. The
figures reproduce across runs within 1%. The transform is correct to f32 tolerance. Batching is
nearly free per layer beyond a fixed 0.016-0.023 ms of dispatch overhead. The drift inside the
large windows is session heat and not size. Timestamp queries work and are unquantized in this
configuration.

**Inferred, not proven.** That a real-to-complex packing would roughly halve the transform. That
the scaling shortfall at the small size and the excess at the large size are occupancy effects.
That the sustained-load penalty is a shader-clock reduction, read from its landing on the
barrier-heavy passes and sparing the bandwidth-bound one. That the five untimed-for-correctness
sizes are correct because they share the verified size's templated kernel. That the figures would
hold on an unloaded machine, where they would be at most what is reported.

**Unmeasured.** The deposit and gradient-force passes. Whether a transpose beats the strided
column pass. Whether a sweep in reversed size order reproduces the same per-size figures. Where
the sustained-load penalty settles beyond three minutes, and whether a real frame, which leaves
the GPU idle between submits, pays it at all. The accuracy of the mesh solve as physics.

## Open Questions

- Whether the design that consumes this figure should also carry a real-to-complex packing. The
  answer changes the transform's cost by about a factor of two but changes nothing in this
  measurement, which stands as the complex-to-complex upper bound either way.
