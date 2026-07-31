import SwiftUI
import UIKit

struct ServerConnectionShareFile: Identifiable {
    let id = UUID()
    let url: URL
    let directory: URL

    static func create(data: Data) throws -> ServerConnectionShareFile {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ClipmanConnectionShare", isDirectory: true)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Clipman Server.clpconf", isDirectory: false)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return ServerConnectionShareFile(url: url, directory: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct ConnectionShareSheet: UIViewControllerRepresentable {
    let file: ServerConnectionShareFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
