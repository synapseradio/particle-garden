/**
 * Configuration and constants for Goober Garden simulation.
 *
 * This module exports:
 * - CONFIG: Mutable runtime configuration (particle count, physics params, rendering options)
 * - MAX_* constants: Upper bounds for buffer allocation and grid sizing
 * - COLORS: Species color palette as interleaved RGB Float32Array
 */

// Runtime configuration - these values can be modified during simulation
export const CONFIG = {
  particleCount: 16000, // Number of active particles
  speciesCount: 4, // Number of particle species (affects matrix size)
  interactionRadius: 50, // Radius for particle-particle force calculations
  forceStrength: 1.0, // Multiplier for attraction/repulsion forces
  friction: 0.05, // Velocity damping per frame
  timeScale: 0.5, // Simulation speed multiplier
  particleSize: 2, // Base render size for particles
  trails: false, // Enable trail rendering mode
  trailAlpha: 0.92, // Trail fade factor (higher = longer trails)
};

// Buffer allocation limits - these determine SharedArrayBuffer sizes
export const MAX_PARTICLES = 64000; // Maximum supported particle count
export const MAX_SPECIES = 6; // Maximum species for attraction matrix
export const MAX_GRID = 256; // Maximum grid cells per dimension
export const MAX_WORKERS = 16; // Maximum Web Workers for physics

// Species color palette - interleaved RGB values (6 species x 3 components)
export const COLORS = new Float32Array([
  1.0,
  0.42,
  0.42, // Red
  1.0,
  0.85,
  0.24, // Yellow
  0.42,
  0.8,
  0.47, // Green
  0.3,
  0.59,
  1.0, // Blue
  0.73,
  0.42,
  1.0, // Purple
  1.0,
  0.55,
  0.3, // Orange
]);
