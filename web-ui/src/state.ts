// Panel controller: Solid signals mirroring the Nim-side state, with every
// mutation routed through gardenAPI and read straight back. Reads-after-
// writes (rather than trusting the value we sent) keep the UI honest about
// Nim-side clamping — descriptor bounds, mode particle ceilings, preset
// validation all happen on the other side of the boundary.

import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";
import type { GardenAPI, StatsSample } from "./garden-api";

// The two coordinates a Gray-Scott regime is. A drag on either lands the pair
// on a regime or off it, and the drifting climate walks the pair from the frame
// loop, so both paths re-read the same two ids. Nim decides which regime a pair
// sits in (getRdRegime) and how the climate moves it (climate_core).
const REGIME_COORDINATE_IDS: readonly string[] = ["rdFeed", "rdKill"];

export function createPanelController(api: GardenAPI) {
  const descriptors = api.descriptor();
  const byId = new Map(descriptors.map((entry) => [entry.id, entry]));

  const initialParams: Record<string, number> = {};
  for (const entry of descriptors) initialParams[entry.id] = api.getParam(entry.id);
  const [params, setParams] = createStore(initialParams);

  const [trails, setTrailsSignal] = createSignal(api.getTrails());
  const [bloom, setBloomSignal] = createSignal(api.getBloom());
  const [forceModel, setForceModelSignal] = createSignal(api.getForceModel());
  const [simMode, setSimModeSignal] = createSignal(api.getSimMode());
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
  const [matrixVersion, setMatrixVersion] = createSignal(0);
  const [chemistryVersion, setChemistryVersion] = createSignal(0);
  const [ready, setReady] = createSignal(api.isReady());
  const [stats, setStats] = createSignal<StatsSample | null>(null);

  const bumpMatrix = () => setMatrixVersion((version) => version + 1);
  const bumpChemistry = () => setChemistryVersion((version) => version + 1);

  // Re-read every descriptor from Nim. The panel's values are whatever the
  // simulation says they are, so anything that can move several of them at once
  // ends by asking rather than by tracking which ones moved.
  const syncParams = () => {
    for (const entry of descriptors) setParams(entry.id, api.getParam(entry.id));
  };

  const syncAll = () => {
    syncParams();
    setTrailsSignal(api.getTrails());
    setBloomSignal(api.getBloom());
    setForceModelSignal(api.getForceModel());
    setSimModeSignal(api.getSimMode());
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
    api.onStats(setStats);
    // Pick up whatever init applied after module eval: ?n=/?mode=/?bloom=
    // overrides, the randomized matrix, mode particle ceilings.
    syncAll();
  });

  return {
    api,
    descriptors,
    byId,
    params,
    trails,
    bloom,
    forceModel,
    simMode,
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

    setParam(id: string, raw: number) {
      api.setParam(id, raw);
      setParams(id, api.getParam(id));
      // Feed and kill decide which regime is lit; a drag off a regime's
      // coordinates unlights it, and onto them lights it.
      if (REGIME_COORDINATE_IDS.includes(id)) {
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
    setSimMode(id: string) {
      api.setSimMode(id);
      // Entering SPH/RD clamps particleCount through the same update path
      // the slider uses; re-read the lot.
      syncAll();
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
    // The drifting climate moves feed and kill from the frame loop, so the
    // panel has to re-read them; nothing pushes at it. Called on a timer only
    // while drift is on.
    syncDriftingParams() {
      for (const id of REGIME_COORDINATE_IDS) setParams(id, api.getParam(id));
      setRdRegimeSignal(api.getRdRegime());
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
