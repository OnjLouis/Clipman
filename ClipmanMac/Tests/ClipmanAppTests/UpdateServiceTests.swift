import Foundation
import MachO
import XCTest
import ClipmanCore
@testable import Clipman

final class UpdateServiceTests: XCTestCase {
    @MainActor func testInstallerReplacesAppAndCleansStaging() throws {
        try exerciseInstaller(failure: nil)
    }

    @MainActor func testInstallerRestoresPreviousAppAfterReplacementFailure() throws {
        try exerciseInstaller(failure: "/bin/mv \"$incoming\" \"$target\"")
    }

    @MainActor func testInstallerKeepsPreviousAppAfterCopyFailure() throws {
        try exerciseInstaller(failure: "/usr/bin/ditto")
    }

    @MainActor private func exerciseInstaller(failure: String?) throws {
        let temporary = ProcessInfo.processInfo.environment["CLIPMAN_TEST_TEMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("ClipmanUpdateTests-\(UUID().uuidString)").appendingPathComponent("Owner's update")
        let target = root.appendingPathComponent("Applications/Clipman.app")
        let staging = root.appendingPathComponent("staging")
        let source = staging.appendingPathComponent("extract/Clipman.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for folder in [target, source] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("previous app".utf8).write(to: target.appendingPathComponent("marker"))
        try Data("new app".utf8).write(to: source.appendingPathComponent("marker"))
        let settings = root.appendingPathComponent("settings-sentinel")
        try Data("retained settings".utf8).write(to: settings)
        var script = UpdateService().installationScript(stagedApp: source, targetApp: target, staging: staging, processID: 0, relaunch: false)
        if failure == "/usr/bin/ditto" {
            try FileManager.default.removeItem(at: source)
        } else if let failure {
            XCTAssertTrue(script.contains(failure))
            script = script.replacingOccurrences(of: failure, with: "/usr/bin/false")
        }
        let scriptURL = root.appendingPathComponent("install.zsh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus == 0, failure == nil)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8), failure == nil ? "new app" : "previous app")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "retained settings")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["Clipman.app"], "Temporary replacement or rollback app was left behind.")
        XCTAssertEqual(FileManager.default.fileExists(atPath: staging.path), failure != nil)
        if failure != nil { XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("install.log").path)) }
    }

    @MainActor func testSignedPackagesValidateWithoutDeveloperTools() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let applePath = environment["CLIPMAN_UPDATE_APPLE_FIXTURE"],
              let intelPath = environment["CLIPMAN_UPDATE_INTEL_FIXTURE"] else {
            throw XCTSkip("Provide both signed release app fixtures for the package integration test.")
        }
        let previous = environment["DEVELOPER_DIR"]
        setenv("DEVELOPER_DIR", "/nonexistent-clipman-developer-tools", 1)
        defer {
            if let previous { setenv("DEVELOPER_DIR", previous, 1) }
            else { unsetenv("DEVELOPER_DIR") }
        }
        for (path, architecture) in [(applePath, MacReleaseAssetSelector.Architecture.appleSilicon), (intelPath, .intel)] {
            let app = URL(fileURLWithPath: path)
            let info = app.appendingPathComponent("Contents/Info.plist")
            let original = try Data(contentsOf: info)
            XCTAssertNoThrow(try UpdateService().validateUpdate(of: app, architecture: architecture))
            let other: MacReleaseAssetSelector.Architecture = architecture == .appleSilicon ? .intel : .appleSilicon
            XCTAssertThrowsError(try UpdateService().validateUpdate(of: app, architecture: other))
            XCTAssertEqual(try Data(contentsOf: info), original)
        }
        let tampered = try makeApp(architectures: [.appleSilicon])
        defer { try? FileManager.default.removeItem(at: tampered.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: tampered)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: applePath), to: tampered)
        let info = tampered.appendingPathComponent("Contents/Info.plist")
        var data = try Data(contentsOf: info)
        data.append(contentsOf: "\n".utf8)
        try data.write(to: info)
        XCTAssertThrowsError(try UpdateService().validateUpdate(of: tampered, architecture: .appleSilicon))
    }

    @MainActor func testValidationRejectsUnsignedAppsEvenWithMatchingArchitecture() throws {
        let fixture = try makeApp(architectures: [.appleSilicon])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        XCTAssertNoThrow(try UpdateService().verifyArchitecture(of: fixture, architecture: .appleSilicon))
        XCTAssertThrowsError(try UpdateService().validateUpdate(of: fixture, architecture: .appleSilicon))
    }

    @MainActor func testArchitectureValidationDoesNotRequireDeveloperTools() throws {
        let previous = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        setenv("DEVELOPER_DIR", "/nonexistent-clipman-developer-tools", 1)
        defer {
            if let previous { setenv("DEVELOPER_DIR", previous, 1) }
            else { unsetenv("DEVELOPER_DIR") }
        }
        for architecture in [MacReleaseAssetSelector.Architecture.appleSilicon, .intel] {
            let fixture = try makeApp(architectures: [architecture])
            defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
            XCTAssertNoThrow(try UpdateService().verifyArchitecture(of: fixture, architecture: architecture))
        }
    }

    @MainActor func testArchitectureValidationRejectsTheOtherArchitecture() throws {
        for architecture in [MacReleaseAssetSelector.Architecture.appleSilicon, .intel] {
            let other: MacReleaseAssetSelector.Architecture = architecture == .appleSilicon ? .intel : .appleSilicon
            let fixture = try makeApp(architectures: [other])
            defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
            XCTAssertThrowsError(try UpdateService().verifyArchitecture(of: fixture, architecture: architecture))
        }
    }

    @MainActor func testArchitectureValidationAcceptsUniversalApps() throws {
        let fixture = try makeApp(architectures: [.appleSilicon, .intel])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        for architecture in [MacReleaseAssetSelector.Architecture.appleSilicon, .intel] {
            XCTAssertNoThrow(try UpdateService().verifyArchitecture(of: fixture, architecture: architecture))
        }
    }

    @MainActor func testArchitectureValidationRejectsMissingOrMalformedExecutables() throws {
        let fixture = try makeApp(architectures: [.appleSilicon])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let executable = fixture.appendingPathComponent("Contents/MacOS/Clipman")
        try Data("not a Mach-O executable".utf8).write(to: executable)
        XCTAssertThrowsError(try UpdateService().verifyArchitecture(of: fixture, architecture: .appleSilicon))
        try FileManager.default.removeItem(at: executable)
        XCTAssertThrowsError(try UpdateService().verifyArchitecture(of: fixture, architecture: .appleSilicon))
    }

    private func makeApp(architectures: [MacReleaseAssetSelector.Architecture]) throws -> URL {
        let temporary = ProcessInfo.processInfo.environment["CLIPMAN_TEST_TEMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("ClipmanUpdateTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Clipman.app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "Clipman", "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "me.example.clipman.fixture.\(UUID().uuidString)"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        func cpu(_ architecture: MacReleaseAssetSelector.Architecture) -> UInt32 {
            UInt32(architecture == .appleSilicon ? NSBundleExecutableArchitectureARM64 : NSBundleExecutableArchitectureX86_64)
        }
        func header(_ architecture: MacReleaseAssetSelector.Architecture) -> Data {
            var data = Data()
            for value: UInt32 in [MH_MAGIC_64, cpu(architecture), architecture == .intel ? UInt32(CPU_SUBTYPE_X86_64_ALL) : UInt32(CPU_SUBTYPE_ARM64_ALL), UInt32(MH_EXECUTE), 0, 0, 0, 0] {
                var word = value.littleEndian
                withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
            }
            return data
        }
        var binary = Data()
        if architectures.count == 1 {
            binary = header(architectures[0])
        } else {
            // A standard fat header followed by two aligned thin Mach-O headers.
            let alignmentPower: UInt32 = 12
            let alignment: UInt32 = 1 << alignmentPower
            var words: [UInt32] = [FAT_MAGIC, UInt32(architectures.count)]
            for (index, architecture) in architectures.enumerated() {
                let subtype = architecture == .intel ? UInt32(CPU_SUBTYPE_X86_64_ALL) : UInt32(CPU_SUBTYPE_ARM64_ALL)
                words += [cpu(architecture), subtype, alignment * UInt32(index + 1), UInt32(MemoryLayout<mach_header_64>.size), alignmentPower]
            }
            for value in words {
                var word = value.bigEndian
                withUnsafeBytes(of: &word) { binary.append(contentsOf: $0) }
            }
            for (index, architecture) in architectures.enumerated() {
                binary.append(Data(count: Int(alignment) * (index + 1) - binary.count))
                binary.append(header(architecture))
            }
        }
        try binary.write(to: executables.appendingPathComponent("Clipman"))
        return app
    }
}
