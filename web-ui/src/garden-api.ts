// Typed surface of window.gardenAPI — the one boundary this UI talks
// through. The object is created by src/web_api.nim at app.js module-eval
// time, before this bundle evaluates. Every number (range, default, step,
// notch, storage key) comes from the Nim side via these calls; this
// project never restates one.
//
// Mutations are synchronous: a setParam call has landed in the simulation's
// CONFIG by the time it returns (the synchronous mirror invariant, see
// web_api.nim). Never wrap these calls in deferred/microtask plumbing.

export type ParamKind = "int" | "float";
// "camera" writes the live view rather than CONFIG, and is excluded from
// preset serialization: a preset restores a world, not where the user stands
// to look at it.
export type ParamStore = "sim" | "render" | "palette" | "camera";

// A labelled position on a slider worth stopping at. Nim decides which values
// earn one and what to call them; this file never invents a notch.
export interface ParamNotch {
  value: number;
  label: string;
}

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
  // Labelled tick positions. Empty for most parameters.
  notches: ParamNotch[];
}

// A named Gray-Scott regime: a POINT in the feed/kill plane, not a region.
// `minDeposit` is the measured deposit floor the regime needs to appear at all
// on the shipped path — 0 where the default already ignites it.
export interface RdRegime {
  id: string;
  label: string;
  feed: number;
  kill: number;
  minDeposit: number;
}

// One editable column of the per-species chemistry grid. Its own table rather
// than a ParamDescriptor because there is one value per SPECIES, not one per
// id: `slot` is the offset inside a species' stride, so the panel indexes the
// live array as species * chemistryStride() + slot without owning either
// number.
export interface ChemistryField {
  id: string;
  label: string;
  slot: number;
  min: number;
  max: number;
  step: number;
  precision: number;
  defaultValue: number;
  hint: string;
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
  // The reaction-diffusion field pass. Zero while the field couplings sit at
  // zero strength and the frame leaves their passes out.
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

  // Force model
  getForceModel(): number;
  setForceModel(model: number): void;

  // Palette / colormap
  paletteSchemes(): PaletteSchemeEntry[];
  getPaletteScheme(): string;
  isPaletteCustom(): boolean;
  setPaletteScheme(id: string): void;
  // Named reaction-diffusion regimes
  rdRegimes(): RdRegime[];
  getRdRegime(): string;
  applyRdRegime(id: string): void;

  // Drifting climate ("weather")
  getClimateDrift(): boolean;
  setClimateDrift(enabled: boolean): void;

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

  // Per-species field chemistry (live reference, same contract as matrix():
  // the frame loop copies the array into the SpeciesChemistry uniform every
  // frame, so a write lands on the next frame with no upload call)
  chemistry(): Float32Array;
  chemistryStride(): number;
  chemistryFields(): ChemistryField[];
  clampChemistry(id: string, value: number): number;

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
