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

interface ParamDescriptorBase {
  id: string;
  label: string;
  group: string;
  kind: ParamKind;
  min: number;
  max: number;
  step: number;
  precision: number;
  // The travel curve. The panel never applies it — conversion goes through
  // paramValueAt/paramPositionOf — but it rides here so the slider knows its
  // position granularity.
  curve: "linear" | "log" | "power";
  curveExponent: number;
  positionStep: number;
  /** When the world answers a move; the panel shows a settling indicator
   * until it elapses. */
  horizon: "instant" | "settling" | "structural";
  /** True where no stepping mirror executes the horizon claim, so the
   * declaration is review-enforced. */
  horizonReview: boolean;
  /** Id of the dormancy predicate naming when this control's consumer
   * cannot act; empty means never dormant. Evaluation stays in Nim —
   * dormantParams() — and the panel renders the result. */
  dormantWhen: string;
  /** The precondition line shown while dormant, e.g. "Bloom is off". */
  dormantLine: string;
  defaultValue: number;
  store: ParamStore;
  reinitOnCommit: boolean;
  // Guidance shown beside the label; empty for parameters that need none.
  hint: string;
  notches: ParamNotch[];
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
  // The long-range mesh solve, and the bodies pass (first substep's span). Zero
  // until the pass first runs; after its strength returns to zero the figure
  // holds its last reading, because a skipped pass writes no timestamps.
  gpuLongRangeMs: number;
  gpuBodiesMs: number;
  /** How many field cells resolved above the aliveness threshold this
   * frame; zero means the field is dark. Feeds the dormancy predicates
   * over world state. */
  fieldAliveCells: number;
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
  // The signed travel offset of every parameter a live excursion moves, by
  // id; empty when none. The slider shades the span from the handle's base by
  // this offset, on the same channel and cadence as `ceilings`.
  excursions: Record<string, number>;
}

// The listen affordance's state, named by Nim (audio_core.ListenState); the
// panel renders the name and restates no threshold behind it.
export type ListenState =
  | "Disconnected"
  | "Requesting"
  | "Connected"
  | "Denied"
  | "Silent";

// One source a family declares: a continuous value in [0, 1] or an event.
// Labels come from Nim; the meters and the mapping editor restate none.
export interface SourceEntry {
  id: string;
  label: string;
  kind: "continuous" | "event";
}

// The audio family's declarations, the same shape.
export type AudioSourceEntry = SourceEntry;

// A mapping row as the boundary serves it: the mapping document's own row
// shape plus where it sits and whether its source is declared this session.
// Everything a user reads calls one of these a mapping.
export type MappingRowKind = "modulate" | "write" | "fire" | "touch" | "tour";

interface MappingRowBase {
  index: number;
  kind: MappingRowKind;
  source: string;
  resolved: boolean;
}

export interface ModulateRow extends MappingRowBase {
  kind: "modulate";
  modParamId: string;
  depth: number;
  attackMs: number;
  releaseMs: number;
}

export interface WriteRow extends MappingRowBase {
  kind: "write";
  writeParamId: string;
  jump: boolean;
  rank: number;
}

export interface FireRow extends MappingRowBase {
  kind: "fire";
  actionId: string;
  ordinal: number;
}

export interface TouchRow extends MappingRowBase {
  kind: "touch";
  gridCols: number;
  gridRows: number;
  baseNote: number;
}

export interface TourRow extends MappingRowBase {
  kind: "tour";
  tourId: string;
  runningParamId: string;
  tourSpeedParamId: string;
  tourRank: number;
  // The parameter ids the registered tour writes, served so the editor can
  // see a write row colliding with a tour on one axis. Empty when the tour
  // id is not registered this session.
  axisParamIds: string[];
}

export type MappingRow = ModulateRow | WriteRow | FireRow | TouchRow | TourRow;

type DistributiveOmit<T, K extends keyof never> = T extends unknown
  ? Omit<T, K>
  : never;

// What an edit or a learn arming sends up: a row without the served position,
// resolution and tour axes. For a learn slot the `source` (and a fire row's
// `ordinal`, a touch row's `baseNote`) is filled by the binding delivery.
export type MappingRowSpec = DistributiveOmit<
  MappingRow,
  "index" | "resolved" | "axisParamIds"
>;

export interface MappingEditResult {
  ok: boolean;
  error?: string;
}

export interface LearnState {
  armed: boolean;
  slot: MappingRowSpec | null;
}

export interface MatrixKeys {
  // The localStorage key the one user mapping persists under. Nim owns it.
  mapping: string;
}

// The connect affordance's state, named by Nim (midi_core.MidiState).
export type MidiState =
  | "Disconnected"
  | "Requesting"
  | "Connected"
  | "Unavailable";

export interface MidiPortEntry {
  id: string;
  name: string;
}

// Pushed once per frame while a capture chain is live and a subscriber is
// registered, and once on each state change otherwise. `onset` carries the
// event's energy in the frame it fires and is null in every other frame.
export interface AudioSample {
  state: ListenState;
  loudness: number;
  bass: number;
  mid: number;
  high: number;
  brightness: number;
  onset: number | null;
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
  isReady(): boolean;
  onReady(callback: () => void): void;

