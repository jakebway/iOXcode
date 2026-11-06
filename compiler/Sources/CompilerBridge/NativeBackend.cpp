#include "CompilerBackend.h"
#include "lld/Common/Driver.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/Stack.h"
#include "clang/CodeGen/ObjectFilePCHContainerWriter.h"
#include "clang/Driver/Compilation.h"
#include "clang/Driver/Driver.h"
#include "clang/Driver/Job.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/TextDiagnosticBuffer.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/FrontendTool/Utils.h"
#include "clang/Serialization/ObjectFilePCHContainerReader.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "swift/AST/DiagnosticEngine.h"
#include "swift/Basic/InitializeSwiftModules.h"
#include "swift/Basic/LLVMInitialize.h"
#include "swift/Frontend/Frontend.h"
#include "swift/Frontend/PrintingDiagnosticConsumer.h"
#include "swift/FrontendTool/FrontendTool.h"
#include "llvm/Support/raw_ostream.h"
#include <mutex>
#include <utility>

LLD_HAS_DRIVER(macho)

/// The build links the upstream object-reader implementation without invoking a subprocess.
int autolink_extract_main(llvm::ArrayRef<const char *> arguments, const char *programName,
                          void *mainAddress);

namespace {

/// LLVM locates the containing image without requiring an executable on the filesystem.
char imageAnchor;

/// A process-wide registration gate for Swift AST classes and optimizer passes.
std::once_flag swiftModuleInitialization;

/// The frontend observer keeps the diagnostic consumer alive throughout compilation.
class DiagnosticCapture : public swift::FrontendObserver {
  /// The diagnostic engine borrows this consumer after frontend setup completes.
  swift::PrintingDiagnosticConsumer consumer;

public:
  /// The caller owns the destination stream until performFrontend returns.
  explicit DiagnosticCapture(llvm::raw_ostream &stream) : consumer(stream) {}

  /// Setup diagnostics emitted before this callback can still reach standard error.
  void configuredCompiler(swift::CompilerInstance &instance) override {
    instance.getDiags().addConsumer(consumer);
  }
};

} // namespace

void swift_toolchain::prepareNativeCompiler() {
  INITIALIZE_LLVM();
  std::call_once(swiftModuleInitialization, initializeSwiftModules);
}

swift_toolchain::BackendResult swift_toolchain::runFrontend(int32_t count,
                                                            const char *const *arguments) {
  prepareNativeCompiler();
  std::string message;
  llvm::raw_string_ostream stream(message);
  DiagnosticCapture capture(stream);
  const int result = swift::performFrontend({arguments, static_cast<size_t>(count)},
                                            "swift-compiler", &imageAnchor, &capture);
  return {result, true, std::move(message)};
}

swift_toolchain::BackendResult swift_toolchain::runAutolink(int32_t count,
                                                            const char *const *arguments) {
  const int result = autolink_extract_main({arguments, static_cast<size_t>(count)},
                                           "swift-autolink-extract", &imageAnchor);
  return {result, true, result == 0 ? "" : "Autolink extraction failed. Inspect standard error."};
}

swift_toolchain::BackendResult swift_toolchain::runLinker(int32_t count,
                                                          const char *const *arguments) {
  std::string message;
  llvm::raw_string_ostream stream(message);
  const lld::DriverDef drivers[] = {{lld::Darwin, &lld::macho::link}};
  const auto result =
      lld::lldMain({arguments, static_cast<size_t>(count)}, stream, stream, drivers);
  return {result.retCode, result.canRunAgain, std::move(message)};
}

namespace {

std::once_flag clangTargetInitialization;

/// Runs one `clang -cc1` job inside this process. The steps follow clang's own cc1_main, without the compile
/// cache, the timers and the process-level crash handling, none of which apply inside an app.
bool runClangFrontendJob(llvm::ArrayRef<const char *> cc1Arguments, llvm::raw_ostream &diagnosticStream) {
  using namespace clang;
  ensureSufficientStack();
  std::call_once(clangTargetInitialization, [] {
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmPrinters();
    llvm::InitializeAllAsmParsers();
  });

  auto pchOperations = std::make_shared<PCHContainerOperations>();
  pchOperations->registerWriter(std::make_unique<ObjectFilePCHContainerWriter>());
  pchOperations->registerReader(std::make_unique<ObjectFilePCHContainerReader>());

  IntrusiveRefCntPtr<DiagnosticIDs> diagnosticIDs = DiagnosticIDs::create();
  DiagnosticOptions parseOptions;
  auto *buffer = new TextDiagnosticBuffer;
  DiagnosticsEngine parseDiagnostics(diagnosticIDs, parseOptions, buffer);

  auto invocation = std::make_shared<CompilerInvocation>();
  bool success = CompilerInvocation::CreateFromArgs(*invocation, cc1Arguments, parseDiagnostics, "clang");
  auto instance = std::make_unique<CompilerInstance>(std::move(invocation), std::move(pchOperations));

  if (instance->getHeaderSearchOpts().UseBuiltinIncludes && instance->getHeaderSearchOpts().ResourceDir.empty()) {
    diagnosticStream << "error: no -resource-dir was given for the clang headers\n";
    return false;
  }
  instance->createVirtualFileSystem(llvm::vfs::getRealFileSystem(), buffer);
  instance->createDiagnostics(new TextDiagnosticPrinter(diagnosticStream, instance->getDiagnosticOpts()));
  if (!instance->hasDiagnostics()) {
    return false;
  }
  buffer->FlushDiagnostics(instance->getDiagnostics());
  if (!success) {
    instance->getDiagnosticClient().finish();
    return false;
  }
  instance->getFrontendOpts().MayEmitDiagnosticsAfterProcessingSourceFiles = true;
  success = ExecuteCompilerInvocation(instance.get());
  instance->getDiagnosticClient().finish();
  return success;
}

} // namespace

swift_toolchain::BackendResult swift_toolchain::runClang(int32_t count, const char *const *arguments) {
  using namespace clang;
  std::string message;
  llvm::raw_string_ostream stream(message);
  DiagnosticOptions driverOptions;
  auto *printer = new TextDiagnosticPrinter(stream, driverOptions);
  IntrusiveRefCntPtr<DiagnosticIDs> ids = DiagnosticIDs::create();
  DiagnosticsEngine diagnostics(ids, driverOptions, printer);
  driver::Driver driver("clang", "arm64-apple-ios16.0", diagnostics, "iOXcode clang", llvm::vfs::getRealFileSystem());
  driver.setCheckInputsExist(true);
  llvm::SmallVector<const char *, 64> args(arguments, arguments + count);
  std::unique_ptr<driver::Compilation> compilation(driver.BuildCompilation(args));
  if (!compilation || diagnostics.hasErrorOccurred()) {
    stream.flush();
    return {1, true, message.empty() ? "clang could not plan the compilation." : std::move(message)};
  }
  for (const auto &job : compilation->getJobs()) {
    const auto &command = job;
    const auto &jobArguments = command.getArguments();
    if (jobArguments.empty() || llvm::StringRef(jobArguments[0]) != "-cc1") {
      stream << "error: only compile steps run on iPhone (got a '" << command.getCreator().getName() << "' step)\n";
      stream.flush();
      return {1, true, std::move(message)};
    }
    llvm::SmallVector<const char *, 64> cc1(jobArguments.begin() + 1, jobArguments.end());
    if (!runClangFrontendJob(cc1, stream)) {
      stream.flush();
      return {1, true, message.empty() ? "clang failed." : std::move(message)};
    }
  }
  stream.flush();
  return {0, true, std::move(message)};
}
