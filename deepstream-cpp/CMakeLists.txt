cmake_minimum_required(VERSION 3.18)
project(ds_fish_pipeline LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# DeepStream SDK root
set(DEEPSTREAM_DIR "/opt/nvidia/deepstream/deepstream-6.4" CACHE PATH "DeepStream SDK root")

# --- Dependencies ---
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED gstreamer-1.0 gstreamer-app-1.0)
pkg_check_modules(GLIB REQUIRED glib-2.0)
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)

# CUDA runtime — just need headers + libs, not the compiler
find_path(CUDA_INCLUDE_DIR cuda_runtime.h HINTS /usr/local/cuda/include)
find_library(CUDA_RUNTIME_LIB cudart HINTS /usr/local/cuda/lib64)

# nlohmann-json — installed via apt in Dockerfile
find_package(nlohmann_json REQUIRED)

# ixwebsocket — vendored in third_party/
set(USE_TLS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/ixwebsocket)

# --- Sources ---
set(SOURCES
    src/main.cpp
    src/config.cpp
    src/pipeline.cpp
    src/probes.cpp
    src/thumbnail.cpp
    src/phoenix_client.cpp
)

add_executable(ds_fish_pipeline ${SOURCES})

target_include_directories(ds_fish_pipeline PRIVATE
    ${GST_INCLUDE_DIRS}
    ${GLIB_INCLUDE_DIRS}
    ${CUDA_INCLUDE_DIR}
    ${OpenCV_INCLUDE_DIRS}
    ${DEEPSTREAM_DIR}/sources/includes
    src
)

target_link_directories(ds_fish_pipeline PRIVATE
    ${GST_LIBRARY_DIRS}
    ${DEEPSTREAM_DIR}/lib
)

# Allow unresolved symbols from transitive deps (libheif → libde265/libx265)
# to be resolved at runtime rather than failing the link.
target_link_options(ds_fish_pipeline PRIVATE "LINKER:--allow-shlib-undefined")

target_link_libraries(ds_fish_pipeline PRIVATE
    ${GST_LIBRARIES}
    ${GLIB_LIBRARIES}
    ${CUDA_RUNTIME_LIB}
    ${OpenCV_LIBS}
    nvdsgst_meta
    nvds_meta
    nvbufsurface
    nvbufsurftransform
    ixwebsocket
    nlohmann_json::nlohmann_json
    pthread
)

target_compile_options(ds_fish_pipeline PRIVATE -Wall -Wextra -O2)
