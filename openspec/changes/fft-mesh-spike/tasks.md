## 1. Harness

- [x] 1.1 Write the Stockham radix-2 line transform `scratchpad/fft-spike/fft_line.wgsl` as a
      template (line length, log2, shared extent and the index expression substituted in JS)
      and verify `getCompilationInfo()` reports no error message for the row and column
      instantiations at every measured size.
- [x] 1.2 Write the per-bin k-space passes `scratchpad/fft-spike/kernel.wgsl` (scalar Yukawa,
      in place) and `scratchpad/fft-spike/mix_kernel.wgsl` (the 12x12 species matvec, out of
      place) and verify both compile clean and neither dispatch exceeds
      `maxComputeWorkgroupsPerDimension`, observed as a run with no uncaptured device error.
- [x] 1.3 Write `scratchpad/fft-spike/main.js` and `index.html` so the page builds the round
      trip, publishes `window.__fftVerify` / `__fftResults` / `__fftDone`, and verify the page
      reaches `__fftDone === true` with `window.__fftError` null.
- [x] 1.4 Write `scratchpad/fft-spike/run_fft.ts` on the launch shape of
      `scratchpad/main/perf-harness/run.ts` and verify it writes
      `scratchpad/fft-spike/runs/<id>.json` carrying the browser string read from
      `/json/version`.

## 2. Verification before timing

- [x] 2.1 Round-trip an impulse per layer at 512x256x12 through forward, identity kernel and
      inverse, and verify the recorded max absolute error against the input is within f32
      tolerance (order 1e-7 on unit-amplitude data).
- [x] 2.2 Check the impulse's forward spectrum against its analytic value, unit modulus in
      every bin with the linear phase of its offset, and verify both recorded errors are at
      f32 noise.
- [x] 2.3 Round-trip a single cosine at (kx=3, ky=5) and check its forward spectrum carries
      `W*H/2` at that bin and at its conjugate with everything else at noise, and verify the
      recorded relative errors are at f32 noise.

## 3. Measurement

- [x] 3.1 Serve `scratchpad/fft-spike` with `scratchpad/main/perf-harness/coop_server.py` on
      8893 and verify the response carries both `Cross-Origin-Opener-Policy: same-origin` and
      `Cross-Origin-Embedder-Policy: require-corp`.
- [x] 3.2 Confirm `timestamp-query` is present on the adapter and that returned deltas are not
      quantized to a 100 us grid; verify by reading `adapter.features` and the raw nanosecond
      deltas in the run JSON, and fall back to wall clock over many iterations with
      `queue.onSubmittedWorkDone` if either fails, labelled as the weaker measurement.
- [x] 3.3 Run the six sizes (256x128, 512x256, 1024x512, each at batch 12 and batch 1) plus
      the 12x12 k-space mix at 512x256x12, and verify each config's `errorDuringConfig` is
      null in the run JSON.
- [x] 3.4 Record each figure as a min-max over the last four samples of its window, never an
      average, matching `docs/perf-report.md`, and verify the full trace is retained in the
      run JSON so drift inside the window is visible.

## 4. Report

- [x] 4.1 Write `design.md` with the machine, the browser build, the WGSL approach, the sizes,
      the numbers with their conditions, and what is proven versus inferred, and verify
      `openspec validate fft-mesh-spike` passes.
- [x] 4.2 Retain every run's JSON and Chromium stderr under `scratchpad/fft-spike/runs/`, one
      `<id>.json` and one `<id>.log`, and verify both files exist for the reported run.
- [x] 4.3 Confirm `git status --porcelain` names nothing under `src/`, `web/`, `web-ui/` or
      `tests/`, so `just happen` and `just check` are untouched by this change and are not
      run for it.

## 5. Repeat

- [x] 5.1 Sweep all seven configurations twice in one page load (`--repeat 2`) from the
      installed `/Applications/Chromium.app`, and verify pass 1 reproduces the first run's
      settled ranges within 1% at every configuration.
- [x] 5.2 Record the machine's contention at the start of the repeat so the two runs are
      comparable, and verify the app's server on 8089 was again not answering.
- [x] 5.3 Settle whether the drift inside the 1024x512 windows is the size or the session by
      comparing pass 2 against pass 1 at unchanged sizes, and record the answer in `design.md`
      with the per-pass evidence.
