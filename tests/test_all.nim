# ==============================================================================
# PARTICLE GARDEN - TEST SUITE
# ==============================================================================
#
# Run with: just test
#
# This file imports all test modules to run the complete test suite.
# Tests are registered and executed automatically via std/unittest on import.
#
# ==============================================================================

# Import test modules - tests run automatically on import via unittest
import test_physics
import test_grid
import test_memory_layout
import test_observable
import test_input
import test_matrix
import test_config
import test_gpu_types
import test_shader_config
import test_app_state
import test_palette
import test_palette_state
import test_preset
import test_preset_store_core
import test_sim_registry
import test_sim_config
import test_sph_core
import test_shader_manifest
import test_field_core
import test_bloom_core
import test_colormap_core
import test_glow_core
import test_trail_core
import test_param_descriptor
import test_response_probe
import test_camera_core
import test_climate_core
import test_camera_input
import test_wgsl_lint
import test_no_modes
import test_panel_reachability

# Reference exported symbols to satisfy UnusedImport warning
# (unittest modules run tests as a side effect of import)
static:
  discard test_physics.EPSILON_TIGHT
  discard test_grid.EPSILON
  discard test_memory_layout.MEMORY_LAYOUT_TESTS_LOADED
  discard test_observable.OBSERVABLE_TESTS_LOADED
  discard test_input.INPUT_TESTS_LOADED
  discard test_matrix.MATRIX_STATE_TESTS_LOADED
  discard test_config.CONFIG_TESTS_LOADED
  discard test_gpu_types.GPU_TYPES_TESTS_LOADED
  discard test_shader_config.SHADER_CONFIG_TESTS_LOADED
  discard test_app_state.APP_STATE_TESTS_LOADED
  discard test_palette.PALETTE_TESTS_LOADED
  discard test_palette_state.PALETTE_STATE_TESTS_LOADED
  discard test_preset.PRESET_TESTS_LOADED
  discard test_preset_store_core.PRESET_STORE_CORE_TESTS_LOADED
  discard test_sim_registry.SIM_REGISTRY_TESTS_LOADED
  discard test_sim_config.SIM_CONFIG_TESTS_LOADED
  discard test_sph_core.SPH_CORE_TESTS_LOADED
  discard test_shader_manifest.SHADER_MANIFEST_TESTS_LOADED
  discard test_field_core.FIELD_CORE_TESTS_LOADED
  discard test_bloom_core.BLOOM_CORE_TESTS_LOADED
  discard test_colormap_core.COLORMAP_CORE_TESTS_LOADED
  discard test_glow_core.GLOW_CORE_TESTS_LOADED
  discard test_trail_core.TRAIL_CORE_TESTS_LOADED
  discard test_param_descriptor.PARAM_DESCRIPTOR_TESTS_LOADED
  discard test_response_probe.RESPONSE_PROBE_TESTS_LOADED
  discard test_camera_core.CAMERA_CORE_TESTS_LOADED
  discard test_climate_core.CLIMATE_CORE_TESTS_LOADED
  discard test_camera_input.CAMERA_INPUT_TESTS_LOADED
  discard test_wgsl_lint.WGSL_LINT_TESTS_LOADED
  discard test_no_modes.NO_MODES_TESTS_LOADED
  discard test_panel_reachability.PANEL_REACHABILITY_TESTS_LOADED
