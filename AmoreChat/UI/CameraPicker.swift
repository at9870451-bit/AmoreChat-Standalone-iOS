import SwiftUI
import UIKit

/// Opens the system camera only on devices that provide one.
struct CameraPicker: UIViewControllerRepresentable {
    let completed: (Data?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completed: (Data?) -> Void
        init(completed: @escaping (Data?) -> Void) { self.completed = completed }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            completed(image?.pngData())
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completed(nil)
        }
    }
}
