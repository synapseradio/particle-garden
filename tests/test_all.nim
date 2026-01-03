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
