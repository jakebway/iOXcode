import Foundation
import SwiftUI

@MainActor
final class Console: ObservableObject {
    @Published private(set) var text: String = ""
    func line(_ s: String) {
        text += s
        if !s.hasSuffix("\n") { text += "\n" }
        if text.count > 400_000 { text = String(text.suffix(300_000)) }
    }
    func clear() { text = "" }
}

/// Thread-safe sink that the build pipeline can write to from any thread.
final class LogSink {
    private let emit: (String) -> Void
    init(_ emit: @escaping (String) -> Void) { self.emit = emit }
    func log(_ s: String) { emit(s) }
}
