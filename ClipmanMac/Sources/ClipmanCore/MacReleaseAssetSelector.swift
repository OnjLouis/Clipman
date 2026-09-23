public enum MacReleaseAssetSelector {
    public enum Architecture {
        case appleSilicon
        case intel

        public static var current: Self {
            #if arch(x86_64)
            return .intel
            #else
            return .appleSilicon
            #endif
        }

        public var machOName: String {
            switch self {
            case .appleSilicon: return "arm64"
            case .intel: return "x86_64"
            }
        }
    }

    public static func preferredName(in names: [String], version: String, architecture: Architecture) -> String? {
        let expectedName: String
        switch architecture {
        case .appleSilicon:
            expectedName = "Clipman-macOS-\(version).zip"
        case .intel:
            expectedName = "Clipman-macOS-Intel-\(version).zip"
        }
        return names.first { $0.caseInsensitiveCompare(expectedName) == .orderedSame }
    }
}
