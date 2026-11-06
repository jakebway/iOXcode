#ifndef IOXC_H
#define IOXC_H

#include <stddef.h>
#include <stdint.h>
#include "SwiftCompilerBridge.h"

/// Loads libSwiftCompilerBridge.dylib from a path. Returns 0 on success, otherwise writes a message.
int ioxc_load(const char *path, char *error, size_t errorLength);
int ioxc_is_loaded(void);
uint32_t ioxc_abi_version(void);

/// Frontend arguments are the ones that follow "swift-frontend" (no program name, no "-frontend").
SwiftCompilerResult ioxc_frontend(int32_t count, const char *const *arguments);
/// Linker arguments start with the program name "ld64.lld".
SwiftCompilerResult ioxc_link(int32_t count, const char *const *arguments);
/// Clang arguments are a normal command line (argv[0] is "clang") for one compile step. Needs ABI 4.
int ioxc_has_clang(void);
SwiftCompilerResult ioxc_clang(int32_t count, const char *const *arguments);
void ioxc_release(char *message);

/// Bytes the process may still allocate (os_proc_available_memory), or 0 if unknown.
size_t ioxc_available_memory(void);

/// Loads Python.framework, initializes it and runs setupCode once. Returns 0 on success.
int ioxc_py_start(const char *frameworkBinary, const char *setupCode, char *error, size_t errorLength);
/// Runs Python source with the GIL held. Returns 0 on success, -1 if an exception escaped.
int ioxc_py_exec(const char *code);

#endif
