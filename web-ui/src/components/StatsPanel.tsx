// Stats readouts fed by the gardenAPI push stream (raw numbers; formatting
// lives here). GPU rows show "-" until a nonzero timestamp-query
// measurement arrives, matching the old panel's placeholder behavior.
//
// "GPU grid" and "GPU field" are mutually exclusive by mode, not sometimes
// missing: particle-life and SPH build a spatial hash and run no field,
// reaction-diffusion runs a field and builds no hash. Whichever a mode does
// not run reads "-".
//
// There is no CPU "Grid build" row. There is no CPU grid: the whole spatial
// hash is built on the GPU, and the row that used to sit here reported a
// hardcoded zero in all three modes.

import type { PanelController } from "../state";
import { formatMs, formatWithThousands } from "../lib/format";

export function StatsPanel(props: { ctrl: PanelController }) {
  const stats = props.ctrl.stats;
  const gpu = (value: number | undefined) =>
    value === undefined || value === 0 ? "-" : formatMs(value, 2);
  return (
    <div class="stats">
      <div>FPS: <span>{stats()?.fps ?? 0}</span></div>
      <div>
        Particles: <span>{formatWithThousands(stats()?.particleCount ?? 0)}</span>
      </div>
      <div>Frame: <span>{formatMs(stats()?.workerTimeMs ?? 0, 1)}</span>ms</div>
      <div>GPU grid: <span>{gpu(stats()?.gpuGridMs)}</span>ms</div>
      <div>GPU field: <span>{gpu(stats()?.gpuFieldMs)}</span>ms</div>
      <div>GPU physics: <span>{gpu(stats()?.gpuPhysicsMs)}</span>ms</div>
      <div>GPU draw: <span>{gpu(stats()?.gpuDrawMs)}</span>ms</div>
      <div>GPU present: <span>{gpu(stats()?.gpuPresentMs)}</span>ms</div>
    </div>
  );
}
