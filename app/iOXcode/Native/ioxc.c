#include "ioxc.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <os/proc.h>

typedef uint32_t (*abi_fn)(void);
typedef SwiftCompilerResult (*run_fn)(int32_t, const char *const *);
typedef void (*release_fn)(char *);

static void *handle;
static abi_fn abiFn;
static run_fn frontendFn;
static run_fn linkFn;
static release_fn releaseFn;

static void setError(char *error, size_t length, const char *text) {
  if (error && length) {
    snprintf(error, length, "%s", text);
  }
}

int ioxc_load(const char *path, char *error, size_t errorLength) {
  if (handle) {
    return 0;
  }
  void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    const char *e = dlerror();
    setError(error, errorLength, e ? e : "dlopen failed");
    return 1;
  }
  abiFn = (abi_fn)dlsym(h, "swift_compiler_abi_version");
  frontendFn = (run_fn)dlsym(h, "swift_compiler_frontend");
  linkFn = (run_fn)dlsym(h, "swift_compiler_link");
  releaseFn = (release_fn)dlsym(h, "swift_compiler_release");
  if (!abiFn || !frontendFn || !linkFn || !releaseFn) {
    setError(error, errorLength, "the library is missing swift_compiler_* symbols");
    dlclose(h);
    return 2;
  }
  handle = h;
  return 0;
}

int ioxc_is_loaded(void) { return handle != NULL; }

uint32_t ioxc_abi_version(void) { return abiFn ? abiFn() : 0; }

SwiftCompilerResult ioxc_frontend(int32_t count, const char *const *arguments) {
  if (!frontendFn) {
    SwiftCompilerResult r = {1, 1, NULL, 0};
    return r;
  }
  return frontendFn(count, arguments);
}

SwiftCompilerResult ioxc_link(int32_t count, const char *const *arguments) {
  if (!linkFn) {
    SwiftCompilerResult r = {1, 1, NULL, 0};
    return r;
  }
  return linkFn(count, arguments);
}

void ioxc_release(char *message) {
  if (releaseFn) {
    releaseFn(message);
  }
}

size_t ioxc_available_memory(void) { return os_proc_available_memory(); }

// ---- embedded Python (loaded at runtime so the app still works without it)

typedef void (*py_init_fn)(int);
typedef int (*py_run_fn)(const char *);
typedef void *(*py_save_fn)(void);
typedef int (*py_ensure_fn)(void);
typedef void (*py_release_fn)(int);

static void *pyHandle;
static py_run_fn pyRun;
static py_ensure_fn pyEnsure;
static py_release_fn pyRelease;
static int pyReady;

int ioxc_py_start(const char *frameworkBinary, const char *setupCode, char *error, size_t errorLength) {
  if (pyReady) return 0;
  if (!pyHandle) {
    pyHandle = dlopen(frameworkBinary, RTLD_NOW | RTLD_GLOBAL);
    if (!pyHandle) {
      const char *e = dlerror();
      setError(error, errorLength, e ? e : "dlopen failed");
      return 1;
    }
  }
  py_init_fn init = (py_init_fn)dlsym(pyHandle, "Py_InitializeEx");
  pyRun = (py_run_fn)dlsym(pyHandle, "PyRun_SimpleString");
  py_save_fn save = (py_save_fn)dlsym(pyHandle, "PyEval_SaveThread");
  pyEnsure = (py_ensure_fn)dlsym(pyHandle, "PyGILState_Ensure");
  pyRelease = (py_release_fn)dlsym(pyHandle, "PyGILState_Release");
  if (!init || !pyRun || !save || !pyEnsure || !pyRelease) {
    setError(error, errorLength, "Python.framework is missing expected functions");
    return 1;
  }
  init(0);  // no signal handlers: this is a guest inside the app
  int rc = pyRun(setupCode);
  save();   // release the GIL so any thread can run code later
  if (rc != 0) {
    setError(error, errorLength, "Python started but its setup code failed");
    return 1;
  }
  pyReady = 1;
  return 0;
}

int ioxc_py_exec(const char *code) {
  if (!pyReady) return -1;
  int state = pyEnsure();
  int rc = pyRun(code);
  pyRelease(state);
  return rc;
}
