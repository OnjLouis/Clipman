import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum EmbeddedImageError: LocalizedError, Equatable {
    case unsupportedFormat
    case inputTooLarge
    case dimensionsTooLarge
    case animatedImage
    case couldNotDecode
    case couldNotOptimize
    case storedImageTooLarge
    case invalidWrapper

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Clipman can add standalone PNG and JPEG images only."
        case .inputTooLarge:
            return "The image is larger than Clipman's 16 MiB input limit."
        case .dimensionsTooLarge:
            return "The image exceeds Clipman's 16 megapixel or 4096-pixel dimension limit."
        case .animatedImage:
            return "Animated images cannot be added to Rich Text history."
        case .couldNotDecode:
            return "The image could not be read safely."
        case .couldNotOptimize:
            return "The image could not be reduced to Clipman's storage limits."
        case .storedImageTooLarge:
            return "The optimized image is larger than Clipman's 512 KiB image limit."
        case .invalidWrapper:
            return "The stored image entry is not in Clipman's safe image format."
        }
    }
}

struct EmbeddedImage: Equatable, Sendable {
    let filename: String
    let altText: String
    let mimeType: String
    let data: Data
    let width: Int
    let height: Int
    let containsMetadata: Bool

    var typeDescription: String { mimeType == "image/png" ? "PNG" : "JPEG" }
}

enum EmbeddedImageCodec {
    static let maximumInputBytes = 16 * 1024 * 1024
    static let maximumStoredBytes = 512 * 1024
    static let maximumPixelCount = 16_000_000
    static let maximumInputDimension = 4096
    static let preferredLongEdge = 2048
    static let totalDatabaseBudget = 8 * 1024 * 1024
    static let maximumHTMLBytes = 768 * 1024
    static let maximumEncodedImageBytes = ((maximumStoredBytes + 2) / 3) * 4
    private static let maximumMetadataBytes = 64 * 1024
    private static let marker = "data-clipman-image=\"1\""

    static func makePayload(data: Data, suggestedFilename: String? = nil) throws -> MobileClipboardPayload {
        let prepared = try prepare(data: data, suggestedFilename: suggestedFilename)
        let html = canonicalHTML(for: prepared)
        guard html.utf8.count <= maximumHTMLBytes else { throw EmbeddedImageError.storedImageTooLarge }
        return MobileClipboardPayload(
            text: identityText(for: prepared),
            richText: RichTextPayload(HtmlFragment: html, PreferredFormat: "Html"),
            importError: nil
        )
    }

    static func recognize(_ payload: RichTextPayload?) -> EmbeddedImage? {
        guard let html = payload?.HtmlFragment, html.contains(marker) else { return nil }
        return try? recognize(html: html)
    }

    static func recognize(html: String) throws -> EmbeddedImage {
        guard html.utf8.count <= maximumHTMLBytes else { throw EmbeddedImageError.invalidWrapper }
        let pattern = #"^<img data-clipman-image="1" data-clipman-filename="([^"]*)" alt="([^"]*)" src="data:(image/(?:jpeg|png));base64,([A-Za-z0-9+/]+={0,2})">$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges == 5,
              let filenameRange = Range(match.range(at: 1), in: html),
              let altRange = Range(match.range(at: 2), in: html),
              let mimeRange = Range(match.range(at: 3), in: html),
              let dataRange = Range(match.range(at: 4), in: html) else {
            throw EmbeddedImageError.invalidWrapper
        }
        let encodedData = html[dataRange]
        guard encodedImageLengthIsWithinLimit(encodedData),
              let data = Data(base64Encoded: String(encodedData)),
              data.count <= maximumStoredBytes else { throw EmbeddedImageError.invalidWrapper }
        let filename = decodeAttribute(String(html[filenameRange]))
        let altText = decodeAttribute(String(html[altRange]))
        let mimeType = String(html[mimeRange])
        guard isCanonicalFilename(filename, mimeType: mimeType),
              altText == displayText(filename: filename) else {
            throw EmbeddedImageError.invalidWrapper
        }
        let inspected = try inspect(data: data, maximumBytes: maximumStoredBytes)
        guard inspected.mimeType == mimeType,
              max(inspected.width, inspected.height) <= preferredLongEdge else {
            throw EmbeddedImageError.invalidWrapper
        }
        let image = EmbeddedImage(
            filename: filename,
            altText: altText,
            mimeType: mimeType,
            data: data,
            width: inspected.width,
            height: inspected.height,
            containsMetadata: inspected.containsMetadata
        )
        guard canonicalHTML(for: image) == html else { throw EmbeddedImageError.invalidWrapper }
        return image
    }

