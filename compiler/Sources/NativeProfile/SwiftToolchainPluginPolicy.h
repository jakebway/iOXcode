#ifndef SWIFT_TOOLCHAIN_PLUGIN_POLICY_H
#define SWIFT_TOOLCHAIN_PLUGIN_POLICY_H

#ifdef __cplusplus
extern "C" {
#endif

/// Copies the canonical plugin path that the compiler or macro server may open.
/// The caller provides a readable null-terminated path for this call. Both the path and the main
/// application's private frameworks directory are resolved through filesystem symlinks.
/// Returns null when resolution fails or the path is not a regular file at a framework's executable
/// location in that directory. The loader validates the library format. A successful result is
/// null-terminated and must be freed by the caller with free().
/// Loaders open this returned path so mutable aliases cannot redirect a later open outside the
/// bundle. The application must preserve its bundled files throughout compiler use.
__attribute__((visibility("default"))) char *
swift_toolchain_copy_bundled_plugin_path(const char *path);

/// Starts a WebAssembly macro plugin. The embedding application interprets the program on a thread of this process.
/// `*toPluginFd` receives the write end of a pipe wired to the program's stdin and `*fromPluginFd` the read end of
/// a pipe wired to its stdout; the plugin ends when it reads end-of-file. Returns zero on success.
typedef int (*swift_toolchain_wasm_plugin_launcher_t)(const char *wasmPath, int *toPluginFd, int *fromPluginFd);

/// The application registers its launcher once (swift_compiler_set_wasm_plugin_launcher forwards here).
__attribute__((visibility("default"))) void
swift_toolchain_set_wasm_plugin_launcher(swift_toolchain_wasm_plugin_launcher_t launcher);

/// Called by the compiler for a '-load-plugin-executable <path>.wasm#Module' plugin. Fails (nonzero) without a launcher.
__attribute__((visibility("default"))) int
swift_toolchain_launch_wasm_plugin(const char *path, int *toPluginFd, int *fromPluginFd);

#ifdef __cplusplus
}
#endif

#endif
