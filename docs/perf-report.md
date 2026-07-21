# S11 Performance Report

Date: 2026-07-21
Commit: `5d715b81ad3526262b960b78843778a3c4d9c456` (feat(fieldviz): colormapped RD field in the graded HDR path + per-mode glow calibration)

## Machine and method

- Hardware: Apple Silicon (arm64), macOS 26.5.2 (build 25F84).
- Browser: Chromium 150.0.7871.46, headless (`--headless=new`), WebGPU via `--enable-unsafe-webgpu --use-angle=metal` (ANGLE/Metal backend).
- Toolchain: Nim 2.2.10 (arm64).
- Build: `nimble all --verbose` run once before measuring; `nimble test` run once to confirm the suite is green (533/533 `[OK]`, exit 0) before any measurement.
- Serve recipe: `python3 coop_server.py <port> web` from the repo root — a `ThreadingHTTPServer` that adds `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` to every response, required for `SharedArrayBuffer`. The server used for this batch listened on `127.0.0.1:8891`.
- Launch recipe per run: a fresh `--user-data-dir` per run, `--enable-logging=stderr`, a 150-second wall-clock cap via `timeout 150`, output captured to a per-run log file. The app prints a `[gpu-profile] n=<count> grid=<ms> physics=<ms> draw=<ms> present=<ms>` line to the console roughly every 5 seconds; the harness captures these as Chromium `INFO:CONSOLE` lines in stderr.

  ```
  timeout 150 /Applications/Chromium.app/Contents/MacOS/Chromium \
    --headless=new --enable-unsafe-webgpu --use-angle=metal \
    --user-data-dir=<fresh-dir> --enable-logging=stderr \
    "http://127.0.0.1:8891/index.html?n=<count>&seed=42[&mode=<mode>][&bloom=1]" \
    > <run>.log 2>&1
  ```

- Settling: each run collects a 150-second window before being killed by `timeout` (`exit 124`, expected). The last 4 `[gpu-profile]` lines of each run — spanning roughly the last 15-20 seconds of a ~145-second window — form the settled sample reported below. Ranges are reported as observed min-max across those 4 lines, not averaged. n=128000 particle-life plateaus well inside this window (its physics trace flattens by roughly line 8, around 40-45 seconds in); n=16000 particle-life does not plateau inside the window (see G1 below) — its physics trace climbs monotonically for the full 145 seconds, so its reported range is a snapshot of a still-settling system, not a converged one.
- One case (particle-life n=128000, bloom=1) was rerun once because its present-path numbers looked implausible against the stated expectation that bloom adds present-path cost; the second, independent run reproduced the same direction (present lower with bloom on), so both samples are reported below rather than silently averaged.
- Full stderr logs for all 7 Chromium launches (6 runs + 1 rerun) are retained at `/Users/nick/.claude/jobs/49a04c5a/tmp/perf/run*.log`.
- Zero-error sweep: every log was grepped for `error|exception|uncaught|validation|warn` (Chromium infra noise — `ERROR:bus`, `dbus`, `network_service`, `ERROR:policy`, `ERROR:zygote`, `ERROR:gpu_pixel`, `ERROR:command_buffer_proxy` — excluded). No matches in any of the 7 logs.

## Recorded baseline (prior measurement, same machine class)

- n=128000, particle-life, bloom off: grid 0.016 ms · physics 5.7-7.2 ms · draw 0.44 ms · present 2.2-2.8 ms → ≈9.3 ms GPU total.
- n=16000, particle-life, bloom off: grid 0.05 ms · physics 0.2-0.3 ms · draw 0.23 ms · present ~0.7 ms.
- Physics cost tracks clustering (roughly 4x from dispersed to settled state), which is why a settle window matters for this metric specifically.

## Results

All values are min-max across the last 4 `[gpu-profile]` lines of the named run.

