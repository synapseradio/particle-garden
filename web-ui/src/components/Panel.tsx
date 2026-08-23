// The control panel: sections, control order and button rows. There is one
// world, so every control it offers is on screen at once, and a coupling that
// contributes nothing shows as a slider sitting at zero. Nim decides what a
// group contains; this file decides only where each group sits on screen. All
// state flows through the controller; no component touches gardenAPI numbers
// directly.
//
// tests/test_panel_reachability.nim reads this file and fails on any
// descriptor it places neither by id nor by group.

import { createSignal, For, onCleanup, Show } from "solid-js";
import type { PanelController } from "../state";
import { groupParamIds } from "../lib/param-groups";
import { Section } from "./Section";
import { HelpPanel } from "./HelpPanel";
import { ParamSlider } from "./ParamSlider";
import { MatrixEditor } from "./MatrixEditor";
import { RegimeSelector } from "./RegimeSelector";
import { ChemistryEditor } from "./ChemistryEditor";
import { PresetsSection } from "./PresetsSection";
import { StatsPanel } from "./StatsPanel";

// The camera is the one parameter something outside the panel writes on its
// own: the wheel zooms at the cursor and the zero key reframes the world, both
// from the Nim side, which has no way to push at the panel. Read once on mount
// and poll from there. Section unmounts its content while closed, so the timer
// lives exactly as long as the slider it feeds.
const CAMERA_POLL_MS = 250;

function CameraSection(props: { ctrl: PanelController }) {
  props.ctrl.syncParam("cameraZoom");
  const timer = setInterval(
    () => props.ctrl.syncParam("cameraZoom"),
    CAMERA_POLL_MS,
  );
  onCleanup(() => clearInterval(timer));
  return <ParamSlider ctrl={props.ctrl} id="cameraZoom" />;
}

export function Panel(props: { ctrl: PanelController }) {
  const ctrl = props.ctrl;
  const [collapsed, setCollapsed] = createSignal(false);
  const toggleCollapsed = () => setCollapsed(!collapsed());
  const [helpOpen, setHelpOpen] = createSignal(false);

  // "?" opens help from anywhere except a text edit in progress.
  const onKey = (event: KeyboardEvent) => {
    const tag = (event.target as HTMLElement | null)?.tagName;
    if (event.key === "?" && tag !== "INPUT" && tag !== "TEXTAREA") {
      setHelpOpen(true);
    }
  };
  document.addEventListener("keydown", onKey);
  onCleanup(() => document.removeEventListener("keydown", onKey));

  const groupIds = (group: string) => groupParamIds(ctrl.descriptors, group);

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
        <button
          class="collapse-btn help-btn"
          title="Help (?)"
          onClick={() => setHelpOpen(true)}
        >
          ?
        </button>
      </h1>
      <HelpPanel ctrl={ctrl} open={helpOpen()} onClose={() => setHelpOpen(false)} />

      <div class="controls-content">
        <For
          each={[
            "particleCount",
            "speciesCount",
            "interactionRadius",
            "forceStrength",
            "crowdingStrength",
            "friction",
            "timeScale",
            "ruleWildness",
          ]}
        >
          {(id) => <ParamSlider ctrl={ctrl} id={id} />}
        </For>

        {/* The force weather sits under the sliders it moves, so someone
            watching strength, radius and friction wander can see what is
            moving them without hunting for it. */}
        <div class="control-group">
          <label class="toggle-label">
            <input
              type="checkbox"
              checked={ctrl.forceWeather()}
              onChange={(event) =>
                ctrl.setForceWeather(event.currentTarget.checked)
              }
            />
            Force Weather
            <span class="param-hint">
              {" "}
              — the forces tour their waypoints on their own
            </span>
          </label>
        </div>
        <Show when={ctrl.forceWeather()}>
          <ParamSlider ctrl={ctrl} id="forceWeatherSpeed" />
        </Show>

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

        {/* Last of the view controls, before the physics ones start. The
            notches are the point: they name the three scales worth stopping
            at, which a wheel gesture cannot offer. */}
        <Section title="Camera">
          <CameraSection ctrl={ctrl} />
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

        {/* Fluid strength leads its own group, so the knob that decides whether
            this world has a fluid at all sits above the knobs that shape it. */}
        <Section title="SPH Fluid">
          <For each={groupIds("fluid")}>
            {(id) => <ParamSlider ctrl={ctrl} id={id} />}
          </For>
        </Section>

        <Section title="Reaction-Diffusion">
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

        <MatrixEditor ctrl={ctrl} />

        {/* Beside the attraction matrix: what a species secretes into the field
            and how hard the field steers it back are the same kind of per-species
            number the matrix holds. The group comes from the one descriptor
            table, so these columns are placed the way every other control is. */}
        <ChemistryEditor ctrl={ctrl} ids={groupIds("chemistry")} />

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
