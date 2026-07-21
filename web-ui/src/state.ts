// Panel controller: Solid signals mirroring the Nim-side state, with every
// mutation routed through gardenAPI and read straight back. Reads-after-
// writes (rather than trusting the value we sent) keep the UI honest about
// Nim-side clamping — descriptor bounds, mode particle ceilings, preset
// validation all happen on the other side of the boundary.

import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";
import type { GardenAPI, StatsSample } from "./garden-api";

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
  const [paletteScheme, setPaletteSchemeSignal] = createSignal(
    api.getPaletteScheme(),
  );
  const [paletteCustom, setPaletteCustomSignal] = createSignal(
    api.isPaletteCustom(),
  );
  const [matrixVersion, setMatrixVersion] = createSignal(0);
  const [ready, setReady] = createSignal(api.isReady());
  const [stats, setStats] = createSignal<StatsSample | null>(null);

  const bumpMatrix = () => setMatrixVersion((version) => version + 1);

  const syncAll = () => {
    for (const entry of descriptors) setParams(entry.id, api.getParam(entry.id));
    setTrailsSignal(api.getTrails());
    setBloomSignal(api.getBloom());
    setForceModelSignal(api.getForceModel());
    setSimModeSignal(api.getSimMode());
    setColormapSignal(api.getColormap());
    setPaletteSchemeSignal(api.getPaletteScheme());
    setPaletteCustomSignal(api.isPaletteCustom());
    bumpMatrix();
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
    paletteScheme,
    paletteCustom,
    matrixVersion,
    ready,
    stats,
    bumpMatrix,
    syncAll,

    setParam(id: string, raw: number) {
      api.setParam(id, raw);
      setParams(id, api.getParam(id));
      if (byId.get(id)?.store === "palette") {
        // Palette knobs regenerate COLORS; the matrix legend reads them.
        setPaletteCustomSignal(api.isPaletteCustom());
        bumpMatrix();
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
    setColormap(index: number) {
      api.setColormap(index);
      setColormapSignal(api.getColormap());
    },
    setPaletteScheme(id: string) {
      api.setPaletteScheme(id);
      setPaletteSchemeSignal(api.getPaletteScheme());
      setPaletteCustomSignal(api.isPaletteCustom());
      bumpMatrix();
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
