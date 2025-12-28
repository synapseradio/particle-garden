/**
 * UI and DOM interaction module for Goober Garden.
 *
 * Handles:
 * - Slider/input bindings to CONFIG values
 * - Mouse and touch event handling
 * - Window resize events
 * - UI toggle functions (trails, controls panel)
 * - Attraction matrix display and editing
 * - Stats display updates
 */

import { CONFIG, MAX_SPECIES, COLORS } from './config.js';
import { matrix, bytesSavedPerFrame } from './buffers.js';

// ═══════════════════════════════════════════════════════════════════════════════
// MOUSE STATE (exported for physics calculations)
// ═══════════════════════════════════════════════════════════════════════════════

export let mouseX = 0;
export let mouseY = 0;
export let mouseDown = false;

// ═══════════════════════════════════════════════════════════════════════════════
// CALLBACK REFERENCES
// ═══════════════════════════════════════════════════════════════════════════════

// Set via init() - called when particle/species count changes
let onInitParticles = null;

// Set via init() - called on window resize
let onResize = null;

// ═══════════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Initialize the UI module with required callbacks.
 *
 * @param {Object} callbacks - Required callback functions
 * @param {Function} callbacks.initParticles - Called when particle/species count changes
 * @param {Function} callbacks.resize - Called on window resize
 */
export function init(callbacks) {
  onInitParticles = callbacks.initParticles;
  onResize = callbacks.resize;
}

// ═══════════════════════════════════════════════════════════════════════════════
// UI SETUP
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Bind slider inputs to CONFIG values.
 * Updates display values in real-time, triggers callbacks on change.
 */
