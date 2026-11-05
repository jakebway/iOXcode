import SwiftUI

struct Greeting: View {
    var name: String
    var body: some View { Text("Hi \(name)") }
}

#Preview {
    Greeting(name: "Preview")
}

#Preview("Second", traits: .sizeThatFitsLayout) {
    Greeting(name: "Second")
}

@main
struct PreviewApp: App {
    var body: some Scene { WindowGroup { Greeting(name: "World") } }
}
