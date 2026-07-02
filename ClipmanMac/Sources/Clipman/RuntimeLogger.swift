import AppKit
import Foundation

enum RuntimeLogger {
    static var logURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clipman", isDirectory: true)
        return support.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Runtime.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            RuntimeLogger.write("Uncaught AppKit exception.", details: exception.description)
        }
    }

    static func write(_ message: String, error: Error? = nil, details: String = "") {
        var lines: [String] = []
        lines.append("[\(timestamp())] \(message)")
        lines.append("App: \(Bundle.main.bundlePath)")
        lines.append("Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
        lines.append("Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Machine: \(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)")
        if let error {
            lines.append(String(describing: error))
        }
        if !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(details)
        }
        lines.append("")

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let text = lines.joined(separator: "\n") + "\n"
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = text.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try text.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Runtime logging must never make a crash worse.
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
