import AppKit

RuntimeLogger.install()
let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.run()
