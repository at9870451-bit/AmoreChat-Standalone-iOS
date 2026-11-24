import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OSLog

/// Keep the picker-granted read scope alive until background copying completes.
final class PickedDocument: Sendable {
    let url: URL
    private let scoped: Bool

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

/// Present Files as its own UIKit modal so Files controls selection and dismissal.
/// Ask for an imported copy; the source file is never edited.
@MainActor
struct NativeDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelection: (PickedDocument?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.presentIfNeeded(from: anchor)
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var configuration: NativeDocumentPicker
        private weak var picker: UIDocumentPickerViewController?
        private var scheduled = false
        private var delivered = false

        init(_ configuration: NativeDocumentPicker) { self.configuration = configuration }

        func presentIfNeeded(from anchor: UIViewController) {
            guard configuration.isPresented, picker == nil, !scheduled else { return }
            scheduled = true
            Task { @MainActor [weak self, weak anchor] in
                guard let self else { return }
                self.scheduled = false
                guard self.configuration.isPresented, self.picker == nil else { return }
                guard let root = anchor?.viewIfLoaded?.window?.rootViewController else {
                    self.resetSelection()
                    return
                }
                var presenter = root
                while let front = presenter.presentedViewController, !front.isBeingDismissed { presenter = front }
                guard presenter.presentedViewController == nil else {
                    self.resetSelection()
                    return
                }
                // Some providers label a valid ZIP as generic data. Validate the
                // archive after selection, not by the provider's advertised type.
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                picker.allowsMultipleSelection = false
                picker.delegate = self
                picker.modalPresentationStyle = .formSheet
                self.delivered = false
                self.picker = picker
                presenter.present(picker, animated: true)
                picker.presentationController?.delegate = self
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first.map(PickedDocument.init))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil) }

        private func resetSelection() {
            configuration.isPresented = false
            configuration.onSelection(nil)
        }

        private func finish(_ document: PickedDocument?) {
            guard !delivered else { return }
            delivered = true
            #if DEBUG
            Logger(subsystem: "app.amorechat.standalone.documents", category: "picker")
                .notice("System document picker finished; has selection: \(document != nil, privacy: .public)")
            #endif
            configuration.isPresented = false
            configuration.onSelection(document)
        }
    }
}
