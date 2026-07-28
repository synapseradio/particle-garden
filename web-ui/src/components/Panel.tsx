// The control panel: sections, control order and button rows as the old
// index.html panel laid them out, narrowed to the controls the active
// simulation mode uses. Nim decides which group belongs to which mode and
// what a group contains; this file decides only where each group sits on
// screen. All state flows through the controller; no component touches
// gardenAPI numbers directly.

import { createEffect, createSignal, For, onCleanup, Show } from "solid-js";
import type { PanelController } from "../state";
import {
  filterVisibleIds,
  groupParamIds,
  isGroupVisible,
  isModeExclusiveGroup,
} from "../lib/mode-gating";
import { Section } from "./Section";
import { ParamSlider } from "./ParamSlider";
import { MatrixEditor } from "./MatrixEditor";
import { RegimeSelector } from "./RegimeSelector";
import { ChemistryEditor } from "./ChemistryEditor";
import { PresetsSection } from "./PresetsSection";
import { StatsPanel } from "./StatsPanel";

export function Panel(props: { ctrl: PanelController }) {
  const ctrl = props.ctrl;
  const [collapsed, setCollapsed] = createSignal(false);
  const toggleCollapsed = () => setCollapsed(!collapsed());

  // The drifting climate moves feed and kill from the frame loop, which has no
  // way to push at the panel. Poll while it is on, and only while it is on —
  // an always-running timer would re-read every frame's worth of state for a
  // feature that is off by default. Four reads a second is enough for a slider
  // to look like it is moving without the panel doing work between them.
  createEffect(() => {
    if (!ctrl.climateDrift()) return;
    const timer = setInterval(() => ctrl.syncDriftingParams(), 250);
    onCleanup(() => clearInterval(timer));
  });

  // Mode gating. Solid's JSX transform reads each/when through getters, so
  // every call below re-runs on a mode switch with no further plumbing.
  const shows = (group: string) =>
    isGroupVisible(ctrl.api.simModes(), ctrl.simMode(), group);
  const opensFor = (group: string) =>
    isModeExclusiveGroup(ctrl.api.simModes(), ctrl.simMode(), group);
  // Empty when the group is hidden, so slider lists need no <Show> of their own.
  const groupIds = (group: string) =>
    shows(group) ? groupParamIds(ctrl.descriptors, group) : [];
  const visible = (ids: string[]) =>
    filterVisibleIds(ctrl.descriptors, ctrl.api.simModes(), ctrl.simMode(), ids);

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
          each={visible([
            "particleCount",
            "speciesCount",
            "interactionRadius",
            "forceStrength",
            "friction",
            "timeScale",
            "ruleTemperature",
          ])}
        >
          {(id) => <ParamSlider ctrl={ctrl} id={id} />}
        </For>

        <div class="button-row">
          <Show when={shows("matrix")}>
            <button onClick={() => ctrl.randomizeMatrix()}>🎲 New Rules</button>
          </Show>
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

        <Show when={shows("force-model")}>
          <Section title="Force Model" defaultOpen={opensFor("force-model")}>
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
        </Show>

        <Show when={shows("sph")}>
          <Section title="SPH Fluid" defaultOpen={opensFor("sph")}>
            <For each={groupIds("sph")}>
              {(id) => <ParamSlider ctrl={ctrl} id={id} />}
            </For>
          </Section>
        </Show>

        <Show when={shows("rd")}>
          <Section title="Reaction-Diffusion" defaultOpen={opensFor("rd")}>
            {/* Regimes first: they are how someone who does not know the
                literature finds the living settings, and the sliders below
                read as adjustments to a named starting point rather than as
                bare numbers over a mostly-dead plane. */}
            <RegimeSelector ctrl={ctrl} />
            <div class="control-group">
              <label class="toggle-label">
                <input
                  type="checkbox"
                  checked={ctrl.climateDrift()}
                  onChange={(event) =>
                    ctrl.setClimateDrift(event.currentTarget.checked)
                  }
                />
                Weather
                <span class="param-hint">
                  {" "}
                  — the climate tours the regimes on its own
                </span>
              </label>
            </div>
            <For each={groupIds("rd")}>
              {(id) => <ParamSlider ctrl={ctrl} id={id} />}
            </For>
            <div class="control-group">
              <label>Field Colormap</label>
              <div class="model-selector">
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
            </div>
            <For each={groupIds("rd-field")}>
              {(id) => <ParamSlider ctrl={ctrl} id={id} />}
            </For>
            <div class="control-group model-selector">
              {/* A deliberate action, never automatic: the field otherwise
                  only ever lights where colonies deposit. */}
              <button
                class="model-btn"
                onClick={() => ctrl.api.reseedField?.()}
                title="Scatter a pattern across the field by hand, instead of waiting for colonies to grow one"
              >
                ✦ Scatter Spores
              </button>
            </div>
          </Section>
        </Show>

        <Show when={shows("matrix")}>
          <MatrixEditor ctrl={ctrl} />
        </Show>

        {/* Beside the attraction matrix, and gated on the same group the rest
            of the field controls use: chemistry only means something where a
            field exists for a species to secrete into. */}
        <Show when={shows("rd")}>
          <ChemistryEditor ctrl={ctrl} />
        </Show>

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
