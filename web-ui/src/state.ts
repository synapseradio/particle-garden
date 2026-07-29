// Panel controller: Solid signals mirroring the Nim-side state, with every
// mutation routed through gardenAPI and read straight back. Reads-after-
// writes (rather than trusting the value we sent) keep the UI honest about
// Nim-side clamping — descriptor bounds and preset validation both happen on
// the other side of the boundary.

import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";
import type { GardenAPI, StatsSample } from "./garden-api";
import { scalarParamIds } from "./lib/param-groups";

export function createPanelController(api: GardenAPI) {
  const descriptors = api.descriptor();
  const byId = new Map(descriptors.map((entry) => [entry.id, entry]));
  // This store mirrors one number per id, which is what a scalar descriptor
  // is. The per-species columns hold one value per species in the live array
  // chemistry() returns, and ChemistryEditor reads that array directly.
  const scalarIds = scalarParamIds(descriptors);

  // The parameters the weather walks, asked for rather than listed. They are
  // also the coordinates a Gray-Scott regime is, because the climate tours the
  // named regimes — so a drag onto them lights a button for the same reason a
  // drift off them unlights one. Nim owns both facts: which ids the climate
  // writes (climate_core) and which regime a point sits in (getRdRegime).
  const climateParamIds = api.climateParamIds();

  const initialParams: Record<string, number> = {};
  for (const id of scalarIds) initialParams[id] = api.getParam(id);
  const [params, setParams] = createStore(initialParams);

  const [trails, setTrailsSignal] = createSignal(api.getTrails());
  const [bloom, setBloomSignal] = createSignal(api.getBloom());
  const [forceModel, setForceModelSignal] = createSignal(api.getForceModel());
  const [colormap, setColormapSignal] = createSignal(api.getColormap());
  const [rdRegime, setRdRegimeSignal] = createSignal(api.getRdRegime());
  const [climateDrift, setClimateDriftSignal] = createSignal(
    api.getClimateDrift(),
  );
  const [paletteScheme, setPaletteSchemeSignal] = createSignal(
    api.getPaletteScheme(),
  );
  const [paletteCustom, setPaletteCustomSignal] = createSignal(
    api.isPaletteCustom(),
  );
  // The live ceiling of each derived bound, by id. Empty until the first stats
  // sample arrives, which reads as "no ceiling reported" rather than as a
  // ceiling of zero — a slider draws its whole track live until told otherwise.
  const [ceilings, setCeilings] = createStore<Record<string, number>>({});
  const [matrixVersion, setMatrixVersion] = createSignal(0);
  const [chemistryVersion, setChemistryVersion] = createSignal(0);
  const [ready, setReady] = createSignal(api.isReady());
  const [stats, setStats] = createSignal<StatsSample | null>(null);

  const bumpMatrix = () => setMatrixVersion((version) => version + 1);
  const bumpChemistry = () => setChemistryVersion((version) => version + 1);

  // Re-read one descriptor from Nim. Every path that moves a parameter goes
  // through here, including the ones outside the panel: the wheel on the
  // canvas, and the frame loop's drifting climate.
  const syncParam = (id: string) => setParams(id, api.getParam(id));

  // Re-read every descriptor from Nim. The panel's values are whatever the
  // simulation says they are, so anything that can move several of them at once
  // ends by asking rather than by tracking which ones moved.
  const syncParams = () => {
    for (const id of scalarIds) syncParam(id);
  };

  const syncAll = () => {
    syncParams();
    setTrailsSignal(api.getTrails());
    setBloomSignal(api.getBloom());
    setForceModelSignal(api.getForceModel());
    setColormapSignal(api.getColormap());
    setRdRegimeSignal(api.getRdRegime());
    setClimateDriftSignal(api.getClimateDrift());
    setPaletteSchemeSignal(api.getPaletteScheme());
    setPaletteCustomSignal(api.isPaletteCustom());
    bumpMatrix();
    bumpChemistry();
  };

  api.onReady(() => {
    setReady(true);
    api.onStats((sample) => {
      setStats(sample);
      // Parameters the simulation moved on its own arrive with the sample; the
      // panel is told rather than polling for them. Applied by comparison so a
      // sample that moved nothing — the usual case, since drift is off by
      // default — costs no store write and no regime lookup.
      let moved = false;
      for (const [id, value] of Object.entries(sample.params)) {
        if (params[id] !== value) {
          setParams(id, value);
          moved = true;
        }
      }
      // A derived bound's ceiling moves when the parameters it reads move, and
      // those need not be ones this panel wrote. Applied by comparison for the
      // same reason as the values above: a sample that moved nothing costs no
      // store write.
      for (const [id, value] of Object.entries(sample.ceilings ?? {})) {
        if (ceilings[id] !== value) setCeilings(id, value);
      }
      // The climate walks the regime coordinates, so a drift can light or
      // unlight a button. Nim owns the comparison.
      if (moved) setRdRegimeSignal(api.getRdRegime());
    });
    // Pick up whatever init applied after module eval: the URL overrides and
    // the randomized matrix.
    syncAll();
  });

  return {
    api,
    descriptors,
    byId,
    params,
    ceilings,
    trails,
    bloom,
    forceModel,
    colormap,
    rdRegime,
    climateDrift,
    paletteScheme,
    paletteCustom,
    matrixVersion,
    chemistryVersion,
    ready,
    stats,
    bumpMatrix,
    bumpChemistry,
    syncAll,
    syncParam,

    setParam(id: string, raw: number) {
      api.setParam(id, raw);
      syncParam(id);
      // These coordinates decide which regime is lit; a drag off a regime's
      // point unlights it, and onto it lights it.
      if (climateParamIds.includes(id)) {
        setRdRegimeSignal(api.getRdRegime());
      }
      if (byId.get(id)?.store === "palette") {
        // Palette knobs regenerate COLORS; the matrix and chemistry legends
        // both read them.
        setPaletteCustomSignal(api.isPaletteCustom());
        bumpMatrix();
        bumpChemistry();
      }
    },
    commitParam(id: string) {
      api.commitParam(id);
      // Count commits cascade (species resize randomizes matrix cells,
      // particle re-init); re-read everything rather than guessing.
      if (byId.get(id)?.reinitOnCommit) syncAll();
    },
    setTrails(enabled: boolean) {
      api.setTrails(enabled);
      setTrailsSignal(api.getTrails());
    },
    setBloom(enabled: boolean) {
      api.setBloom(enabled);
      setBloomSignal(api.getBloom());
    },
    setForceModel(model: number) {
      api.setForceModel(model);
      setForceModelSignal(api.getForceModel());
    },
    applyRdRegime(id: string) {
      api.applyRdRegime(id);
      // A regime sets feed and kill, and may raise the deposit floor — read
      // the lot back rather than assuming which of them moved.
      syncParams();
      setRdRegimeSignal(api.getRdRegime());
    },
    setClimateDrift(enabled: boolean) {
      api.setClimateDrift(enabled);
      setClimateDriftSignal(api.getClimateDrift());
    },
    setColormap(index: number) {
      api.setColormap(index);
      setColormapSignal(api.getColormap());
    },
    setPaletteScheme(id: string) {
      api.setPaletteScheme(id);
      setPaletteSchemeSignal(api.getPaletteScheme());
      setPaletteCustomSignal(api.isPaletteCustom());
      bumpMatrix();
      bumpChemistry();
    },
    randomizeMatrix() {
      api.randomizeMatrix();
      bumpMatrix();
    },
    resetParticles() {
      api.resetParticles();
    },
    applyPresetJson(json: string) {
      const result = api.applyPresetJson(json);
      if (result.ok) syncAll();
      return result;
    },
  };
}

export type PanelController = ReturnType<typeof createPanelController>;
