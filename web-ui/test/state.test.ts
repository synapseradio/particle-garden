import { describe, expect, test } from "bun:test";
import { createPanelController } from "../src/state";
import type {
  GardenAPI,
  ParamDescriptor,
  StatsSample,
} from "../src/garden-api";

// The climate's written parameters, as this fixture names them. Deliberately
// NOT rdFeed and rdKill: a controller holding its own copy of the shipped ids
// would satisfy a test written against those while ignoring what Nim served,
// which is the drift these tests exist to catch.
const CLIMATE_IDS = ["windSpeed", "windAngle"];
const OTHER_ID = "friction";

function descriptorFor(id: string): ParamDescriptor {
  return {
    id,
    label: id,
    group: "rd",
    arity: "scalar",
    kind: "float",
    min: 0,
    max: 1,
    step: 0.001,
    precision: 3,
    curve: "linear",
    curveExponent: 0,
    positionStep: 0.001,
    horizon: "instant",
    horizonReview: false,
    dormantWhen: "",
    dormantLine: "",
    defaultValue: 0,
    store: "sim",
    reinitOnCommit: false,
    hint: "",
    notches: [],
    bound: { kind: "constant" },
  };
}

function statsSample(
  params: Record<string, number>,
  ceilings: Record<string, number> = {},
): StatsSample {
  return {
    fps: 60,
    particleCount: 1000,
    gridTimeMs: 0,
    workerTimeMs: 0,
    gpuGridMs: 0,
    gpuPhysicsMs: 0,
    gpuDrawMs: 0,
    gpuPresentMs: 0,
    gpuFieldMs: 0,
    fieldAliveCells: 0,
    params,
    ceilings,
  };
}

/** A gardenAPI standing in for the Nim side, recording what the panel asked. */
function fakeGarden() {
  const values: Record<string, number> = {
    windSpeed: 0.1,
    windAngle: 0.2,
    [OTHER_ID]: 0.5,
  };
  const listeners: ((sample: StatsSample) => void)[] = [];
  let regime = "coral";
  let regimeReads = 0;

  const api = {
    isReady: () => true,
    onReady: (callback: () => void) => callback(),
    descriptor: () =>
      [...CLIMATE_IDS, OTHER_ID].map(descriptorFor),
    getParam: (id: string) => values[id] ?? 0,
    setParam: (id: string, value: number) => {
      values[id] = value;
    },
    commitParam: () => {},
    dragOverlay: () => {},
    getTrails: () => false,
    setTrails: () => {},
    getBloom: () => false,
    setBloom: () => {},
    getForceModel: () => 0,
    setForceModel: () => {},
    paletteSchemes: () => [],
    getPaletteScheme: () => "spectrum",
    isPaletteCustom: () => false,
    setPaletteScheme: () => {},
    rdRegimes: () => [],
    getRdRegime: () => {
      regimeReads += 1;
      return regime;
    },
    applyRdRegime: () => {},
    getClimateDrift: () => true,
    setClimateDrift: () => {},
    climateParamIds: () => CLIMATE_IDS,
    colormaps: () => [],
    getColormap: () => 0,
    setColormap: () => {},
    matrix: () => new Float32Array(0),
    matrixCellColor: () => "#000",
    clampMatrixValue: (value: number) => value,
    matrixStride: () => 0,
    speciesColor: () => "#000",
    randomizeMatrix: () => {},
    chemistry: () => new Float32Array(0),
    chemistryStride: () => 0,
    chemistryFields: () => [],
    clampChemistry: (_id: string, value: number) => value,
    resetParticles: () => {},
    reseedField: () => {},
    onStats: (callback: (sample: StatsSample) => void) => {
      listeners.push(callback);
    },
    dormantParams: () => ({}),
    presetKeys: () => ({ prefix: "", indexKey: "", defaultName: "" }),
    normalizePresetName: (raw: string) => raw,
    exportPresetJson: () => "{}",
    exportPresetJsonPretty: () => "{}",
    applyPresetJson: () => ({ ok: true }),
    builtinPresets: () => [],
  } as unknown as GardenAPI;

  return {
    api,
    values,
    push: (
      params: Record<string, number>,
      ceilings: Record<string, number> = {},
    ) => {
      for (const listener of listeners) listener(statsSample(params, ceilings));
    },
    listenerCount: () => listeners.length,
    setRegime: (next: string) => {
      regime = next;
    },
    regimeReads: () => regimeReads,
  };
}

