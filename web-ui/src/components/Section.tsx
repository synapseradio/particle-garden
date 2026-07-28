// Collapsible section over the panel's section-header/-content markup.
// Collapse state is Solid-local; sections start collapsed unless the caller
// opens them.
//
// defaultOpen is read once, at mount. Every section stays mounted for the life
// of the panel, so a manual collapse or expand sticks until the page reloads.

import { createSignal, Show, type JSX } from "solid-js";

export function Section(props: {
  title: string;
  defaultOpen?: boolean;
  children: JSX.Element;
}) {
  const [open, setOpen] = createSignal(props.defaultOpen ?? false);
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
