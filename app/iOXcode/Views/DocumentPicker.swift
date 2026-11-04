import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Shows the system file browser straight from UIKit (not inside a SwiftUI sheet), so Open/Cancel always work.
enum FilePicker {
    private static var holder: Delegate?

    static func present(types: [UTType], copy: Bool, onPick: @escaping (URL) -> Void) {
        // wait a moment so a closing menu or sheet does not block the presentation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: copy)
            vc.allowsMultipleSelection = false
            let d = Delegate(onPick)
            holder = d
            vc.delegate = d
            top()?.present(vc, animated: true)
        }
    }

    private static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        var vc = windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windows.first?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            FilePicker.holder = nil
            if let u = urls.first { onPick(u) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { FilePicker.holder = nil }
    }
}
