import Foundation
import Photos
import SwiftUI
import UIKit

enum EmbeddedImageHistoryAction: String, CaseIterable, Hashable {
    case saveToPhotos = "Save to Photos"
    case share = "Share"

    var label: String { rawValue }

    var systemImage: String {
        switch self {
        case .saveToPhotos:
            return "photo.badge.arrow.down"
        case .share:
            return "square.and.arrow.up"
        }
    }
}

enum EmbeddedImageHistoryActionPolicy {
    static func actions(for image: EmbeddedImage?) -> [EmbeddedImageHistoryAction] {
        image == nil ? [] : EmbeddedImageHistoryAction.allCases
    }

    static func labels(appendingTo existingLabels: [String], for image: EmbeddedImage?) -> [String] {
        existingLabels + actions(for: image).map(\.label)
    }
}

enum EmbeddedImagePhotoAuthorizationDecision: Equatable {
    case save
    case request
    case deny

    static func decision(for status: PHAuthorizationStatus) -> EmbeddedImagePhotoAuthorizationDecision {
        switch status {
        case .authorized, .limited:
            return .save
        case .notDetermined:
            return .request
        case .denied, .restricted:
            return .deny
        @unknown default:
            return .deny
        }
    }
}

enum EmbeddedImagePhotoLibraryError: LocalizedError {
    case accessDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Photo Library access was not allowed. You can change this in iOS Settings for Clipman."
        case .saveFailed:
            return "Photos could not save the image."
        }
    }
}

@MainActor
enum EmbeddedImagePhotoLibrary {
    static func save(_ image: EmbeddedImage) async throws {
        var decision = EmbeddedImagePhotoAuthorizationDecision.decision(
            for: PHPhotoLibrary.authorizationStatus(for: .addOnly)
        )
        if decision == .request {
            let status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
            decision = EmbeddedImagePhotoAuthorizationDecision.decision(for: status)
        }
        guard decision == .save else { throw EmbeddedImagePhotoLibraryError.accessDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = image.filename
                request.addResource(with: .photo, data: image.data, options: options)
            } completionHandler: { saved, error in
                if saved {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? EmbeddedImagePhotoLibraryError.saveFailed)
                }
            }
        }
    }
}

struct EmbeddedImageShareFile: Identifiable {
    let id: UUID
    let url: URL
    let directory: URL

    static func create(for image: EmbeddedImage, fileManager: FileManager = .default) throws -> EmbeddedImageShareFile {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ClipmanImageShare", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(rootValues)

        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let url = directory.appendingPathComponent(image.filename, isDirectory: false)
            try image.data.write(to: url, options: [.atomic, .completeFileProtection])
            return EmbeddedImageShareFile(id: id, url: url, directory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }
}

struct EmbeddedImageShareSheet: UIViewControllerRepresentable {
    let file: EmbeddedImageShareFile
    let completion: (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            file.remove()
            completion(completed, error)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
