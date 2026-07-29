// One range slider bound to a descriptor: min/max/step, label, hint and
// notches all come from the Nim side, input events write through setParam
// (clamped, synchronous mirror), release fires commitParam (the DOM "change"
// event's side effects).
//
// Notches are labelled tick marks the drag snaps to when it comes close. They
// are a soft magnet, never a hard stop — the track stays continuous, so a
// value between two named ones is still reachable by dragging past the pull.

import { For, Show } from "solid-js";
import type { PanelController } from "../state";
import { formatParamValue } from "../lib/format";
import { applySnap, notchPosition } from "../lib/notches";
import { dormantShare } from "../lib/bounds";

export function ParamSlider(props: { ctrl: PanelController; id: string }) {
  const descriptor = props.ctrl.byId.get(props.id);
  if (!descriptor) return null;
  const value = () => props.ctrl.params[props.id] ?? descriptor.defaultValue;

  // The track above a derived bound's live ceiling. The stored value keeps its
  // whole envelope — the handle still reaches the maximum and the number still
  // saves — but the simulation runs at the ceiling, so this shades the part of
  // the travel the fluid cannot currently honour. Nim owns both the ceiling and
  // the reason; this reads them.
  const bound = descriptor.bound;
  const dormant = () =>
    bound.kind === "derived"
      ? dormantShare(
          props.ctrl.ceilings[props.id],
          descriptor.min,
          descriptor.max,
        )
      : null;

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
      <Show when={bound.kind === "derived" && dormant() !== null}>
        <p class="param-dormant-note">
          {bound.kind === "derived" ? bound.reason : ""}
        </p>
      </Show>
      <div class="slider-track" classList={{ notched: ticks().length > 0 }}>
        <Show when={dormant() !== null}>
          <div
            class="slider-dormant"
            style={{ width: `${(dormant() as number) * 100}%` }}
            aria-hidden="true"
          />
        </Show>
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
