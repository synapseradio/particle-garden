## MODIFIED Requirements

### Requirement: Stage order follows the compile-time embed graph

The build SHALL run four stages in the order `shaders` → `build-app` → `build-ui` → `build-native`
(`justfile:38`, and the same order restated by `justfile:60-61` for the release build). The order is
forced by two `staticRead` edges, each of which reads a file from disk at Nim-compile time:

- `src/webgpu_render.nim` embeds the bundled render shaders (`render`, `glow`, `fade`, `composite`,
  `blur`, `tonemap`, `overlay`) into `web/app.js`. `shaders` MUST therefore
  precede `build-app`.
- `src/main.nim:37-61` embeds `web/index.html`, `web/app.js`, `web/ui-bundle.js`,
  `web/ui-bundle.css`, and the bundled compute shaders into the native binary. `shaders`,
  `build-app`, and `build-ui` MUST therefore all precede `build-native`.

Because `staticRead` resolves at compile time, a missing input fails the compile that reads it.
`web-ui/build.ts:1-5` records the same constraint at the producing end.

#### Scenario: Full build honors the order

- **WHEN** `just happen` runs
- **THEN** `shaders`, `build-app`, and `build-ui` all complete before `nim c --out:main src/main.nim`
  is invoked

#### Scenario: A missing embedded artifact fails the native compile

- **WHEN** `nim c --out:main src/main.nim` runs without `web/ui-bundle.js` on disk
- **THEN** the compile fails at the `staticRead` in `src/main.nim:43` rather than producing a binary

#### Scenario: Release build repeats the same order

- **WHEN** `just release` runs
- **THEN** it depends on `shaders build-app build-ui` before compiling `src/main.nim`
  (`justfile:60-61`)
