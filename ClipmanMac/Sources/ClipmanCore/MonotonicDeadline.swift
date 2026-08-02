import Dispatch
import Foundation

package struct MonotonicDeadline: Sendable {
    private let endUptimeNanoseconds: UInt64

    package init(timeoutSeconds: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let clampedSeconds = max(0, timeoutSeconds)
        let nanoseconds = min(clampedSeconds * 1_000_000_000, Double(UInt64.max))
        let delta = UInt64(nanoseconds.rounded(.up))
        let (end, overflow) = now.addingReportingOverflow(delta)
        endUptimeNanoseconds = overflow ? UInt64.max : end
    }

    package var isExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= endUptimeNanoseconds
    }

    package var dispatchTime: DispatchTime {
        DispatchTime(uptimeNanoseconds: endUptimeNanoseconds)
    }
}