export function setupUI() {
  // Particle count slider
  document.getElementById('particleCount').oninput = (e) => {
    CONFIG.particleCount = +e.target.value;
    document.getElementById('particleValue').textContent = CONFIG.particleCount;
  };
  document.getElementById('particleCount').onchange = () => {
    if (onInitParticles) onInitParticles();
  };

  // Species count slider
  document.getElementById('speciesCount').oninput = (e) => {
    CONFIG.speciesCount = +e.target.value;
    document.getElementById('speciesValue').textContent = CONFIG.speciesCount;
  };
  document.getElementById('speciesCount').onchange = () => {
    randomizeMatrix();
    if (onInitParticles) onInitParticles();
  };

  // Interaction radius slider
  document.getElementById('interactionRadius').oninput = (e) => {
    CONFIG.interactionRadius = +e.target.value;
    document.getElementById('radiusValue').textContent = CONFIG.interactionRadius;
  };

  // Force strength slider
  document.getElementById('forceStrength').oninput = (e) => {
    CONFIG.forceStrength = +e.target.value;
    document.getElementById('forceValue').textContent = CONFIG.forceStrength.toFixed(1);
  };

  // Friction slider
  document.getElementById('friction').oninput = (e) => {
    CONFIG.friction = +e.target.value;
    document.getElementById('frictionValue').textContent = CONFIG.friction.toFixed(2);
  };

  // Time scale slider
  document.getElementById('timeScale').oninput = (e) => {
    CONFIG.timeScale = +e.target.value;
    document.getElementById('timeScaleValue').textContent = CONFIG.timeScale.toFixed(1);
  };

  // Trail length slider
  document.getElementById('trailLength').oninput = (e) => {
    CONFIG.trailAlpha = +e.target.value;
    document.getElementById('trailValue').textContent = CONFIG.trailAlpha.toFixed(2);
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
// EVENT SETUP
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Set up mouse, touch, and resize event handlers.
 *
 * @param {HTMLCanvasElement} canvas - The canvas element for mouse/touch events
 */
export function setupEvents(canvas) {
  // Window resize
  window.onresize = () => {
    if (onResize) onResize();
  };

  // Mouse events
  canvas.onmousedown = (e) => {
    mouseDown = true;
    mouseX = e.clientX;
    mouseY = e.clientY;
  };
  canvas.onmouseup = () => {
    mouseDown = false;
  };
  canvas.onmouseleave = () => {
    mouseDown = false;
  };
  canvas.onmousemove = (e) => {
    mouseX = e.clientX;
    mouseY = e.clientY;
  };

  // Touch events
  canvas.ontouchstart = (e) => {
    e.preventDefault();
    mouseDown = true;
    mouseX = e.touches[0].clientX;
    mouseY = e.touches[0].clientY;
  };
  canvas.ontouchend = () => {
    mouseDown = false;
  };
  canvas.ontouchmove = (e) => {
    e.preventDefault();
    mouseX = e.touches[0].clientX;
    mouseY = e.touches[0].clientY;
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
// UI TOGGLE FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Toggle trail rendering mode.
 * Updates button state and shows/hides trail length slider.
 */
export function toggleTrails() {
  CONFIG.trails = !CONFIG.trails;
  document.getElementById('trailBtn').classList.toggle('active', CONFIG.trails);
  document.getElementById('trailSettings').style.display = CONFIG.trails ? 'block' : 'none';
}

/**
 * Toggle controls panel visibility.
 * Updates collapse button text.
 */
export function toggleControls() {
  const c = document.getElementById('controls');
  c.classList.toggle('collapsed');
  c.querySelector('.collapse-btn').textContent = c.classList.contains('collapsed') ? '+' : '-';
}

// ═══════════════════════════════════════════════════════════════════════════════
// MATRIX UI
// ═══════════════════════════════════════════════════════════════════════════════

// Callback for when matrix is updated - set by init or externally
let onMatrixUpdate = null;

/**
 * Set callback for matrix updates.
 * Called after randomizeMatrix() or updateMatrixRule().
 *
 * @param {Function} callback - Called when matrix values change
 */
export function setMatrixUpdateCallback(callback) {
  onMatrixUpdate = callback;
}

/**
 * Randomize all values in the attraction matrix.
 * Values range from -1 (repulsion) to +1 (attraction).
 */
export function randomizeMatrix() {
  const ns = CONFIG.speciesCount;
  for (let i = 0; i < ns; i++) {
    for (let j = 0; j < ns; j++) {
      matrix[i * MAX_SPECIES + j] = Math.random() * 2 - 1;
    }
  }
  updateMatrixDisplay();
  if (onMatrixUpdate) onMatrixUpdate();
  console.log("Matrix randomized - sample values:", matrix[0], matrix[1], matrix[6], matrix[7]);
}

/**
 * Update the matrix display grid to reflect current values.
 * Creates editable input cells with color-coded backgrounds.
 */
export function updateMatrixDisplay() {
  const el = document.getElementById('matrixDisplay');
  const ns = CONFIG.speciesCount;
  el.style.gridTemplateColumns = `repeat(${ns + 1}, 1fr)`;

  let html = '<div class="matrix-cell matrix-header"></div>';

  // Column headers (species colors)
  for (let j = 0; j < ns; j++) {
    const c = j * 3;
    html += `<div class="matrix-cell matrix-header" style="background:rgba(${(COLORS[c] * 255) | 0},${(COLORS[c + 1] * 255) | 0},${(COLORS[c + 2] * 255) | 0},0.5)"></div>`;
  }

  // Matrix rows
  for (let i = 0; i < ns; i++) {
    // Row header (species color)
    const c = i * 3;
    html += `<div class="matrix-cell matrix-header" style="background:rgba(${(COLORS[c] * 255) | 0},${(COLORS[c + 1] * 255) | 0},${(COLORS[c + 2] * 255) | 0},0.5)"></div>`;

    // Matrix cells
    for (let j = 0; j < ns; j++) {
      const v = matrix[i * MAX_SPECIES + j];
      const bg = `hsla(${v > 0 ? 120 : 0},${(Math.abs(v) * 100) | 0}%,40%,0.7)`;
      html += `<div class="matrix-cell" style="background:${bg}">
                  <input type="number" step="0.1" value="${v.toFixed(2)}"
                  data-row="${i}" data-col="${j}">
               </div>`;
    }
  }
  el.innerHTML = html;

  // Attach event listeners to inputs
  el.querySelectorAll('input[type="number"]').forEach((input) => {
    input.onchange = (e) => {
      const row = parseInt(e.target.dataset.row, 10);
      const col = parseInt(e.target.dataset.col, 10);
      updateMatrixRule(row, col, e.target);
    };
  });
}

/**
 * Update a single matrix rule value.
 *
 * @param {number} i - Row index (species that feels the force)
 * @param {number} j - Column index (species that exerts the force)
 * @param {HTMLInputElement} el - The input element containing the new value
 */
export function updateMatrixRule(i, j, el) {
  const v = parseFloat(el.value);
  if (!isNaN(v)) {
    matrix[i * MAX_SPECIES + j] = v;
    if (onMatrixUpdate) onMatrixUpdate();
    const bg = `hsla(${v > 0 ? 120 : 0},${(Math.abs(v) * 100) | 0}%,40%,0.7)`;
    el.parentElement.style.background = bg;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// STATS DISPLAY
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Update the stats display panel.
 *
 * @param {number} fps - Current frames per second
 * @param {number} gridTimeMs - Time spent building spatial grid (ms)
 * @param {number} workerTimeMs - Time spent in worker physics (ms)
 */
export function updateStats(fps, gridTimeMs, workerTimeMs) {
  document.getElementById('fps').textContent = fps;
  document.getElementById('gridTime').textContent = gridTimeMs.toFixed(2);
  document.getElementById('workerTime').textContent = workerTimeMs.toFixed(1);

  const mbPerSec = ((bytesSavedPerFrame * fps) / 1024 / 1024).toFixed(1);
  document.getElementById('memSaved').textContent = mbPerSec;
}

/**
 * Update the particle count display.
 *
 * @param {number} count - Current particle count
 */
export function updateParticleStats(count) {
  document.getElementById('particleStats').textContent = count.toLocaleString();
}

// ═══════════════════════════════════════════════════════════════════════════════
// GLOBAL WINDOW BINDINGS
// ═══════════════════════════════════════════════════════════════════════════════

// Make toggle functions available to inline onclick handlers in HTML
window.toggleTrails = toggleTrails;
window.toggleControls = toggleControls;
window.randomizeMatrix = randomizeMatrix;
