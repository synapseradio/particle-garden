// Bundles the Solid control panel into web/ui-bundle.js (+ ui-bundle.css).
// A build script rather than the `bun build` CLI because the CLI cannot load
// plugins, and Solid's JSX needs the Babel transform from bun-plugin-solid.
// main.nim staticReads the outputs at compile time, so this must run before
// `nim c` — `just happen` enforces that order.
import { SolidPlugin } from "@dschz/bun-plugin-solid";

const result = await Bun.build({
  entrypoints: ["./src/main.tsx"],
  outdir: "../web",
  target: "browser",
  format: "esm",
  minify: true,
  naming: { entry: "ui-bundle.[ext]", asset: "ui-bundle.[ext]" },
  plugins: [SolidPlugin({ generate: "dom", hydratable: false })],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
for (const artifact of result.outputs) {
  console.log(`built ${artifact.path} (${artifact.size} bytes)`);
}
