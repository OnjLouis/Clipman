import Foundation

public enum EmbeddedImageFileImportError: Equatable, Error, LocalizedError, Sendable {
    case noFile
    case multipleFiles
    case directory
    case unsupportedFileType
    case unreadableFile
    case inputTooLarge

    public var errorDescription: String? {
        switch self {
        case .noFile:
            return "The clipboard does not contain a local image file."
        case .multipleFiles:
            return "Paste one PNG or JPEG image file at a time."
        case .directory:
            return "Folders cannot be added to Rich Text history as images."
        case .unsupportedFileType:
            return "Only local PNG and JPEG image files can be added to Rich Text history."
        case .unreadableFile:
            return "The image file could not be read."
        case .inputTooLarge:
            return "The image is larger than the 16 MiB input limit."
        }
    }
}

public enum EmbeddedImageFileImport {
    public static func automaticCaptureEnabled(
        richTextHistoryEnabled: Bool,
        includeImagesEnabled: Bool,
        alsoAddCopiedImageFilesEnabled: Bool
    ) -> Bool {
        richTextHistoryEnabled && includeImagesEnabled && alsoAddCopiedImageFilesEnabled
    }

    public static func shouldUsePasteboardImageFallback(
        fileReferenceCount: Int,
        plainText: String?,
        automaticCaptureEnabled: Bool
    ) -> Bool {
        guard automaticCaptureEnabled,
              fileReferenceCount == 1,
              let plainText
        else {
            return false
        }

        let filename = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty,
              filename.count <= 255,
              !filename.contains(where: { $0.isNewline }),
              !filename.contains("/"),
              !filename.contains("\\")
        else {
            return false
        }

        return ["png", "jpg", "jpeg"].contains(
            URL(fileURLWithPath: filename).pathExtension.lowercased()
        )
    }

    public static func prepare(urls: [URL]) throws -> (text: String, payload: RichTextPayload, info: EmbeddedImageInfo) {
        guard !urls.isEmpty else { throw EmbeddedImageFileImportError.noFile }
        guard urls.count == 1 else { throw EmbeddedImageFileImportError.multipleFiles }

        let url = urls[0]
        guard url.isFileURL else { throw EmbeddedImageFileImportError.unsupportedFileType }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        } catch {
            throw EmbeddedImageFileImportError.unreadableFile
        }
        if values.isDirectory == true { throw EmbeddedImageFileImportError.directory }
        guard values.isRegularFile == true else { throw EmbeddedImageFileImportError.unreadableFile }

        let fileExtension = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(fileExtension) else {
            throw EmbeddedImageFileImportError.unsupportedFileType
        }
        if let fileSize = values.fileSize, fileSize > EmbeddedImageHTML.maxInputBytes {
            throw EmbeddedImageFileImportError.inputTooLarge
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: EmbeddedImageHTML.maxInputBytes + 1) ?? Data()
        } catch {
            throw EmbeddedImageFileImportError.unreadableFile
        }
        guard data.count <= EmbeddedImageHTML.maxInputBytes else {
            throw EmbeddedImageFileImportError.inputTooLarge
        }
        return try EmbeddedImageHTML.makePayload(data: data, filename: url.lastPathComponent)
    }
}
