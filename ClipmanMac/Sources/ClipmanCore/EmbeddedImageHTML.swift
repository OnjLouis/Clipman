import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public struct EmbeddedImageInfo: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public let filename: String
    public let altText: String
    public let width: Int
    public let height: Int
    public let contentIdentifier: String

    public init(data: Data, mimeType: String, filename: String, altText: String, width: Int, height: Int) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        self.altText = altText
        self.width = width
        self.height = height
        self.contentIdentifier = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum EmbeddedImageError: Equatable, Error, LocalizedError, Sendable {
    case unsupportedType
    case animatedImage
    case inputTooLarge
    case dimensionsTooLarge
    case invalidImage
    case cannotOptimize
    case storedImageTooLarge
    case wrapperTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedType: return "Only standalone PNG and JPEG images can be saved."
        case .animatedImage: return "Animated images cannot be saved in Rich Text history."
        case .inputTooLarge: return "The image is larger than the 16 MiB input limit."
        case .dimensionsTooLarge: return "The image exceeds the 16 megapixel or 4096-pixel dimension limit."
        case .invalidImage: return "The clipboard image could not be decoded safely."
        case .cannotOptimize: return "The image could not be reduced to Clipman's storage limits."
        case .storedImageTooLarge: return "The optimized image is larger than the 512 KiB per-image limit."
        case .wrapperTooLarge: return "The embedded image would exceed the Rich Text HTML limit."
        }
    }
}

public enum EmbeddedImageHTML {
    public static let maxInputBytes = 16 * 1024 * 1024
    public static let maxInputPixels = 16_000_000
    public static let maxInputDimension = 4096
    public static let maxStoredDimension = 2048
    public static let maxStoredBytes = 512 * 1024
    public static let maxHTMLBytes = 768 * 1024
    public static let totalBudgetBytes = 8 * 1024 * 1024
    public static let maxReencodedMetadataBytes = 64 * 1024

    public static func makePayload(data: Data, filename: String) throws -> (text: String, payload: RichTextPayload, info: EmbeddedImageInfo) {
        guard data.count <= maxInputBytes else { throw EmbeddedImageError.inputTooLarge }
        guard let source = createImageSource(data),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) as String?
        else {
            throw EmbeddedImageError.invalidImage
        }
        guard CGImageSourceGetCount(source) == 1 else { throw EmbeddedImageError.animatedImage }
        guard let mimeType = mimeType(for: sourceType) else { throw EmbeddedImageError.unsupportedType }
        let dimensions = try imageDimensions(source)
        try validateInputDimensions(width: dimensions.width, height: dimensions.height)

        let output: (data: Data, mimeType: String, width: Int, height: Int)
        if data.count <= maxStoredBytes,
           dimensions.width <= maxStoredDimension,
           dimensions.height <= maxStoredDimension {
            output = (data, mimeType, dimensions.width, dimensions.height)
        } else {
            output = try optimizedImage(source: source)
        }
        guard output.data.count <= maxStoredBytes else { throw EmbeddedImageError.storedImageTooLarge }

