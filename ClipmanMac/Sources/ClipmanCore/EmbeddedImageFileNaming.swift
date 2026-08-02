import Foundation

public enum EmbeddedImageFileNaming {
    public static func suggestedFilename(
        capturedUnixMs: Int64,
        device: String,
        mimeType: String,
        timeZone: TimeZone = .current
    ) -> String {
        let capturedDate = capturedUnixMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(capturedUnixMs) / 1_000)
            : Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        let safeDevice = sanitizedComponent(device, maximumLength: 64)
        let deviceSuffix = safeDevice.isEmpty ? "" : " - \(safeDevice)"
        let fileExtension = mimeType.caseInsensitiveCompare("image/png") == .orderedSame ? "png" : "jpg"
        return "Clipman image \(formatter.string(from: capturedDate))\(deviceSuffix).\(fileExtension)"
    }

    private static func sanitizedComponent(_ value: String, maximumLength: Int) -> String {
        let excluded = CharacterSet.controlCharacters
            .union(.illegalCharacters)
            .union(CharacterSet(charactersIn: "/:\\\"<>|?*"))
        let cleaned = value.unicodeScalars.map {
            excluded.contains($0) || $0.properties.generalCategory == .format ? " " : String($0)
        }
        .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(cleaned.prefix(maximumLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}
