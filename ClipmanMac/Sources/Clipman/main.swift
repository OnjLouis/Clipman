import AppKit

RuntimeLogger.install()
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
RuntimeLogger.debug(
    "Process entry reached.",
    details: "pid=\(ProcessInfo.processInfo.processIdentifier) version=\(version) build=\(build)"
)
let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
RuntimeLogger.debug("Entering the AppKit event loop.")
app.run()
RuntimeLogger.debug("AppKit event loop returned.")
