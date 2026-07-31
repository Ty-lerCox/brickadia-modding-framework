cmake_minimum_required(VERSION 3.22)
set(TARGET BMFFrameTelemetry)
project(${TARGET})

add_library(${TARGET} SHARED bmf_frame_telemetry.cpp)
target_link_libraries(${TARGET} PUBLIC UE4SS PRIVATE winmm)