    static func encodedImageLengthIsWithinLimit(_ encodedData: Substring) -> Bool {
        let encodedByteCount = encodedData.utf8.count
        let paddingCount = encodedData.hasSuffix("==") ? 2 : (encodedData.hasSuffix("=") ? 1 : 0)
        return encodedByteCount <= maximumEncodedImageBytes
            && encodedByteCount.isMultiple(of: 4)
            && (encodedByteCount / 4) * 3 - paddingCount <= maximumStoredBytes
    }

    static func containsImageMarker(_ payload: RichTextPayload?) -> Bool {
        payload?.HtmlFragment.contains(marker) == true
    }

    static func totalStoredBytes(in database: ClipDatabase) -> Int {
        database.Entries.reduce(into: 0) { total, entry in
            total += recognize(entry.RichText)?.data.count ?? 0
        }
    }

    static func canonicalHTML(for image: EmbeddedImage) -> String {
        let filename = encodeAttribute(image.filename)
        let alt = encodeAttribute(image.altText)
        return "<img data-clipman-image=\"1\" data-clipman-filename=\"\(filename)\" alt=\"\(alt)\" src=\"data:\(image.mimeType);base64,\(image.data.base64EncodedString())\">"
    }

    static func displayText(filename: String) -> String {
        "Image: \(filename)"
    }

    static func identityText(for image: EmbeddedImage) -> String {
        let hash = SHA256.hash(data: image.data).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(displayText(filename: image.filename)) (\(hash))"
    }

    private struct Inspection {
        let source: CGImageSource
        let typeIdentifier: CFString
        let mimeType: String
        let width: Int
        let height: Int
        let containsMetadata: Bool
        let metadata: [CFString: Any]?
    }

    private static func prepare(data: Data, suggestedFilename: String?) throws -> EmbeddedImage {
        let inspected = try inspect(data: data, maximumBytes: maximumInputBytes)
        let fileExtension = inspected.mimeType == "image/png" ? "png" : "jpg"
        let filename = try sanitizedFilename(
            suggestedFilename,
            fallback: "Clipboard image.\(fileExtension)",
            extension: fileExtension
        )
        let altText = displayText(filename: filename)

        if data.count <= maximumStoredBytes && max(inspected.width, inspected.height) <= preferredLongEdge {
            return EmbeddedImage(
                filename: filename,
                altText: altText,
                mimeType: inspected.mimeType,
                data: data,
                width: inspected.width,
                height: inspected.height,
                containsMetadata: inspected.containsMetadata
            )
        }

        guard let optimized = optimize(inspected) else { throw EmbeddedImageError.couldNotOptimize }
        guard optimized.data.count <= maximumStoredBytes else { throw EmbeddedImageError.storedImageTooLarge }
        return EmbeddedImage(
            filename: filename,
            altText: altText,
            mimeType: inspected.mimeType,
            data: optimized.data,
            width: optimized.width,
            height: optimized.height,
            containsMetadata: optimized.containsMetadata
        )
    }

