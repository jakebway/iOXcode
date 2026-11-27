import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let path = Bundle.main.bundleURL.appendingPathComponent("KeychainSwift_KeychainSwift.bundle").path
        if let b = Bundle(path: path) { return b }
        fatalError("could not load resource bundle: \(path)")
    }()
}