  descriptor(): ParamDescriptor[];
  getParam(id: string): number;
  setParam(id: string, value: number): void;
  commitParam(id: string): void;
  /** Drag-active signal for the spatial overlay. Nim owns the closed set of
   * spatial ids; a non-spatial id crosses and draws nothing. */
  dragOverlay(id: string, active: boolean): void;
  /** Help sections in display order: descriptor-group keys plus
   * "orientation" and "glossary", bodies in the restricted markdown subset. */
  help(): { key: string; body: string }[];
  // Bound a value against its descriptor without writing it, for controls that
  // own their own storage — the per-species grid writes cells of chemistry()
  // by reference and clamps them through here.
  clampParam(id: string, value: number): number;
  // The travel-curve pair: position in [0, 1] to lattice value and back.
  // Nim owns both directions; the panel computes no mapping.
  paramValueAt(id: string, position: number): number;
  paramPositionOf(id: string, value: number): number;

  getTrails(): boolean;
  setTrails(enabled: boolean): void;
  getBloom(): boolean;
  setBloom(enabled: boolean): void;
  // The camera's self-motion. Its speed is an ordinary descriptor; only the
  // toggle needs a pair of its own.
  getCameraDrift(): boolean;
  setCameraDrift(enabled: boolean): void;

  getForceModel(): number;
  setForceModel(model: number): void;

  paletteSchemes(): PaletteSchemeEntry[];
  getPaletteScheme(): string;
  isPaletteCustom(): boolean;
  setPaletteScheme(id: string): void;
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

  // Drifting force parameters ("force weather"). A second waypoint table on the
  // same tour, with its own switch and its own speed, so the two weathers run
  // independently.
  getForceWeather(): boolean;
  setForceWeather(enabled: boolean): void;
  // Asked for rather than listed, on the same terms climateParamIds is.
  forceWeatherParamIds(): string[];

  colormaps(): ColormapEntry[];
  getColormap(): number;
  setColormap(index: number): void;

  // Attraction matrix (live references; valid after onReady)
  matrix(): Float32Array;
  matrixCellColor(value: number): string;
  clampMatrixValue(value: number): number;
  /** The served band, step, and display precision, from the range
   * authority. The editor serves these and restates none of them. */
  matrixSpec(): { min: number; max: number; step: number; precision: number };
  matrixStride(): number;
  speciesColor(index: number): string;
  randomizeMatrix(): void;

  // Per-species field chemistry (live reference, same contract as matrix():
  // the frame loop copies the array into the SpeciesChemistry uniform every
  // frame, so a write lands on the next frame with no upload call). Which
  // columns exist comes from descriptor()'s per-species entries.
  chemistry(): Float32Array;
  chemistryStride(): number;

  resetParticles(): void;

  reseedField(): void;

  /** Light a body at a world point, with the shape and lifetime the bodies
   * sliders currently describe. False when every slot is taken. */
  igniteBody(x: number, y: number): boolean;

  onStats(callback: (stats: StatsSample) => void): void;

  // Audio. Start and stop are synchronous and return no promise: start leaves
  // the affordance Requesting before it returns and the outcome arrives on the
  // metering push; stop leaves it Disconnected before it returns. A subscribe
  // pushes the current state once and returns its unsubscribe.
  startListening(): void;
  stopListening(): void;
  onAudio(callback: (sample: AudioSample) => void): () => void;
  audioSources(): AudioSourceEntry[];
  /** Dormancy: id -> whether the control's consumer can act. Evaluated
   * Nim-side; called on the panel's own writes and on each stats push. */
  dormantParams(): Record<string, boolean>;

  // MIDI. Connect requests access only when called and leaves the affordance
  // Requesting before it returns; the outcome arrives through midiState() on
  // the next push. Disconnect leaves it Disconnected before it returns.
  connectMidi(): void;
  disconnectMidi(): void;
  midiState(): MidiState;
  midiPorts(): MidiPortEntry[];

  // Mappings (Nim owns the row model, validation, the document schema and the
  // shipped default; this UI owns localStorage under matrixKeys().mapping).
  mappingRows(): MappingRow[];
  // Every declared source of every registered family, in registration order.
  mappingSources(): SourceEntry[];
  // Every action id a fire row may name.
  mappingActions(): string[];
  defaultMappingRows(): MappingRowSpec[];
  // Each edit validates and answers a refusal without changing the mapping.
  setMappingRow(index: number, row: MappingRowSpec): MappingEditResult;
  addMappingRow(row: MappingRowSpec): MappingEditResult;
  removeMappingRow(index: number): MappingEditResult;
  setMappingRank(index: number, rank: number): MappingEditResult;
  // Learn stays armed until a qualifying source arrives or cancel is called.
  armLearn(slot: MappingRowSpec): void;
  cancelLearn(): void;
  learnState(): LearnState;
  // Pushed once on subscribe and again whenever the mapping changes: an edit,
  // an applied document, or a learn arming completing a row. Returns the
  // unsubscribe.
  onMapping(callback: (rows: MappingRow[]) => void): () => void;
  matrixKeys(): MatrixKeys;
  exportMappingJson(): string;
  // The same validate-first decode a load runs; a refused document leaves the
  // mapping as it was.
  applyMappingJson(json: string): MappingEditResult;

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
