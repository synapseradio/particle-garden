// One range slider bound to a descriptor: min/max/step, label, hint and
// notches all come from the Nim side, input events write through setParam
// (clamped, synchronous mirror), release fires commitParam (the old "change"
// event's side effects).
//
// Notches are labelled tick marks the drag snaps to when it comes close. They
// are a soft magnet, never a hard stop — the track stays continuous, so a
// value between two named ones is still reachable by dragging past the pull.

import { For, Show } from "solid-js";
import type { PanelController } from "../state";
import { formatParamValue } from "../lib/format";
import { applySnap, notchPosition } from "../lib/notches";

export function ParamSlider(props: { ctrl: PanelController; id: string }) {
  const descriptor = props.ctrl.byId.get(props.id);
  if (!descriptor) return null;
  const value = () => props.ctrl.params[props.id] ?? descriptor.defaultValue;

  // Only notches that land inside the track get a tick. Nim already asserts
  // every notch is in range, so this filter is a guard against an older
  // app.js, not an expected case.
  const ticks = () =>
    descriptor.notches
      .map((notch) => ({
        notch,
        position: notchPosition(notch.value, descriptor.min, descriptor.max),
      }))
      .filter((tick) => tick.position !== null);

  const write = (raw: number) => {
    props.ctrl.setParam(
      props.id,
      applySnap(raw, descriptor.notches, descriptor.min, descriptor.max),
    );
  };

  return (
    <div class="control-group">
      <label>
        {descriptor.label}
        <Show when={descriptor.hint}>
          <span class="param-hint"> — {descriptor.hint}</span>
        </Show>
        <span class="value-display">
          {formatParamValue(value(), descriptor.kind, descriptor.precision)}
        </span>
      </label>
      <div class="slider-track" classList={{ notched: ticks().length > 0 }}>
        <input
          type="range"
          min={descriptor.min}
          max={descriptor.max}
          step={descriptor.step}
          value={value()}
          onInput={(event) => write(parseFloat(event.currentTarget.value))}
          onChange={() => props.ctrl.commitParam(props.id)}
        />
        <Show when={ticks().length > 0}>
          <div class="notch-rail" aria-hidden="true">
            <For each={ticks()}>
              {(tick) => (
                <span
                  class="notch-tick"
                  classList={{
                    active: Math.abs(value() - tick.notch.value) < 1e-9,
                  }}
                  style={{ left: `${(tick.position as number) * 100}%` }}
                  title={`${tick.notch.label} (${formatParamValue(
                    tick.notch.value,
                    descriptor.kind,
                    descriptor.precision,
                  )})`}
                >
                  <span class="notch-label">{tick.notch.label}</span>
                </span>
              )}
            </For>
          </div>
        </Show>
      </div>
    </div>
  );
}