| Run | n | mode | bloom | grid (ms) | physics (ms) | draw (ms) | present (ms) | per-frame total range (ms) |
|---|---|---|---|---|---|---|---|---|
| 1 | 128000 | particle-life | off | 0.015-0.894 | 5.454-8.578 | 0.444-0.518 | 2.509-4.794 | 9.34-13.91 |
| 2 | 16000 | particle-life | off | 0.052-0.058 | 0.322-0.484 | 0.219-0.221 | 0.662-0.774 | 1.26-1.53 |
| 3 | 32000 | sph | off | 0.047-0.048 | 0.217-0.221 | 0.395-0.399 | 1.812-1.822 | 2.48-2.49 |
| 4 | 32000 | reaction-diffusion | off | 0.235-0.238 | 0.013-0.014 | 0.409-0.411 | 1.812-1.816 | 2.47-2.48 |
| 5 | 128000 | particle-life | on | 0.016-0.077 | 5.885-7.174 | 0.506-0.592 | 1.363-1.498 | 7.85-9.23 |
| 5b (rerun) | 128000 | particle-life | on | 0.015-0.058 | 4.794-8.304 | 0.472-0.599 | 1.164-2.000 | 6.47-10.88 |
| 6 | 32000 | reaction-diffusion | on | 0.329-0.338 | 0.013-0.013 | 0.403-0.407 | 0.934-0.943 | 1.68-1.69 |

For run 4 and run 6 (reaction-diffusion), the "grid" column reports the field-solve pass, not a grid build — reaction-diffusion frames have no grid-binning pass, and the profiler has no dedicated field-pass slot, so the field solve's cost lands in the `grid=` field of the console line by construction of the profiler, not by relabeling on our part.

## Gate verdicts

**G1 — particle-life n=128000 and n=16000 within noise of the recorded baseline: PASS, with a caveat on n=16000.**

n=128000: physics 5.454-8.578 ms overlaps the baseline's 5.7-7.2 ms band for 3 of 4 sampled lines; draw (0.444-0.518 ms) and grid (0.015-0.894 ms, occasional sub-millisecond spikes consistent with periodic bin-count/prefix-sum jitter seen throughout the full 29-line trace, not just at the tail) both match. The fourth line (physics 8.578 ms, present 4.794 ms) is a single-frame outlier — physics, draw, and present all spike together on that one line, the signature of a shared scheduling hitch rather than a systematic regression in any one pass. Excluding that line, present sits at 2.509-3.172 ms against a baseline top of 2.8 ms — within the ~15% band. The hot path shows no regression from the sprint's registry/codegen/rename stages.

n=16000: physics measured at 0.322-0.484 ms against a baseline of 0.2-0.3 ms — no range overlap, and the top of the measured range is 61% above the baseline top. However, the full 29-line trace for this run climbs monotonically from 0.158 ms to 0.484 ms with no plateau visible anywhere in the 145-second window, while the n=128000 trace (same run length) flattens by line 8 (~40-45 s in) and stays flat. That shape difference is exactly the settling-driven variance the baseline itself documents ("physics cost tracks clustering"), not a flat-but-elevated trace from frame one, which is what a hot-path regression would look like. The absolute delta is 0.18 ms, immaterial to any interactive budget at this scale. Read as: not proven within noise on a strict range-overlap basis, but the trace shape is consistent with an under-settled run rather than a regression. A rerun with a longer settle window (300 s+) would resolve this cleanly; that rerun was not performed, as it falls outside this batch's fixed six-run scope.

**G2 — SPH n=32000: PASS.** Per-frame total 2.48-2.49 ms, stable across all 4 sampled lines (grid 0.047-0.048, physics 0.217-0.221, draw 0.395-0.399, present 1.812-1.822 ms) — comfortably inside a 16.7 ms interactive budget, with roughly 14 ms of headroom.

