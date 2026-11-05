import SwiftUI
import KeychainAccess

@main
struct PackageApp: App {
    let keychain = Keychain(service: "com.example.packagedemo")
    var body: some Scene {
        WindowGroup { Text(keychain["token"] ?? "no token yet") }
    }
}
