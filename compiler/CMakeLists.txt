cmake_minimum_required(VERSION 3.27)
project(iOXcodeCompiler LANGUAGES C CXX)

# Builds the Swift frontend, Clang importer, LLVM (arm64) and LLD (Mach-O) as one iOS dylib that an
# app calls in-process. Derived from mozharovsky/swift-toolchain-ios (Apache-2.0); see UPSTREAM.md.
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(TOOLCHAIN_ENABLE_COMPILER_BUILD "Create explicit upstream compiler build targets." OFF)
if(TOOLCHAIN_ENABLE_COMPILER_BUILD)
  include(CMake/CompilerBuild.cmake)
endif()
