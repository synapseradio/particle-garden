# ==============================================================================
# PARTICLE GARDEN - TEST SUITE
# ==============================================================================
#
# Run with: nimble test
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
import test_slider
import test_matrix
import test_config
import test_gpu_types
import test_shader_config
import test_stats
import test_control_panel
import test_app_state
import test_palette
import test_palette_state
import test_preset
import test_preset_store_core
import test_sim_registry
import test_sim_config

# Reference exported symbols to satisfy UnusedImport warning
# (unittest modules run tests as a side effect of import)
static:
  discard test_physics.EPSILON_TIGHT
  discard test_grid.EPSILON
  discard test_memory_layout.MEMORY_LAYOUT_TESTS_LOADED
  discard test_observable.OBSERVABLE_TESTS_LOADED
  discard test_input.INPUT_TESTS_LOADED
  discard test_slider.SLIDER_TESTS_LOADED
  discard test_matrix.MATRIX_STATE_TESTS_LOADED
  discard test_config.CONFIG_TESTS_LOADED
  discard test_gpu_types.GPU_TYPES_TESTS_LOADED
  discard test_shader_config.SHADER_CONFIG_TESTS_LOADED
  discard test_stats.STATS_TESTS_LOADED
  discard test_control_panel.CONTROL_PANEL_TESTS_LOADED
  discard test_app_state.APP_STATE_TESTS_LOADED
  discard test_palette.PALETTE_TESTS_LOADED
  discard test_palette_state.PALETTE_STATE_TESTS_LOADED
  discard test_preset.PRESET_TESTS_LOADED
  discard test_preset_store_core.PRESET_STORE_CORE_TESTS_LOADED
  discard test_sim_registry.SIM_REGISTRY_TESTS_LOADED
  discard test_sim_config.SIM_CONFIG_TESTS_LOADED
