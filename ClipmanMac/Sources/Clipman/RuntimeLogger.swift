import AppKit
import Foundation

enum RuntimeLogger {
    private static let debugStartUptime = ProcessInfo.processInfo.systemUptime
    private static let debugLock = NSLock()

    static let debugLoggingEnabled: Bool = {
        guard let value = ProcessInfo.processInfo.environment["CLIPMAN_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }()

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
        debug("Console debug logging enabled.")
    }

    static func debug(_ message: String, details: String = "") {
        guard debugLoggingEnabled else { return }

        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - debugStartUptime)
        var line = "[\(timestamp())] [debug +\(String(format: "%.3f", elapsed))s] \(singleLine(message))"
        let safeDetails = singleLine(details)
        if !safeDetails.isEmpty {
            line += " | \(safeDetails)"
        }
        line += "\n"

        debugLock.lock()
        defer { debugLock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func write(_ message: String, error: Error? = nil, details: String = "") {
        var lines: [String] = []
        lines.append("[\(timestamp())] \(message)")
        lines.append("App: \(Bundle.main.bundlePath)")
        lines.append("Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
        lines.append("Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        lines.append("Build stamp: \(Bundle.main.object(forInfoDictionaryKey: "ClipmanBuildStampUtcMs") as? String ?? "unknown")")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Device: \(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)")
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

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
