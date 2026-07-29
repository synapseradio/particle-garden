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
// "chemistry" writes a cell of the live per-species array by reference, the
// same contract the attraction matrix uses, so setParam does not route it.
export type ParamStore =
  | "sim"
  | "render"
  | "palette"
  | "chemistry"
  | "camera";

// How many values one descriptor stands for. A scalar holds one for the whole
// world; a per-species descriptor holds one per species and carries the slot
// that locates it inside a species' stride.
export type ParamArity = "scalar" | "perSpecies";

// A labelled position on a slider worth stopping at. Nim decides which values
// earn one and what to call them; this file never invents a notch.
export interface ParamNotch {
  value: number;
  label: string;
}

// What bounds a value beyond the min/max envelope below.
//
// Constant for all but one tunable: the declared range is the whole story, and
// a slider's whole track is live. A derived bound means a pure function on the
// Nim side caps how much of the stored value takes effect, from other live
// parameters — so the track above the current ceiling is dormant, and that
// ceiling moves when those other parameters do. It arrives on the stats push,
// keyed by this descriptor's id; `reason` is Nim's own words for why.
export type ParamBound =
  | { kind: "constant" }
  | { kind: "derived"; ceilingId: string; reason: string };

// What every tunable carries, whatever its cardinality.
interface ParamDescriptorBase {
  id: string;
  label: string;
  group: string;
  kind: ParamKind;
  min: number;
  max: number;
  step: number;
  precision: number;
  // The travel curve (design E5). The panel never applies it — conversion
  // goes through paramValueAt/paramPositionOf — but it rides here so the
  // slider knows its position granularity.
  curve: "linear" | "log" | "power";
  curveExponent: number;
  positionStep: number;
  defaultValue: number;
  store: ParamStore;
  reinitOnCommit: boolean;
  // Guidance shown beside the label; empty for parameters that need none.
  hint: string;
  // Labelled tick positions. Empty for most parameters.
  notches: ParamNotch[];
  // What bounds the value beyond the envelope above.
  bound: ParamBound;
}

// One value for the world, read and written by id through getParam/setParam.
export interface ScalarParam extends ParamDescriptorBase {
  arity: "scalar";
}

// One value per species, held in the live array chemistry() returns. Read a
// cell as species * chemistryStride() + slot; write it back through the same
// index after clampParam. The union below is what keeps `slot` unreachable
// until the arity has been checked.
export interface PerSpeciesParam extends ParamDescriptorBase {
  arity: "perSpecies";
  slot: number;
}

export type ParamDescriptor = ScalarParam | PerSpeciesParam;

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
  // Parameters the simulation writes on its own, by id — the drifting climate
  // walks its axes from the frame loop. Present on every sample whether or not
  // anything is currently moving them, so the panel reports what the
  // simulation holds without tracking which feature wrote it.
  params: Record<string, number>;
  // The live ceiling of every derived bound, by parameter id. A ceiling moves
  // when the parameters it reads move, which the panel may not have caused, so
  // it arrives on this sample rather than being asked for — the same channel
  // and the same reason as `params` above.
  ceilings: Record<string, number>;
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
  // Bound a value against its descriptor without writing it, for controls that
  // own their own storage — the per-species grid writes cells of chemistry()
  // by reference and clamps them through here.
  clampParam(id: string, value: number): number;
  // The travel-curve pair (design E5): position in [0, 1] to lattice value
  // and back. Nim owns both directions; the panel computes no mapping.
  paramValueAt(id: string, position: number): number;
  paramPositionOf(id: string, value: number): number;

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
  // The parameter ids the climate writes as it drifts. Nim names them once
  // (climate_core.CLIMATE_PARAM_IDS); this UI asks rather than listing them,
  // so an axis added there reaches the panel without a TypeScript edit.
  climateParamIds(): string[];

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
  // frame, so a write lands on the next frame with no upload call). Which
  // columns exist comes from descriptor()'s per-species entries.
  chemistry(): Float32Array;
  chemistryStride(): number;

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
