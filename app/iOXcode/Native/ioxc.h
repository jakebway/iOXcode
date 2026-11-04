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
void ioxc_release(char *message);

/// Bytes the process may still allocate (os_proc_available_memory), or 0 if unknown.
size_t ioxc_available_memory(void);

#endif
