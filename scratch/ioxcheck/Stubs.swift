import Foundation
enum CCompiler { static let extensions: Set<String> = ["c", "m", "mm", "cpp", "cc", "cxx"] }
enum Paths {
    static var projects: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
}
