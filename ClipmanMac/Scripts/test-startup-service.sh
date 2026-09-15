#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-${CLIPMAN_TEMP_ROOT:-$HOME/Projects/Codex/Temp/clipman}/startup-service-smoke}"
HARNESS="$SCRATCH/main.swift"
BINARY="$SCRATCH/startup-service-smoke"

case "$SCRATCH" in
  "$HOME"/Projects/Codex/Temp/clipman/*) ;;
  *)
    echo "Startup smoke scratch must be inside ~/Projects/Codex/Temp/clipman." >&2
    exit 1
    ;;
esac

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

cat > "$HARNESS" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Startup smoke requires one scratch path.\n".utf8))
    exit(1)
}
let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let launchAgents = scratch.appendingPathComponent("LaunchAgents", isDirectory: true)
let appURL = scratch.appendingPathComponent("Clipman.app", isDirectory: true)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("Startup smoke failed: \(message)\n".utf8))
        exit(1)
    }
}

defer { try? fileManager.removeItem(at: scratch) }
try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)

var commands: [[String]] = []
let service = StartupService(
    fileManager: fileManager,
    launchAgentsDirectory: launchAgents,
    launchctlRunner: { arguments in
        commands.append(arguments)
        return true
    }
)

try service.setEnabled(false, appBundleURL: appURL)
require(commands.isEmpty, "disabling an absent registration invoked launchctl")

try service.setEnabled(true, appBundleURL: appURL)
require(commands.count == 1 && commands[0].first == "bootstrap", "first registration did not bootstrap directly")
require(service.isEnabled(), "first registration did not create its property list")

commands.removeAll()
try service.setEnabled(true, appBundleURL: appURL)
require(commands.map(\.first) == ["bootout", "bootstrap"], "replacing a registration used the wrong launchctl sequence")

commands.removeAll()
try service.setEnabled(false, appBundleURL: appURL)
require(commands.count == 1 && commands[0].first == "bootout", "disabling an existing registration did not boot it out")
require(!service.isEnabled(), "disabling an existing registration did not remove its property list")

var failedBootstrapWasReported = false
let failingService = StartupService(
    fileManager: fileManager,
    launchAgentsDirectory: launchAgents,
    launchctlRunner: { _ in false }
)
do {
    try failingService.setEnabled(true, appBundleURL: appURL)
} catch {
    failedBootstrapWasReported = true
}
require(failedBootstrapWasReported, "a failed bootstrap was silently accepted")

print("Startup service smoke passed")
SWIFT

swiftc "$ROOT/Sources/Clipman/StartupService.swift" "$HARNESS" -o "$BINARY"
"$BINARY" "$SCRATCH/runtime"
