import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Import a copy of a user-selected file. Some file providers label a valid ZIP
/// as generic data, so both callers accept files here and validate actual bytes.
@MainActor
struct NativeDocumentPicker: UIViewControllerRepresentable {
    let onSelection: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--document-ui-test") {
            picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        #endif
        return picker
    }

    func updateUIViewController(_ viewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onSelection = onSelection
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onSelection: (URL?) -> Void
        private var delivered = false

        init(_ onSelection: @escaping (URL?) -> Void) { self.onSelection = onSelection }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(nil)
        }

        private func finish(_ url: URL?) {
            guard !delivered else { return }
            delivered = true
            onSelection(url)
        }
    }
}
