import SwiftUI
import Observation

@Observable
final class Counter {
    var count = 0
    func bump() { count += 1 }
}

@main
struct CounterApp: App {
    @State private var counter = Counter()
    var body: some Scene {
        WindowGroup {
            Button("Count: \(counter.count)") { counter.bump() }
        }
    }
}
