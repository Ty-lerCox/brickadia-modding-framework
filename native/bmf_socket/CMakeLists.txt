cmake_minimum_required(VERSION 3.22)
set(TARGET BMFSocket)
project(${TARGET})

add_library(${TARGET} SHARED bmf_socket.cpp)
target_link_libraries(${TARGET} PUBLIC UE4SS)
target_link_libraries(${TARGET} PRIVATE ws2_32)
