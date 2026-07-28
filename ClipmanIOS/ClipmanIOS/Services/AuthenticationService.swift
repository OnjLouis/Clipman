import Foundation
import LocalAuthentication

enum AuthenticationService {
    static func unlock(reason: String = "Unlock Clipman clipboard history.") async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
        #endif
    }
}
