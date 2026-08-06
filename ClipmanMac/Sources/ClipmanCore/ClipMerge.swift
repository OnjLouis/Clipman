import Foundation

public enum ClipMergeKind: Sendable {
    case text
    case files
}

public struct ClipMergeObservation: Sendable {
    public var kind: ClipMergeKind
    public var signature: String
    public var sourceApplication: String
    public var operation: String
    public var historyID: String
    public var changeIdentifier: Int
    public var values: [String]

    public init(kind: ClipMergeKind, signature: String, sourceApplication: String, operation: String = "", historyID: String = "", changeIdentifier: Int = 0, values: [String]) {
        self.kind = kind
        self.signature = signature
        self.sourceApplication = sourceApplication
        self.operation = operation
        self.historyID = historyID
        self.changeIdentifier = changeIdentifier
        self.values = values
    }
}

public struct ClipMergeDecision: Sendable {
    public var base: ClipMergeObservation?
    public var firstTap: ClipMergeObservation?
    public var suppressDuplicate = false
    public var shouldMerge: Bool { base != nil && firstTap != nil }
}

public struct ClipMergeDetector: Sendable {
    public static let defaultWindowMilliseconds = 500
    public static let minimumWindowMilliseconds = 200
    public static let maximumWindowMilliseconds = 2000
    public static let duplicateNotificationMilliseconds: Int64 = 60
    public static let mozillaDuplicateNotificationMilliseconds: Int64 = 500

    private var current: ClipMergeObservation?
    private var candidateBase: ClipMergeObservation?
    private var candidateFirstTap: ClipMergeObservation?
    private var candidateStartedMilliseconds: Int64 = 0

    public init() {}

    public mutating func observe(_ incoming: ClipMergeObservation, nowMilliseconds: Int64, enabled: Bool, windowMilliseconds: Int, deliberate: Bool) -> ClipMergeDecision {
        let window = Self.normalizeWindow(windowMilliseconds)
        guard enabled, !deliberate, !incoming.sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            candidateBase = nil
            candidateFirstTap = nil
            current = incoming
            return ClipMergeDecision()
        }
        let elapsed = nowMilliseconds - candidateStartedMilliseconds
        if let first = candidateFirstTap, sameTap(first, incoming),
           isDuplicateNotification(first, incoming, elapsed: elapsed) {
            candidateStartedMilliseconds = nowMilliseconds
            return ClipMergeDecision(suppressDuplicate: true)
        }
        if let first = candidateFirstTap, let base = candidateBase,
           elapsed >= 0, elapsed <= Int64(window), sameTap(first, incoming), compatible(base, incoming) {
            candidateBase = nil
            candidateFirstTap = nil
            return ClipMergeDecision(base: base, firstTap: first)
        }
        candidateBase = current
        candidateFirstTap = incoming
        candidateStartedMilliseconds = nowMilliseconds
        current = incoming
        return ClipMergeDecision()
    }

    public mutating func setCurrentHistoryID(_ historyID: String, matching signature: String) {
        if current?.signature == signature {
            current?.historyID = historyID
        }
        if candidateFirstTap?.signature == signature {
            candidateFirstTap?.historyID = historyID
        }
    }

    public mutating func completeMerge(_ merged: ClipMergeObservation, historyID: String) {
        var value = merged
        value.historyID = historyID
        current = value
        candidateBase = nil
        candidateFirstTap = nil
    }

    public mutating func retainFirstTap(_ firstTap: ClipMergeObservation) {
        current = firstTap
        candidateBase = nil
        candidateFirstTap = nil
    }

    public mutating func reset() {
        current = nil
        candidateBase = nil
        candidateFirstTap = nil
        candidateStartedMilliseconds = 0
    }

    public static func normalizeWindow(_ value: Int) -> Int {
        min(maximumWindowMilliseconds, max(minimumWindowMilliseconds, value))
    }

    public static func separator(mode: String, custom: String) -> String {
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "blankline": return "\n\n"
        case "space": return " "
        case "commaspace": return ", "
        case "custom":
            return custom
                .replacingOccurrences(of: "\\r\\n", with: "\r\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
        default: return "\n"
        }
    }

    private func sameTap(_ left: ClipMergeObservation, _ right: ClipMergeObservation) -> Bool {
        left.kind == right.kind && left.signature == right.signature &&
            left.sourceApplication.caseInsensitiveCompare(right.sourceApplication) == .orderedSame &&
            left.operation.caseInsensitiveCompare(right.operation) == .orderedSame
    }

    private func isDuplicateNotification(_ left: ClipMergeObservation, _ right: ClipMergeObservation, elapsed: Int64) -> Bool {
        if left.changeIdentifier != 0, right.changeIdentifier != 0 {
            if left.changeIdentifier == right.changeIdentifier { return true }
            return isMozillaApplication(left.sourceApplication) && elapsed >= 0 && elapsed < Self.mozillaDuplicateNotificationMilliseconds
        }
        let threshold = isMozillaApplication(left.sourceApplication)
            ? Self.mozillaDuplicateNotificationMilliseconds
            : Self.duplicateNotificationMilliseconds
        return elapsed >= 0 && elapsed < threshold
    }

    private func isMozillaApplication(_ value: String) -> Bool {
        let source = value.lowercased()
        return source.contains("firefox") || source.contains("thunderbird")
    }

    private func compatible(_ base: ClipMergeObservation, _ incoming: ClipMergeObservation) -> Bool {
        base.kind == incoming.kind && base.signature != incoming.signature &&
            (incoming.kind != .files || base.operation.caseInsensitiveCompare(incoming.operation) == .orderedSame)
    }
}

public enum ClipMergeFilePolicy {
    public static func sourcesAreAvailable(_ paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { path in
            let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return !clean.isEmpty && FileManager.default.fileExists(atPath: clean)
        }
    }
}
