cmake_minimum_required(VERSION 3.15)
project(fxshot LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT WIN32)
  message(FATAL_ERROR
    "fxshot targets Direct3D 11 and builds on Windows only.")
endif()

add_executable(fxshot src/fxshot.cpp)

target_link_libraries(fxshot PRIVATE
  d3d11          # device, resources, pass execution
  dxgi           # adapter enumeration, to avoid the iGPU
  d3dcompiler    # compiles the translated HLSL at run time
  windowscodecs  # PNG load and save via WIC
  ole32)

if(MSVC)
  target_compile_options(fxshot PRIVATE /W3 /O2)
endif()

install(TARGETS fxshot RUNTIME DESTINATION bin)
install(PROGRAMS src/translate.py DESTINATION bin)

# The analysis scripts in tools/ are optional and need Python 3.13.
