import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A plain UIKit file picker. SwiftUI's fileImporter is unreliable when it sits inside tabs, forms and sheets.
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let copy: Bool
    let onPick: (URL) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: copy)
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
    var onCancel: () -> Void = {}
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
