// TS 7 requires side-effect CSS imports to resolve to a module declaration;
// Bun's bundler extracts them into ui-bundle.css at build time.
declare module "*.css";
