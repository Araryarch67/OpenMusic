# Sign-in window for YouTube Music (see openmusic_login.cc). Optional: without
# webkit2gtk-4.1 the app still builds and offers the browser / OAuth sign-ins.
pkg_check_modules(WEBKIT IMPORTED_TARGET webkit2gtk-4.1)
if(NOT WEBKIT_FOUND)
  message(STATUS "webkit2gtk-4.1 not found; building without the in-app Google sign-in")
  return()
endif()

add_executable(openmusic_login "openmusic_login.cc")
apply_standard_settings(openmusic_login)
target_link_libraries(openmusic_login PRIVATE PkgConfig::GTK PkgConfig::WEBKIT)
set_target_properties(openmusic_login PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run")
add_dependencies(${BINARY_NAME} openmusic_login)
