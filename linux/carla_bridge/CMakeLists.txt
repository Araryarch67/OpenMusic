# LADSPA bridge to Carla, for audio plugins in the filter chain (see
# openmusic_carla.cc). Needs no Carla headers or libraries to build.
add_library(openmusic_carla MODULE "openmusic_carla.cc")
target_compile_features(openmusic_carla PRIVATE cxx_std_17)
target_compile_options(openmusic_carla PRIVATE -Wall -Werror -O2 -fvisibility=hidden)
target_link_libraries(openmusic_carla PRIVATE ${CMAKE_DL_LIBS})
set_target_properties(openmusic_carla PROPERTIES PREFIX "lib" LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run")
add_dependencies(${BINARY_NAME} openmusic_carla)
