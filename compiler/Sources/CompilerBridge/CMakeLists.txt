if(NOT TARGET swiftFrontendTool OR NOT COMMAND add_swift_host_library)
  message(FATAL_ERROR "Configure this target through the pinned Swift compiler build.")
endif()

find_package(LLD CONFIG REQUIRED
  PATHS "${TOOLCHAIN_BUILD_ROOT}/llvm-ios/lib/cmake/lld" NO_DEFAULT_PATH)

add_swift_host_library(SwiftCompilerBridge SHARED
  "${CMAKE_CURRENT_LIST_DIR}/SwiftCompilerBridge.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/NativeBackend.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/CompletionBackend.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/AnnotationBackend.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/SemanticSupport.cpp"
  HAS_SWIFT_MODULES)
target_sources(SwiftCompilerBridge PRIVATE
  "${TOOLCHAIN_SWIFT_SOURCE}/lib/DriverTool/autolink_extract_main.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/../NativeProfile/BundledPluginPolicy.cpp")
target_include_directories(SwiftCompilerBridge PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../NativeProfile")
target_include_directories(SwiftCompilerBridge PRIVATE "${TOOLCHAIN_LLVM_SOURCE}/lld/include"
  "${TOOLCHAIN_LLVM_SOURCE}/clang/include"
  "${TOOLCHAIN_BUILD_ROOT}/llvm-ios/tools/clang/include")
target_link_libraries(SwiftCompilerBridge PRIVATE
  swiftFrontendTool swiftCompilerModules swiftIDETool swiftIDE lldMachO lldCommon
  clangDriver clangFrontendTool clangFrontend clangCodeGen clangSerialization)
if(APPLE)
  target_link_libraries(SwiftCompilerBridge PRIVATE "-framework CoreFoundation")
endif()
set_target_properties(SwiftCompilerBridge PROPERTIES
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
