/**
 * WebGL rendering for Goober Garden particle simulation.
 *
 * This module handles all GPU-based rendering:
 * - Particle point sprites with density-based sizing
 * - Optional trail effect via fade overlay
 * - VBO management with pre-allocation to avoid GPU memory leaks
 *
 * The render loop reads particle data from the active buffer set and
 * uploads interleaved position/color/density data to the GPU each frame.
 */

import { CONFIG, MAX_PARTICLES, COLORS } from './config.js';
import {
  renderData,
  pxA,
  pyA,
  speciesA,
  pxB,
  pyB,
  speciesB,
  denA,
  denB,
  activeParity,
} from './buffers.js';

// ═══════════════════════════════════════════════════════════════════════════════
// SHADER SOURCES
// ═══════════════════════════════════════════════════════════════════════════════

// Particle vertex shader - transforms positions to clip space with density-based point size
const VERT = `
    attribute vec2 a_pos;
    attribute vec3 a_col;
    attribute float a_den;
    uniform vec2 u_res;
    uniform float u_size;
    varying vec3 v_col;
    void main() {
        vec2 clip = (a_pos / u_res) * 2.0 - 1.0;
        gl_Position = vec4(clip * vec2(1, -1), 0, 1);
        float size_mod = max(1.0, 4.0 - a_den * 0.5);
        gl_PointSize = u_size * size_mod;
        v_col = a_col;
    }
`;

// Particle fragment shader - circular point sprites with soft edges
const FRAG = `
    precision mediump float;
    varying vec3 v_col;
    void main() {
        vec2 c = gl_PointCoord - 0.5;
        float d2 = dot(c, c);
        if (d2 > 0.25) discard;
        float a = 1.0 - smoothstep(0.1, 0.25, d2);
        gl_FragColor = vec4(v_col, a);
    }
`;

// Fade overlay vertex shader - fullscreen quad
const FADE_VERT = `attribute vec2 a_pos; void main() { gl_Position = vec4(a_pos, 0, 1); }`;

// Fade overlay fragment shader - semi-transparent dark overlay for trail effect
const FADE_FRAG = `precision mediump float; uniform float u_alpha; void main() { gl_FragColor = vec4(0.04, 0.04, 0.06, u_alpha); }`;

// ═══════════════════════════════════════════════════════════════════════════════
// GL STATE
// ═══════════════════════════════════════════════════════════════════════════════

export let canvas;
export let gl;

let prog;
let fadeProg;
let vbo;
let quadVbo;
let uRes;
let uSize;
let aPos;
let aCol;
let aDen;
let fadeAPos;
let fadeAlpha;

// ═══════════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Initialize WebGL context, compile shaders, and set up buffers.
 * @returns {boolean} True if initialization succeeded, false otherwise
 */
export function initGL() {
  canvas = document.getElementById('canvas');
  gl = canvas.getContext('webgl', {
    alpha: false,
    antialias: false,
    preserveDrawingBuffer: true,
  });

  if (!gl) {
    alert('WebGL required');
    return false;
  }

  function compile(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
  }

  function link(vs, fs) {
    const p = gl.createProgram();
    gl.attachShader(p, vs);
    gl.attachShader(p, fs);
    gl.linkProgram(p);
    return gl.getProgramParameter(p, gl.LINK_STATUS) ? p : null;
  }

  prog = link(
    compile(gl.VERTEX_SHADER, VERT),
    compile(gl.FRAGMENT_SHADER, FRAG)
  );
  fadeProg = link(
    compile(gl.VERTEX_SHADER, FADE_VERT),
    compile(gl.FRAGMENT_SHADER, FADE_FRAG)
  );

  aPos = gl.getAttribLocation(prog, 'a_pos');
  aCol = gl.getAttribLocation(prog, 'a_col');
  aDen = gl.getAttribLocation(prog, 'a_den');
  uRes = gl.getUniformLocation(prog, 'u_res');
  uSize = gl.getUniformLocation(prog, 'u_size');
  fadeAPos = gl.getAttribLocation(fadeProg, 'a_pos');
  fadeAlpha = gl.getUniformLocation(fadeProg, 'u_alpha');

  vbo = gl.createBuffer();
  // Pre-allocate VBO to max size once — avoids per-frame GPU allocation leak
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
  gl.bufferData(gl.ARRAY_BUFFER, MAX_PARTICLES * 6 * 4, gl.DYNAMIC_DRAW);

  quadVbo = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quadVbo);
  gl.bufferData(
    gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
    gl.STATIC_DRAW
  );

  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

  resize();
  return true;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RESIZE HANDLING
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Update canvas and viewport to match window dimensions.
 */
export function resize() {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  gl.viewport(0, 0, canvas.width, canvas.height);
}

// ═══════════════════════════════════════════════════════════════════════════════
// RENDER
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Render all particles to the canvas.
 * @param {number} particleCount - Number of particles to render
 */
export function render(particleCount) {
  if (CONFIG.trails) {
    gl.useProgram(fadeProg);
    gl.uniform1f(fadeAlpha, 1 - CONFIG.trailAlpha);
    gl.bindBuffer(gl.ARRAY_BUFFER, quadVbo);
    gl.enableVertexAttribArray(fadeAPos);
    gl.vertexAttribPointer(fadeAPos, 2, gl.FLOAT, false, 0, 0);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  } else {
    gl.clearColor(0.04, 0.04, 0.06, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
  }

  const n = particleCount;
  // Select active buffer based on current parity
  const pxActive = activeParity === 1 ? pxB : pxA;
  const pyActive = activeParity === 1 ? pyB : pyA;
  const sActive = activeParity === 1 ? speciesB : speciesA;
  const denActive = activeParity === 1 ? denB : denA;

  for (let i = 0; i < n; i++) {
    const i6 = i * 6;
    const c = sActive[i] * 3;
    renderData[i6] = pxActive[i];
    renderData[i6 + 1] = pyActive[i];
    renderData[i6 + 2] = COLORS[c];
    renderData[i6 + 3] = COLORS[c + 1];
    renderData[i6 + 4] = COLORS[c + 2];
    renderData[i6 + 5] = denActive[i];
  }

  gl.useProgram(prog);
  gl.uniform2f(uRes, canvas.width, canvas.height);
  gl.uniform1f(uSize, CONFIG.particleSize + 1);

  gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
  // Update existing buffer — bufferSubData reuses GPU memory, bufferData allocates new
  gl.bufferSubData(gl.ARRAY_BUFFER, 0, renderData.subarray(0, n * 6));

  gl.enableVertexAttribArray(aPos);
  gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 24, 0);
  gl.enableVertexAttribArray(aCol);
  gl.vertexAttribPointer(aCol, 3, gl.FLOAT, false, 24, 8);
  gl.enableVertexAttribArray(aDen);
  gl.vertexAttribPointer(aDen, 1, gl.FLOAT, false, 24, 20);

  gl.drawArrays(gl.POINTS, 0, n);
}
