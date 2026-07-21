// Entry point. While the old Nim-rendered panel is still the default, the
// Solid panel mounts only behind ?ui=solid (the side-by-side acceptance
// gate); the legacy panel is hidden — not removed, because ui.nim's stats
// writes still target its DOM nodes every frame.
import { render } from "solid-js/web";
import { createPanelController } from "./state";
import { Panel } from "./components/Panel";
import "./ui.css";

const solidRequested =
  new URLSearchParams(window.location.search).get("ui") === "solid";
const root = document.getElementById("ui-root");
const api = window.gardenAPI;

if (solidRequested && root && api) {
  const legacyPanel = document.getElementById("controls");
  if (legacyPanel) legacyPanel.style.display = "none";
  const ctrl = createPanelController(api);
  render(() => <Panel ctrl={ctrl} />, root);
}
