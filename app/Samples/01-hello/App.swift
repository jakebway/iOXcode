import SwiftUI

@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup { VStack(spacing: 12) { Image(systemName: "hammer.fill").font(.largeTitle); Text("Hello from iOXcode") } }
    }
}
