import { render } from "solid-js/web";
import "./ui.css";

function Panel() {
  return <div class="pg-panel-probe" style={{ display: "none" }} />;
}

const root = document.getElementById("ui-root");
if (root) {
  render(() => <Panel />, root);
}
