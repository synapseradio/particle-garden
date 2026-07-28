// The named-regime row: six buttons that set feed and kill together, because
// a regime is a POINT in that plane and a notch on either axis alone does not
// locate one.
//
// Everything here comes from Nim: the names, the coordinates, and the deposit
// floor two of them need. The button only sends an id.
//
// A row of plain buttons rather than a dropdown or a 2D pad — six entries is
// few enough that all of them fit in view, and seeing the whole set at once is
// most of the point. A user who does not know the literature should be able to
// read the available worlds off the panel rather than discover them one at a
// time behind a control.

import { For, Show } from "solid-js";
import type { PanelController } from "../state";

export function RegimeSelector(props: { ctrl: PanelController }) {
  const regimes = props.ctrl.api.rdRegimes?.() ?? [];
  if (regimes.length === 0) return null;

  return (
    <div class="control-group">
      <label>
        Regimes
        <span class="param-hint">
          {" "}
          — named settings that produce something; the sliders stay free
          between them
        </span>
      </label>
      <div class="model-selector regime-row">
        <For each={regimes}>
          {(regime) => (
            <button
              class="model-btn"
              classList={{ active: props.ctrl.rdRegime() === regime.id }}
              title={`feed ${regime.feed}, kill ${regime.kill}${
                regime.minDeposit > 0
                  ? ` — needs Secretion at least ${regime.minDeposit} to appear at all`
                  : ""
              }`}
              onClick={() => props.ctrl.applyRdRegime(regime.id)}
            >
              {regime.label}
            </button>
          )}
        </For>
      </div>
      <Show when={props.ctrl.rdRegime() === ""}>
        <div class="regime-note">Between regimes</div>
      </Show>
    </div>
  );
}
