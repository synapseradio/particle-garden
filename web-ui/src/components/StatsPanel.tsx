// Stats readouts fed by the gardenAPI push stream (raw numbers; formatting
// lives here). GPU rows show "-" until a nonzero timestamp-query
// measurement arrives.
//
// A row reads "-" while the pass it times contributes nothing: the frame
// leaves a coupling's passes out at zero strength, so "GPU field" goes quiet
// on a world with no chemistry and the rest keep reporting.
//
// There is no CPU "Grid build" row, because there is no CPU grid: the whole
// spatial hash is built on the GPU, so such a row could only report a
// hardcoded zero.

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
