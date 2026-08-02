import Foundation

package enum ServerHTTPResponsePolicy {
    package static func expectsBody(forMethod method: String) -> Bool {
        method.caseInsensitiveCompare("HEAD") != .orderedSame
    }
}
