# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(chta LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "chta")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Build the shared Rust core used by the Windows Dart FFI adapter.
get_filename_component(CHT_REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
find_program(CARGO_EXECUTABLE cargo HINTS "$ENV{USERPROFILE}/.cargo/bin" REQUIRED)
set(CHT_CORE_DLL "${CHT_REPOSITORY_ROOT}/target/release/cht_core.dll")
set(CHT_MESH_TARGET_DIR "${CHT_REPOSITORY_ROOT}/target/native-mesh")
set(CHT_MESH_DLL "${CHT_MESH_TARGET_DIR}/release/cht_mesh.dll")
set(CHT_RELAY_TARGET_DIR "${CHT_REPOSITORY_ROOT}/target/relay-server")
set(CHT_RELAY_EXE "${CHT_RELAY_TARGET_DIR}/release/cht-relay.exe")
find_program(CHT_PYTHON_EXECUTABLE NAMES python.exe python3 python REQUIRED)
set(CHT_RELAY_TOOLS_DIR "${CMAKE_CURRENT_BINARY_DIR}/relay-tools")
add_custom_target(cht_relay_tools ALL
  COMMAND "${CHT_PYTHON_EXECUTABLE}" "${CHT_REPOSITORY_ROOT}/scripts/fetch_windows_relay_tools.py"
    --output "${CHT_RELAY_TOOLS_DIR}"
  WORKING_DIRECTORY "${CHT_REPOSITORY_ROOT}"
  COMMENT "Preparing verified public relay runtime"
  VERBATIM)
add_custom_target(cht_relay_server ALL
  COMMAND "${CMAKE_COMMAND}" -E env "CARGO_TARGET_DIR=${CHT_RELAY_TARGET_DIR}"
    "${CARGO_EXECUTABLE}" build --locked --release
    --manifest-path "${CHT_REPOSITORY_ROOT}/rust/crates/relay_server/Cargo.toml"
  WORKING_DIRECTORY "${CHT_REPOSITORY_ROOT}"
  COMMENT "Building public cht-relay server"
  VERBATIM)
add_custom_target(cht_core_native ALL
  COMMAND "${CARGO_EXECUTABLE}" build --release -p cht-core
  WORKING_DIRECTORY "${CHT_REPOSITORY_ROOT}"
  COMMENT "Building native cht-core"
  VERBATIM)
add_custom_target(cht_mesh_native ALL
  COMMAND "${CMAKE_COMMAND}" -E env "CARGO_TARGET_DIR=${CHT_MESH_TARGET_DIR}"
    "${CARGO_EXECUTABLE}" build --release
    --manifest-path "${CHT_REPOSITORY_ROOT}/rust/crates/native_mesh/Cargo.toml"
  WORKING_DIRECTORY "${CHT_REPOSITORY_ROOT}"
  COMMENT "Building native cht-mesh"
  VERBATIM)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")
add_dependencies(${BINARY_NAME} cht_core_native)
add_dependencies(${BINARY_NAME} cht_mesh_native)
add_dependencies(${BINARY_NAME} cht_relay_server)
add_dependencies(${BINARY_NAME} cht_relay_tools)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT OR
   CMAKE_INSTALL_PREFIX MATCHES "^\\$<TARGET_FILE_DIR:[^>]+>$")
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(FILES "${CHT_CORE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${CHT_MESH_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(PROGRAMS "${CHT_RELAY_EXE}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(PROGRAMS "${CHT_RELAY_TOOLS_DIR}/cloudflared.exe" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${CHT_RELAY_TOOLS_DIR}/licenses/cloudflared-LICENSE.txt"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/licenses" COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