        let safeFilename = normalizedFilename(filename, mimeType: output.mimeType)
        let alt = "Image: \(safeFilename)"
        let info = EmbeddedImageInfo(
            data: output.data,
            mimeType: output.mimeType,
            filename: safeFilename,
            altText: alt,
            width: output.width,
            height: output.height
        )
        let html = canonicalHTML(for: info)
        guard html.utf8.count <= maxHTMLBytes else { throw EmbeddedImageError.wrapperTooLarge }
        let text = "Image: \(safeFilename) (\(String(info.contentIdentifier.prefix(12))))"
        return (
            text,
            RichTextPayload(Version: 1, HtmlFragment: html, RtfBase64: "", PreferredFormat: "Html"),
            info
        )
    }

    public static func pngData(fromTIFFTransport data: Data) throws -> Data {
        guard data.count <= maxInputBytes else { throw EmbeddedImageError.inputTooLarge }
        guard let source = createImageSource(data),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              sourceType.caseInsensitiveCompare("public.tiff") == .orderedSame
        else {
            throw EmbeddedImageError.unsupportedType
        }
        let dimensions = try imageDimensions(source)
        try validateInputDimensions(width: dimensions.width, height: dimensions.height)

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxInputDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw EmbeddedImageError.invalidImage
        }
        try validateInputDimensions(width: image.width, height: image.height)
        let propertyOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, propertyOptions) as? [CFString: Any]) ?? [:]
        for metadata in metadataCandidates(properties, width: image.width, height: image.height) {
            if let png = encode(image: image, mimeType: "image/png", quality: 1, metadata: metadata),
               png.count <= maxInputBytes {
                return png
            }
        }
        throw EmbeddedImageError.inputTooLarge
    }

    public static func imageInfo(from payload: RichTextPayload?) -> EmbeddedImageInfo? {
        guard let payload else { return nil }
        return imageInfo(fromHTML: payload.HtmlFragment)
    }

    public static func imageInfo(fromHTML html: String) -> EmbeddedImageInfo? {
        guard !html.isEmpty,
              html.utf8.count <= maxHTMLBytes,
              let regex = try? NSRegularExpression(
                pattern: #"^<img data-clipman-image=\"1\" data-clipman-filename=\"([^\"]*)\" alt=\"([^\"]*)\" src=\"data:image/(jpeg|png);base64,([A-Za-z0-9+/]*={0,2})\">$"#
              )
        else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.range == range,
              let filenameRange = Range(match.range(at: 1), in: html),
              let altRange = Range(match.range(at: 2), in: html),
              let subtypeRange = Range(match.range(at: 3), in: html),
              let dataRange = Range(match.range(at: 4), in: html),
              let data = Data(base64Encoded: String(html[dataRange]), options: []),
              data.count <= maxStoredBytes
        else {
            return nil
        }

        let parsedMimeType = "image/\(html[subtypeRange])"
        guard let source = createImageSource(data),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              mimeType(for: sourceType) == parsedMimeType,
              let dimensions = try? imageDimensions(source),
              dimensions.width <= maxStoredDimension,
              dimensions.height <= maxStoredDimension,
              dimensions.width * dimensions.height <= maxInputPixels
        else {
            return nil
        }
        let info = EmbeddedImageInfo(
            data: data,
            mimeType: parsedMimeType,
            filename: unescapeAttribute(String(html[filenameRange])),
            altText: unescapeAttribute(String(html[altRange])),
            width: dimensions.width,
            height: dimensions.height
        )
        guard info.filename == normalizedFilename(info.filename, mimeType: info.mimeType),
              info.altText == "Image: \(info.filename)",
              canonicalHTML(for: info) == html
        else {
            return nil
        }
        return info
    }

    public static func canonicalHTML(for info: EmbeddedImageInfo) -> String {
        let subtype = info.mimeType == "image/png" ? "png" : "jpeg"
        return "<img data-clipman-image=\"1\" data-clipman-filename=\"\(escapeAttribute(info.filename))\" alt=\"\(escapeAttribute(info.altText))\" src=\"data:image/\(subtype);base64,\(info.data.base64EncodedString())\">"
    }

    public static func validateInputDimensions(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width <= maxInputDimension,
              height <= maxInputDimension,
              width <= maxInputPixels / height
        else {
            throw EmbeddedImageError.dimensionsTooLarge
        }
    }

    private static func imageDimensions(_ source: CGImageSource) throws -> (width: Int, height: Int) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = integer(properties[kCGImagePropertyPixelWidth]),
              let height = integer(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0
        else {
            throw EmbeddedImageError.invalidImage
        }
        return (width, height)
    }

    private static func optimizedImage(source: CGImageSource) throws -> (data: Data, mimeType: String, width: Int, height: Int) {
        let originalProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        for dimension in [2048, 1792, 1536, 1280, 1024, 768, 512] {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                continue
            }
            let outputMime = imageHasAlpha(image) ? "image/png" : "image/jpeg"
            let qualities: [CGFloat] = outputMime == "image/jpeg" ? [0.86, 0.76, 0.66, 0.56, 0.46] : [1]
            for quality in qualities {
                for metadata in metadataCandidates(originalProperties, width: image.width, height: image.height) {
                    guard let encoded = encode(image: image, mimeType: outputMime, quality: quality, metadata: metadata) else {
                        continue
                    }
                    if encoded.count <= maxStoredBytes {
                        return (encoded, outputMime, image.width, image.height)
                    }
                }
            }
        }
        throw EmbeddedImageError.cannotOptimize
    }

    private static func encode(image: CGImage, mimeType: String, quality: CGFloat, metadata: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        let uti = mimeType == "image/png" ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        var properties = metadata
        if mimeType == "image/jpeg" {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func metadataCandidates(_ source: [CFString: Any], width: Int, height: Int) -> [[CFString: Any]] {
        var full = source
        full.removeValue(forKey: kCGImagePropertyOrientation)
        full[kCGImagePropertyPixelWidth] = width
        full[kCGImagePropertyPixelHeight] = height

        let retainedKeys: [CFString] = [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary
        ]
        var bounded: [CFString: Any] = [
            kCGImagePropertyPixelWidth: width,
            kCGImagePropertyPixelHeight: height
        ]
        for key in retainedKeys {
            if let value = source[key] {
                var candidate = bounded
                candidate[key] = value
                if serializedMetadataSize(candidate).map({ $0 <= maxReencodedMetadataBytes }) == true {
                    bounded = candidate
                }
            }
        }
        var candidates: [[CFString: Any]] = []
        if serializedMetadataSize(full).map({ $0 <= maxReencodedMetadataBytes }) == true {
            candidates.append(full)
        }
        if serializedMetadataSize(bounded).map({ $0 <= maxReencodedMetadataBytes }) == true {
            candidates.append(bounded)
        }
        candidates.append([:])
        return candidates
    }

    private static func serializedMetadataSize(_ metadata: [CFString: Any]) -> Int? {
        let propertyList = metadata.reduce(into: [String: Any]()) { result, pair in
            result[pair.key as String] = pair.value
        }
        guard PropertyListSerialization.propertyList(propertyList, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0)
        else {
            return nil
        }
        return data.count
    }

    private static func createImageSource(_ data: Data) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateWithData(data as CFData, options)
    }

    private static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    private static func mimeType(for sourceType: String) -> String? {
        switch sourceType.lowercased() {
        case "public.png": return "image/png"
        case "public.jpeg", "public.jpg": return "image/jpeg"
        default: return nil
        }
    }

    private static func normalizedFilename(_ value: String, mimeType: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if lower.hasPrefix("content:") {
            name = ""
        } else if lower.hasPrefix("file:"), let fileURL = URL(string: name), fileURL.isFileURL {
            name = fileURL.lastPathComponent
        } else if name.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            name = ""
        } else {
            name = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        }
        if let marker = name.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            name = String(name[..<marker])
        }
        name = canonicalFilenameText(name)
        if name.isEmpty { name = "Clipboard image" }
        let matchingSuffix = matchingImageSuffix(name, mimeType: mimeType)
        let suffix = matchingSuffix ?? (mimeType == "image/png" ? ".png" : ".jpg")
        var base: String
        if let matchingSuffix {
            base = String(name.dropLast(matchingSuffix.count))
        } else {
            base = removingImageSuffix(name)
        }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Clipboard image" }
        let maximumStemScalarCount = 120 - suffix.unicodeScalars.count
        if base.unicodeScalars.count > maximumStemScalarCount {
            base = String(base.unicodeScalars.prefix(maximumStemScalarCount))
                .trimmingCharacters(in: .whitespaces)
        }
        return "\(base)\(suffix)"
    }

    private static func canonicalFilenameText(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false

        for scalar in value.unicodeScalars {
            if isUnicodeWhitespace(scalar) {
                if !result.isEmpty {
                    pendingSpace = true
                }
                continue
            }
            if isForbiddenFilenameScalar(scalar) || scalar.value == 0x2F || scalar.value == 0x5C || scalar.value == 0x3A {
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

    private static func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func isForbiddenFilenameScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0xFFFD || isBidiControl(scalar.value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate:
            return true
        default:
            return false
        }
    }

    private static func isBidiControl(_ value: UInt32) -> Bool {
        value == 0x061C || value == 0x200E || value == 0x200F ||
            (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }

    private static func matchingImageSuffix(_ value: String, mimeType: String) -> String? {
        if mimeType == "image/png", value.lowercased().hasSuffix(".png") {
            return ".png"
        }
        if mimeType == "image/jpeg" {
            if value.lowercased().hasSuffix(".jpeg") {
                return ".jpeg"
            }
            if value.lowercased().hasSuffix(".jpg") {
                return ".jpg"
            }
        }
        return nil
    }

    private static func removingImageSuffix(_ value: String) -> String {
        let lower = value.lowercased()
        for suffix in [".jpeg", ".jpg", ".png"] where lower.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
        if let dot = value.lastIndex(of: "."), dot != value.startIndex {
            return String(value[..<dot])
        }
        return value
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func unescapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }
}
