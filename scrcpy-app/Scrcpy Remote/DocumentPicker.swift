//
//  DocumentPicker.swift
//  Scrcpy Remote
//
//  直接包 UIDocumentPickerViewController（2026-10-27）。
//
//  为什么不用 SwiftUI 的 .fileImporter：实测在这个 App 里点「打开」后
//  弹窗不消失、回调也不触发（选文件夹 / 选文件都复现），怀疑与越狱签名环境有关。
//  直接用 UIKit 的 picker 可控性更强，并且 asCopy: true 让系统把选中的文件
//  复制到 App 的临时目录 —— 之后可以直接读取，不用处理 security-scoped URL。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {

    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    /// 取消时回调空数组
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
