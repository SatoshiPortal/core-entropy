# Refuses to ship a binary containing Core's /dev/urandom fallback, or one
# missing the strong-path export. Runs on every Flutter/Gradle build.
file(STRINGS "${LIB}" HITS REGEX "/dev/urandom")
if(HITS)
  message(FATAL_ERROR "core-entropy: /dev/urandom present in ${LIB}")
endif()
execute_process(COMMAND ${NM} -D --defined-only "${LIB}" OUTPUT_VARIABLE SYMS
                ERROR_QUIET RESULT_VARIABLE RC)
if(RC EQUAL 0)
  string(FIND "${SYMS}" "core_entropy_get_strong" FOUND)
  if(FOUND EQUAL -1)
    message(FATAL_ERROR "core-entropy: core_entropy_get_strong not exported")
  endif()
  string(FIND "${SYMS}" "core_entropy_get_bytes" WEAK)
  if(NOT WEAK EQUAL -1)
    message(FATAL_ERROR "core-entropy: Core's FAST path is exported")
  endif()
endif()
message(STATUS "core-entropy: no fallback present, strong path exported")
