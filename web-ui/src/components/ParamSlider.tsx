// One range slider bound to a descriptor: min/max/step come from the Nim
// side, input events write through setParam (clamped, synchronous mirror),
// release fires commitParam (the old "change" event's side effects).

import { Show } from "solid-js";
import type { PanelController } from "../state";
import { formatParamValue } from "../lib/format";

export function ParamSlider(props: {
  ctrl: PanelController;
  id: string;
  hint?: string;
}) {
  const descriptor = props.ctrl.byId.get(props.id);
  if (!descriptor) return null;
  const value = () => props.ctrl.params[props.id] ?? descriptor.defaultValue;
  return (
    <div class="control-group">
      <label>
        {descriptor.label}
        <Show when={props.hint}>
          <span class="param-hint"> — {props.hint}</span>
        </Show>
        <span class="value-display">
          {formatParamValue(value(), descriptor.kind, descriptor.precision)}
        </span>
      </label>
      <input
        type="range"
        min={descriptor.min}
        max={descriptor.max}
        step={descriptor.step}
        value={value()}
        onInput={(event) =>
          props.ctrl.setParam(props.id, parseFloat(event.currentTarget.value))
        }
        onChange={() => props.ctrl.commitParam(props.id)}
      />
    </div>
  );
}
