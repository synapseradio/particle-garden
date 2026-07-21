// Collapsible section, matching the old panel's section-header/-content
// markup. Collapse state is Solid-local; sections start collapsed like the
// old panel's inline display:none.

import { createSignal, Show, type JSX } from "solid-js";

export function Section(props: { title: string; children: JSX.Element }) {
  const [open, setOpen] = createSignal(false);
  return (
    <div class="control-section">
      <button class="section-header" onClick={() => setOpen(!open())}>
        {props.title} <span class="section-toggle">{open() ? "−" : "+"}</span>
      </button>
      <Show when={open()}>
        <div class="section-content">{props.children}</div>
      </Show>
    </div>
  );
}
