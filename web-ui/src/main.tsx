// Entry point: mount the Solid control panel at #ui-root. gardenAPI is
// created at app.js module-eval time, which the shell page loads first;
// if it is missing (app.js failed to evaluate), there is nothing to drive,
// so nothing mounts.
import { render } from "solid-js/web";
import { createPanelController } from "./state";
import { Panel } from "./components/Panel";
import "./ui.css";

const root = document.getElementById("ui-root");
const api = window.gardenAPI;

if (root && api) {
  const ctrl = createPanelController(api);
  render(() => <Panel ctrl={ctrl} />, root);
}
