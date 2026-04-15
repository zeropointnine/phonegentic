cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Find PulseAudio
pkg_check_modules(PULSEAUDIO REQUIRED IMPORTED_TARGET libpulse)

# ─── whisper.cpp (on-device STT) ─────────────────────────────────────────────
include(FetchContent)
FetchContent_Declare(
  whisper
  GIT_REPOSITORY https://github.com/ggerganov/whisper.cpp.git
  GIT_TAG        v1.7.5
)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)

# Opportunistic GPU — enable backends if system libraries are available.
# The resulting binary always falls back to CPU if GPU init fails at runtime.
find_package(Vulkan QUIET)
if(Vulkan_FOUND)
  set(GGML_VULKAN ON CACHE BOOL "" FORCE)
  message(STATUS "whisper.cpp: Vulkan backend enabled")
else()
  message(STATUS "whisper.cpp: Vulkan not found — CPU only")
endif()

find_package(CUDAToolkit QUIET)
if(CUDAToolkit_FOUND)
  set(GGML_CUDA ON CACHE BOOL "" FORCE)
  message(STATUS "whisper.cpp: CUDA backend enabled")
else()
  message(STATUS "whisper.cpp: CUDA not found — skipping")
endif()

FetchContent_MakeAvailable(whisper)
# ─────────────────────────────────────────────────────────────────────────────

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "audio_device_channel.cc"
  "audio_tap_channel.cc"
  "kokoro_tts_channel.cc"
  "kokoro_onnx_engine.cc"
  "whisper_cpp_stt_channel.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::PULSEAUDIO)

# Find ONNX Runtime (optional — enables Kokoro TTS when available)
find_library(ONNXRUNTIME_LIB NAMES onnxruntime)
find_path(ONNXRUNTIME_INCLUDE NAMES onnxruntime_cxx_api.h)

if(ONNXRUNTIME_LIB AND ONNXRUNTIME_INCLUDE)
  target_link_libraries(${BINARY_NAME} PRIVATE ${ONNXRUNTIME_LIB})
  target_include_directories(${BINARY_NAME} PRIVATE ${ONNXRUNTIME_INCLUDE})
  target_compile_definitions(${BINARY_NAME} PRIVATE HAS_ONNXRUNTIME)
  message(STATUS "ONNX Runtime found: ${ONNXRUNTIME_LIB}")
else()
  message(WARNING "ONNX Runtime not found — Kokoro TTS will be disabled")
endif()

# Find espeak-ng (optional — enables G2P for Kokoro TTS when available)
pkg_check_modules(ESPEAKNG QUIET IMPORTED_TARGET espeak-ng)

if(ESPEAKNG_FOUND)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::ESPEAKNG)
  target_compile_definitions(${BINARY_NAME} PRIVATE HAS_ESPEAK_NG)
  message(STATUS "espeak-ng found")
else()
  message(WARNING "espeak-ng not found — Kokoro TTS phonemization will be disabled")
endif()

# Link dl for dlopen/dlsym (used by kokoro_onnx_engine.cc for dynamic espeak loading)
target_link_libraries(${BINARY_NAME} PRIVATE dl)

target_link_libraries(${BINARY_NAME} PRIVATE whisper)
# whisper.h lives at the repo root in v1.x; the target's INTERFACE_INCLUDE_DIRS
# may not export it, so add both root and include/ as a fallback.
target_include_directories(${BINARY_NAME} PRIVATE
    ${whisper_SOURCE_DIR}
    ${whisper_SOURCE_DIR}/include)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE ${PULSEAUDIO_INCLUDE_DIRS})