    private static func inspect(data: Data, maximumBytes: Int) throws -> Inspection {
        guard data.count <= maximumBytes else { throw EmbeddedImageError.inputTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source),
              let type = UTType(sourceType as String) else {
            throw EmbeddedImageError.couldNotDecode
        }
        let mimeType: String
        if type.conforms(to: .png) {
            mimeType = "image/png"
        } else if type.conforms(to: .jpeg) {
            mimeType = "image/jpeg"
        } else {
            throw EmbeddedImageError.unsupportedFormat
        }
        guard CGImageSourceGetCount(source) == 1 else { throw EmbeddedImageError.animatedImage }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw EmbeddedImageError.couldNotDecode
        }
        guard width <= maximumInputDimension,
              height <= maximumInputDimension,
              Int64(width) * Int64(height) <= Int64(maximumPixelCount) else {
            throw EmbeddedImageError.dimensionsTooLarge
        }
        let metadata = boundedMetadata(properties)
        return Inspection(
            source: source,
            typeIdentifier: sourceType,
            mimeType: mimeType,
            width: width,
            height: height,
            containsMetadata: hasUsefulMetadata(properties),
            metadata: metadata
        )
    }

    private static func optimize(_ input: Inspection) -> (data: Data, width: Int, height: Int, containsMetadata: Bool)? {
        var longEdge = min(preferredLongEdge, max(input.width, input.height))
        let minimumLongEdge = 96
        while longEdge >= minimumLongEdge {
            guard let image = CGImageSourceCreateThumbnailAtIndex(input.source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longEdge,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { return nil }
            let qualities: [CGFloat] = input.mimeType == "image/jpeg" ? [0.88, 0.78, 0.68, 0.58, 0.48] : [1.0]
            for quality in qualities {
                if let encoded = encode(image: image, input: input, quality: quality), encoded.count <= maximumStoredBytes {
                    let inspected = try? inspect(data: encoded, maximumBytes: maximumStoredBytes)
                    return (encoded, image.width, image.height, inspected?.containsMetadata ?? false)
                }
            }
            longEdge = Int(Double(longEdge) * 0.78)
        }
        return nil
    }

    private static func encode(image: CGImage, input: Inspection, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, input.typeIdentifier, 1, nil) else { return nil }
        var properties = input.metadata ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        if input.mimeType == "image/jpeg" {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func boundedMetadata(_ properties: [CFString: Any]) -> [CFString: Any]? {
        if let data = try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0),
           data.count <= maximumMetadataBytes {
            return properties
        }
        var basic: [CFString: Any] = [:]
        for key in [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { basic[key] = value }
            if let data = try? PropertyListSerialization.data(fromPropertyList: basic, format: .binary, options: 0),
               data.count > maximumMetadataBytes {
                basic.removeValue(forKey: key)
            }
        }
        return basic.isEmpty ? nil : basic
    }

    private static func hasUsefulMetadata(_ properties: [CFString: Any]) -> Bool {
        [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
         kCGImagePropertyIPTCDictionary].contains { properties[$0] != nil }
    }

    private static func sanitizedFilename(_ suggested: String?, fallback: String, extension fileExtension: String) throws -> String {
        let raw = suggested ?? ""
        guard !hasMangledUnicode(raw) else { throw EmbeddedImageError.invalidWrapper }
        let lowerRaw = raw.lowercased()
        var value = lowerRaw.hasPrefix("content:") || lowerRaw.hasPrefix("ph:")
            || lowerRaw.hasPrefix("assets-library:") || lowerRaw.contains("://")
            ? ""
            : raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        value = canonicalFilenameText(value)
        if value.isEmpty { value = canonicalFilenameText(fallback) }
        let lower = value.lowercased()
        let suffix: String
        var stem: String
        if fileExtension == "jpg" {
            if lower.hasSuffix(".jpeg") {
                suffix = ".jpeg"
                stem = String(value.dropLast(5))
            } else if lower.hasSuffix(".jpg") {
                suffix = ".jpg"
                stem = String(value.dropLast(4))
            } else {
                suffix = ".jpg"
                stem = removingImageSuffix(value)
            }
        } else if lower.hasSuffix(".png") {
            suffix = ".png"
            stem = String(value.dropLast(4))
        } else {
            suffix = ".png"
            stem = removingImageSuffix(value)
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "Clipboard image" }
        let maximumStemScalars = 120 - suffix.unicodeScalars.count
        var clippedStem = ""
        clippedStem.unicodeScalars.append(contentsOf: stem.unicodeScalars.prefix(maximumStemScalars))
        clippedStem = clippedStem.trimmingCharacters(in: .whitespaces)
        if clippedStem.isEmpty { clippedStem = "Clipboard image" }
        return clippedStem + suffix
    }

    private static func isCanonicalFilename(_ value: String, mimeType: String) -> Bool {
        guard !value.isEmpty, !hasMangledUnicode(value) else { return false }
        let fileExtension = mimeType == "image/png" ? "png" : "jpg"
        let fallback = "Clipboard image.\(fileExtension)"
        return (try? sanitizedFilename(value, fallback: fallback, extension: fileExtension)) == value
    }

    private static func canonicalFilenameText(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if isUnicodeWhitespace(scalar) {
                if !result.isEmpty { pendingSpace = true }
                continue
            }
            if isDisallowedFilenameScalar(scalar) || scalar == "/" || scalar == "\\" || scalar == ":" {
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(scalar)
        }
        return String(result)
    }

    private static func removingImageSuffix(_ value: String) -> String {
        let lower = value.lowercased()
        for suffix in [".jpeg", ".jpg", ".png"] where lower.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
        return value
    }

    private static func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func isDisallowedFilenameScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            || scalar.properties.generalCategory == .format
            || scalar.properties.generalCategory == .surrogate
            || scalar.value == 0xfffd
            || isBidiControl(scalar)
    }

    private static func hasMangledUnicode(_ value: String) -> Bool {
        if value.unicodeScalars.contains(where: { $0.value == 0xfffd }) { return true }
        var pendingHighSurrogate = false
        for codeUnit in value.utf16 {
            if pendingHighSurrogate {
                guard (0xdc00...0xdfff).contains(codeUnit) else { return true }
                pendingHighSurrogate = false
            } else if (0xd800...0xdbff).contains(codeUnit) {
                pendingHighSurrogate = true
            } else if (0xdc00...0xdfff).contains(codeUnit) {
                return true
            }
        }
        return pendingHighSurrogate
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func encodeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func decodeAttribute(_ value: String) -> String {
        HTMLEntityDecoder.decode(value)
    }
}
