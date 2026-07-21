// The control panel, laid out 1:1 with the old index.html panel: same
// control order, same sections, same button rows. All state flows through
// the controller; no component touches gardenAPI numbers directly.

import { createSignal, For, Show } from "solid-js";
import type { PanelController } from "../state";
import { Section } from "./Section";
import { ParamSlider } from "./ParamSlider";
import { MatrixEditor } from "./MatrixEditor";
import { PresetsSection } from "./PresetsSection";
import { StatsPanel } from "./StatsPanel";

// Pearson regime hints, verbatim from the old panel's RD labels.
const RD_HINTS: Record<string, string> = {
  rdFeed: "spots .025-.034, stripes .046-.058, movers ~.06",
  rdKill: "spots .061-.065, stripes .063-.065, movers ~.0609",
};

export function Panel(props: { ctrl: PanelController }) {
  const ctrl = props.ctrl;
  const [collapsed, setCollapsed] = createSignal(false);
  const toggleCollapsed = () => setCollapsed(!collapsed());

  const groupIds = (group: string) =>
    ctrl.descriptors
      .filter((entry) => entry.group === group)
      .map((entry) => entry.id);

  return (
    <div class="controls" classList={{ collapsed: collapsed() }}>
      <button class="collapse-btn" onClick={toggleCollapsed}>
        {collapsed() ? "+" : "−"}
      </button>
      <h1>
        •🧬•
        <button class="collapse-btn" onClick={toggleCollapsed}>
          🦠
        </button>
      </h1>

      <div class="controls-content">
        {/* Simulation mode selector */}
        <div class="control-group model-selector">
          <For each={ctrl.api.simModes()}>
            {(mode) => (
              <button
                class="model-btn"
                classList={{ active: ctrl.simMode() === mode.id }}
                onClick={() => ctrl.setSimMode(mode.id)}
              >
                {mode.label}
              </button>
            )}
          </For>
        </div>

        {/* Main simulation sliders */}
        <For
          each={[
            "particleCount",
            "speciesCount",
            "interactionRadius",
            "forceStrength",
            "friction",
            "timeScale",
            "ruleTemperature",
          ]}
        >
          {(id) => <ParamSlider ctrl={ctrl} id={id} />}
        </For>

        <div class="button-row">
          <button onClick={() => ctrl.randomizeMatrix()}>🎲 New Rules</button>
          <button onClick={() => ctrl.resetParticles()}>↺ Reset</button>
          <button
            class="secondary"
            classList={{ active: ctrl.trails() }}
            onClick={() => ctrl.setTrails(!ctrl.trails())}
          >
            Trails
          </button>
        </div>

        <Show when={ctrl.trails()}>
          <div class="trail-settings">
            <ParamSlider ctrl={ctrl} id="trailLength" />
          </div>
        </Show>

        <ParamSlider ctrl={ctrl} id="particleSize" />

        <Section title="Glow">
          <For each={groupIds("glow")}>
            {(id) => <ParamSlider ctrl={ctrl} id={id} />}
          </For>
        </Section>

        <Section title="Bloom & Grade">
          <div class="control-group">
            <button
              class="secondary"
              classList={{ active: ctrl.bloom() }}
              onClick={() => ctrl.setBloom(!ctrl.bloom())}
            >
              Bloom
            </button>
          </div>
          <For each={groupIds("bloom")}>
            {(id) => <ParamSlider ctrl={ctrl} id={id} />}
          </For>
        </Section>

        <ParamSlider ctrl={ctrl} id="maxVelocity" />

        <Section title="Force Model">
          <div class="control-group model-selector">
            <button
              class="model-btn"
              classList={{ active: ctrl.forceModel() === 0 }}
              onClick={() => ctrl.setForceModel(0)}
            >
              Polynomial
            </button>
            <button
              class="model-btn"
              classList={{ active: ctrl.forceModel() === 1 }}
              onClick={() => ctrl.setForceModel(1)}
            >
              Exponential
            </button>
          </div>
          <Show when={ctrl.forceModel() === 0}>
            <For each={groupIds("force-polynomial")}>
              {(id) => <ParamSlider ctrl={ctrl} id={id} />}
            </For>
          </Show>
          <Show when={ctrl.forceModel() === 1}>
            <For each={groupIds("force-exponential")}>
              {(id) => <ParamSlider ctrl={ctrl} id={id} />}
            </For>
          </Show>
        </Section>

        <Section title="SPH Fluid">
          <For each={groupIds("sph")}>
            {(id) => <ParamSlider ctrl={ctrl} id={id} />}
          </For>
        </Section>

        <Section title="Reaction-Diffusion">
          <ParamSlider ctrl={ctrl} id="rdFeed" hint={RD_HINTS["rdFeed"]} />
          <ParamSlider ctrl={ctrl} id="rdKill" hint={RD_HINTS["rdKill"]} />
          <div class="control-group model-selector">
            <For each={ctrl.api.colormaps()}>
              {(entry) => (
                <button
                  class="model-btn"
                  classList={{ active: ctrl.colormap() === entry.index }}
                  onClick={() => ctrl.setColormap(entry.index)}
                >
                  {entry.label}
                </button>
              )}
            </For>
          </div>
          <ParamSlider ctrl={ctrl} id="fieldOpacity" />
        </Section>

        <MatrixEditor ctrl={ctrl} />

        <Section title="Palette">
          <div class="control-group model-selector">
            <For each={ctrl.api.paletteSchemes()}>
              {(scheme) => (
                <button
                  class="model-btn"
                  classList={{
                    active:
                      !ctrl.paletteCustom() &&
                      ctrl.paletteScheme() === scheme.id,
                  }}
                  onClick={() => ctrl.setPaletteScheme(scheme.id)}
                >
                  {scheme.label}
                </button>
              )}
            </For>
          </div>
          <For each={groupIds("palette")}>
            {(id) => <ParamSlider ctrl={ctrl} id={id} />}
          </For>
        </Section>

        <Section title="Presets">
          <PresetsSection ctrl={ctrl} />
        </Section>

        <StatsPanel ctrl={ctrl} />
      </div>
    </div>
  );
}
