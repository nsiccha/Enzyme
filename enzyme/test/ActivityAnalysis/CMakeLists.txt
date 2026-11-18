set(LLVM_LINK_COMPONENTS Support)
add_llvm_executable(EnzymeActivityReEvaluationTest EXCLUDE_FROM_ALL
                    reevaluation.cpp)
target_include_directories(EnzymeActivityReEvaluationTest
                           PRIVATE ${ENZYME_SOURCE_DIR}/Enzyme)
set_target_properties(
  EnzymeActivityReEvaluationTest
  PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")

# Run regression and unit tests
add_lit_testsuite(
  check-activityanalysis
  "Running enzyme regression tests"
  ${CMAKE_CURRENT_BINARY_DIR}
  DEPENDS
  ${ENZYME_TEST_DEPS}
  EnzymeActivityReEvaluationTest
  ARGS
  -v)

set_target_properties(check-activityanalysis PROPERTIES FOLDER "Tests")
