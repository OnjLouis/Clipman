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
        names.first { $0.caseInsensitiveCompare(expectedName(version: version, architecture: architecture)) == .orderedSame }
    }

    @MainActor
    public static func preferredAsset<Asset>(
        in embedded: [Asset],
        name: KeyPath<Asset, String>,
        version: String,
        architecture: Architecture,
        fetch: @MainActor () async throws -> [Asset]
    ) async throws -> Asset? {
        let expected = expectedName(version: version, architecture: architecture)
        if let asset = embedded.first(where: { $0[keyPath: name].caseInsensitiveCompare(expected) == .orderedSame }) {
            return asset
        }
        return try await fetch().first { $0[keyPath: name].caseInsensitiveCompare(expected) == .orderedSame }
    }

    private static func expectedName(version: String, architecture: Architecture) -> String {
        switch architecture {
        case .appleSilicon:
            return "Clipman-macOS-\(version).zip"
        case .intel:
            return "Clipman-macOS-Intel-\(version).zip"
        }
    }
}
