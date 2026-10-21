import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static var signingP12: UTType {
        UTType(filenameExtension: "p12", conformingTo: .data) ?? .data
    }

    static var signingMobileProvision: UTType {
        UTType(filenameExtension: "mobileprovision", conformingTo: .data) ?? .data
    }
}

struct SigningFilePicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    var allowsMultipleSelection = false
    var asCopy = true
    let onDocumentsPicked: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentsPicked: onDocumentsPicked)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: asCopy
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentsPicked: ([URL]) -> Void

        init(onDocumentsPicked: @escaping ([URL]) -> Void) {
            self.onDocumentsPicked = onDocumentsPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDocumentsPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDocumentsPicked([])
        }
    }
}
