import Foundation
import Darwin

enum FileRestoreAccess {
    static func readablePaths(_ paths: [String]) throws -> [String] {
        var readable: [String] = []
        var seen = Set<String>()
        // Attempt access before filtering: existence checks may hide files awaiting macOS volume permission.
        for path in paths {
            guard seen.insert(path).inserted else { continue }
            do {
                try check(path)
                readable.append(path)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR)) {
                continue
            }
        }
        return readable
    }

    private static func check(_ path: String) throws {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw accessError(path) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw accessError(path) }
        if metadata.st_mode & S_IFMT == S_IFREG {
            // Request a minimal read without loading whole files or blocking on special file types.
            var byte: UInt8 = 0
            guard Darwin.read(descriptor, &byte, 1) >= 0 else { throw accessError(path) }
        } else if metadata.st_mode & S_IFMT == S_IFDIR {
            guard let directory = Darwin.opendir(path) else { throw accessError(path) }
            defer { Darwin.closedir(directory) }
            errno = 0
            if Darwin.readdir(directory) == nil, errno != 0 { throw accessError(path) }
        }
    }

    private static func accessError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
