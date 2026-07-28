// Typed surface of window.gardenAPI — the one boundary this UI talks
// through. The object is created by src/web_api.nim at app.js module-eval
// time, before this bundle evaluates. Every number (range, default, step,
// ceiling, storage key) comes from the Nim side via these calls; this
// project never restates one.
//
// Mutations are synchronous: a setParam call has landed in the simulation's
// CONFIG by the time it returns (the synchronous mirror invariant, see
// web_api.nim). Never wrap these calls in deferred/microtask plumbing.

export type ParamKind = "int" | "float";
export type ParamStore = "sim" | "render" | "palette";

export interface ParamDescriptor {
  id: string;
  label: string;
  group: string;
  kind: ParamKind;
  min: number;
  max: number;
  step: number;
  precision: number;
  defaultValue: number;
  store: ParamStore;
  reinitOnCommit: boolean;
  // Guidance shown beside the label; empty for parameters that need none.
  hint: string;
}

export interface SimMode {
  id: string;
  label: string;
  particleCeiling: number;
  // The descriptor groups this mode uses. The panel shows a control only
  // when the active mode lists its group — see lib/mode-gating.ts, which
  // still renders everything if an older app.js omits the field.
  groups: string[];
}

export interface PaletteSchemeEntry {
  id: string;
  label: string;
}

export interface ColormapEntry {
  index: number;
  label: string;
}

export interface StatsSample {
  fps: number;
  particleCount: number;
  gridTimeMs: number;
  workerTimeMs: number;
  gpuGridMs: number;
  gpuPhysicsMs: number;
  gpuDrawMs: number;
  gpuPresentMs: number;
  // The reaction-diffusion field pass. Zero in the other two modes, which run
  // no field — just as gpuGridMs is zero in reaction-diffusion, which builds
  // no spatial hash.
  gpuFieldMs: number;
}

export interface PresetKeys {
  prefix: string;
  indexKey: string;
  defaultName: string;
}

// A preset shipped with the app: Nim holds the JSON, so a starter never
// reaches localStorage and can neither collide with nor be overwritten by a
// saved preset of the same name.
export interface BuiltinPreset {
  id: string;
  label: string;
  mode: string;
  json: string;
}

export interface ApplyPresetResult {
  ok: boolean;
  error?: string;
}

export interface GardenAPI {
  // Lifecycle
  isReady(): boolean;
  onReady(callback: () => void): void;

  // Parameters
  descriptor(): ParamDescriptor[];
  getParam(id: string): number;
  setParam(id: string, value: number): void;
  commitParam(id: string): void;

  // Toggles
  getTrails(): boolean;
  setTrails(enabled: boolean): void;
  getBloom(): boolean;
  setBloom(enabled: boolean): void;

  // Simulation mode
  simModes(): SimMode[];
  getSimMode(): string;
  setSimMode(id: string): void;

  // Force model
  getForceModel(): number;
  setForceModel(model: number): void;

  // Palette / colormap
  paletteSchemes(): PaletteSchemeEntry[];
  getPaletteScheme(): string;
  isPaletteCustom(): boolean;
  setPaletteScheme(id: string): void;
  colormaps(): ColormapEntry[];
  getColormap(): number;
  setColormap(index: number): void;

  // Attraction matrix (live references; valid after onReady)
  matrix(): Float32Array;
  matrixCellColor(value: number): string;
  clampMatrixValue(value: number): number;
  matrixStride(): number;
  speciesColor(index: number): string;
  randomizeMatrix(): void;

  // Particles
  resetParticles(): void;

  // Reaction-diffusion field
  reseedField(): void;

  // Stats
  onStats(callback: (stats: StatsSample) => void): void;

  // Presets (Nim owns schema/validation/apply order; this UI owns storage)
  presetKeys(): PresetKeys;
  normalizePresetName(raw: string): string;
  exportPresetJson(name: string): string;
  exportPresetJsonPretty(name: string): string;
  applyPresetJson(json: string): ApplyPresetResult;
  builtinPresets(): BuiltinPreset[];
}

declare global {
  interface Window {
    gardenAPI?: GardenAPI;
  }
}
