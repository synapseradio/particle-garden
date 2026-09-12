// The Audio section: the Listen switch, the affordance's state, a meter per
// continuous source, and an onset indicator that fades on its own energy.
// Nim owns every source's label and every threshold behind the affordance
// (audio_core.nim); this component restates none of them and runs no
// interval — the subscription in the effect below is the section's only
// clock, live exactly while the section is open and the panel not collapsed.

import { createEffect, createSignal, For, onCleanup } from "solid-js";
import type { PanelController } from "../state";
import type { AudioSample } from "../garden-api";
import { listenChecked, onsetLevel } from "../lib/audio-section";

const DISCONNECTED_SAMPLE: AudioSample = {
  state: "Disconnected",
  loudness: 0,
  bass: 0,
  mid: 0,
  high: 0,
  brightness: 0,
  onset: null,
};

export function AudioSection(props: {
  ctrl: PanelController;
  active: boolean;
}) {
  const { api } = props.ctrl;
  const sources = api.audioSources().filter((entry) => entry.kind === "continuous");
  const [sample, setSample] = createSignal<AudioSample>(DISCONNECTED_SAMPLE);

  // A subscribe pushes the current state once, so opening the section
  // shows where listening already stands rather than a stale default.
  createEffect(() => {
    if (!props.active) return;
    onCleanup(api.onAudio(setSample));
  });

  const valueOf = (sourceId: string): number => {
    const field = sourceId.slice(sourceId.indexOf(":") + 1) as keyof AudioSample;
    return sample()[field] as number;
  };

  return (
    <>
      <div class="control-group">
        <label class="toggle-label">
          <input
            id="listen"
            type="checkbox"
            role="switch"
            checked={listenChecked(sample().state)}
            onChange={(event) =>
              event.currentTarget.checked
                ? api.startListening()
                : api.stopListening()
            }
          />
          Listen
          <span class="param-hint">
            {" "}
            — the microphone becomes six sources the world can be played
            through
          </span>
        </label>
      </div>
      <div class="audio-state">{sample().state}</div>
      <For each={sources}>
        {(entry) => (
          <div class="control-group audio-meter">
            <label>{entry.label}</label>
            <meter min="0" max="1" value={valueOf(entry.id)} />
          </div>
        )}
      </For>
      <div class="audio-onset" style={{ opacity: onsetLevel(sample()) }} />
    </>
  );
}
