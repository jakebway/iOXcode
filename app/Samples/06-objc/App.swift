import SwiftUI

@main
struct ObjCApp: App {
    var body: some Scene { WindowGroup { Text(String(cString: ioxc_greeting())) } }
}