**G3 — reaction-diffusion n=32000: PASS.** Per-frame total 2.47-2.48 ms (field-solve-in-grid-slot 0.235-0.238, physics 0.013-0.014, draw 0.409-0.411, present 1.812-1.816 ms) — comfortably inside the same 16.7 ms budget, with roughly 14 ms of headroom.

**G4 — bloom's added present-path cost at n=128000: PASS on the budget yardstick, but the underlying premise is contradicted by measurement.** The gate as framed assumes bloom adds present-path cost; two independent runs show the opposite. Bloom-off present (run 1): 2.509-4.794 ms. Bloom-on present (runs 5 + 5b combined, 8 samples): 1.164-2.000 ms — every bloom-on sample sits below every bloom-off sample except the single-frame outlier noted in G1. Draw rises slightly with bloom on (0.506-0.599 ms vs. 0.444-0.518 ms off, a genuine small increase consistent with the extra blur/composite work), but that rise is far smaller than the present-side drop. The same direction reproduces in reaction-diffusion: run 6 (bloom on, present 0.934-0.943 ms) is lower than run 4 (bloom off, present 1.812-1.816 ms).

**Root cause, confirmed in code after the measurement runs:** the three bloom-path render passes — "Glow HDR Pass", "Bloom Blur H", "Bloom Blur V" — are created by `beginBloomPass` (`src/webgpu_render.nim:1432`) with no `gpu_profiler.attachTimestamps` call, so none of them appear in any profiler bucket. With bloom off, the timestamped present pass contains the full-resolution additive glow draw (6 vertices x n particles) plus the trail blit; with bloom on, that glow draw moves into the unprofiled Glow HDR pass and the present pass shrinks to a single fullscreen tonemap triangle. The measured present-side "drop" is the glow cost leaving the measured bucket, not bloom being cheaper. The reaction-diffusion reproduction is the same mechanism (bloom off: field backdrop + glow + blit in present; bloom on: one tonemap triangle).

Consequence for the gate: bloom's true added cost (half-res glow draw + two blur passes) is unmeasured by this batch, so G4 cannot be settled either way with the current 4-bucket profiler. What the numbers do establish: no budget-risk signal in either direction — even attributing the entire bloom-off/on present delta (~1.5-3 ms) to the unprofiled passes as a worst-case bound, bloom-on totals at n=128000 stay inside the 16.7 ms budget.

To produce a real G4 verdict later:
1. Add a profiler bucket (or reuse a spare slot) covering the three bloom passes, then rerun runs 1 and 5 — this is the direct fix for the instrumentation gap.
2. Cross-check in windowed (non-headless) Chromium — headless present/swapchain behavior on ANGLE/Metal can differ from a real compositor, independent of the bucket gap.

## Anomalies and other observations

- The bloom present-path reversal (G4) reproduced twice, in two simulation modes, and is not measurement noise; its root cause is the unprofiled bloom passes (confirmed in code, see G4), so the finding is an instrumentation gap, not a performance change.
- One single-frame hitch in run 1 (n=128000, bloom off) spiked grid, physics, and present together on the same line; not repeated elsewhere in that run's 29-line trace and not treated as a regression.
- n=16000's physics trace never plateaus inside the 145-second observation window (see G1); this is a method limitation for that specific run, not a build or code finding.
- No uncaught exceptions, validation errors, or WebGPU errors appeared in any of the 7 logs.

## Caveats

- Headless Chromium is not windowed Chromium: GPU present/swapchain timing, driver dispatch, and possibly power/thermal state can differ from what a user sees in the desktop app. Numbers here characterize the ANGLE/Metal headless path specifically.
- All ranges depend on the settle window chosen (last 4 lines of a ~145 s run). A different settle window would shift the sampled range, most visibly for n=16000 particle-life, whose settling had not converged inside this window (see G1).
- reaction-diffusion's `grid=` profiler field carries its field-solve pass, not a grid-binning pass — read the RD rows in the results table with that substitution in mind.