describe("the panel takes the climate's writes as a push", () => {
  test("it reads back exactly the ids gardenAPI says the climate writes", () => {
    // THE DEFECT THIS PINS. The frame loop moves these parameters and the panel
    // has to report them. Naming them on the TypeScript side means a third axis
    // moves the simulation while the panel keeps showing two — nothing breaks,
    // the readout just stops being true.
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    garden.push({ windSpeed: 0.42, windAngle: 0.77 });

    expect(ctrl.params["windSpeed"]).toBe(0.42);
    expect(ctrl.params["windAngle"]).toBe(0.77);
  });

  test("it subscribes to the stats channel rather than starting a timer", () => {
    // Push, not poll: one subscription on the channel that already exists, and
    // no interval of the panel's own. syncDriftingParams was that timer's
    // callback, so its absence is what proves the timer is gone.
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    expect(garden.listenerCount()).toBe(1);
    expect(
      (ctrl as unknown as Record<string, unknown>)["syncDriftingParams"],
    ).toBeUndefined();
  });

  test("a pushed move re-reads which regime is lit", () => {
    // The climate tours the regime coordinates, so drifting off a regime has to
    // unlight its button. The panel cannot know that from the value alone; it
    // asks Nim, which owns the comparison.
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);
    garden.setRegime("mitosis");

    garden.push({ windSpeed: 0.42, windAngle: 0.77 });

    expect(ctrl.rdRegime()).toBe("mitosis");
  });

  test("a push that moves nothing leaves the regime alone", () => {
    // Stats arrive on their own cadence whether or not the weather is on. A
    // push carrying the values the panel already holds must cost no work.
    const garden = fakeGarden();
    createPanelController(garden.api);
    const before = garden.regimeReads();

    garden.push({ windSpeed: 0.1, windAngle: 0.2 });

    expect(garden.regimeReads()).toBe(before);
  });

  test("the stats sample itself still reaches the panel", () => {
    // The channel carries both. Folding the parameter values into it must not
    // cost the readout it was already serving.
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    garden.push({ windSpeed: 0.42, windAngle: 0.77 });

    expect(ctrl.stats()?.fps).toBe(60);
  });
});

describe("a derived bound's ceiling rides the same push", () => {
  test("the panel holds no ceiling until one is pushed", () => {
    // No ceiling reported is not a ceiling of zero. A slider asked to draw
    // itself before the first sample must show its whole track live.
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    expect(ctrl.ceilings["windSpeed"]).toBeUndefined();
  });

  test("a pushed ceiling reaches the panel by parameter id", () => {
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    garden.push({ windSpeed: 0.1, windAngle: 0.2 }, { windSpeed: 0.3 });

    expect(ctrl.ceilings["windSpeed"]).toBe(0.3);
  });

  test("a ceiling moves on its own, without the panel having written anything", () => {
    // The point of pushing it: the parameters a ceiling reads can move from
    // anywhere — another slider, a preset, the weather — so the panel is told
    // rather than asked to work out when to ask.
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    garden.push({ windSpeed: 0.1, windAngle: 0.2 }, { windSpeed: 0.3 });
    garden.push({ windSpeed: 0.1, windAngle: 0.2 }, { windSpeed: 0.9 });

    expect(ctrl.ceilings["windSpeed"]).toBe(0.9);
  });

  test("a sample carrying no ceilings leaves the ones already held alone", () => {
    const garden = fakeGarden();
    const ctrl = createPanelController(garden.api);

    garden.push({ windSpeed: 0.1, windAngle: 0.2 }, { windSpeed: 0.3 });
    garden.push({ windSpeed: 0.1, windAngle: 0.2 });

    expect(ctrl.ceilings["windSpeed"]).toBe(0.3);
  });
});
