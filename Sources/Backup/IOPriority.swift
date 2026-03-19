import Foundation
import IOKit
import IOKit.ps

enum IOPriority {
    // From sys/resource.h
    private static let IOPOL_TYPE_DISK: Int32 = 1
    private static let IOPOL_SCOPE_PROCESS: Int32 = 0
    private static let IOPOL_DEFAULT: Int32 = 0
    private static let IOPOL_THROTTLE: Int32 = 3

    /// Set disk I/O priority. Throttle on battery for system responsiveness.
    static func setIOPriority(throttle: Bool) {
        let policy = throttle ? IOPOL_THROTTLE : IOPOL_DEFAULT
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, policy)
    }

    /// Detect if running on battery power. Returns false on desktop Macs or when undeterminable.
    static func isOnBattery() -> Bool {
        guard let psInfoRaw = IOPSCopyPowerSourcesInfo() else { return false }
        let psInfo = psInfoRaw.takeRetainedValue()

        guard let listRaw = IOPSCopyPowerSourcesList(psInfo) else { return false }
        let sources = listRaw.takeRetainedValue() as [AnyObject]
        guard !sources.isEmpty else { return false }

        for source in sources {
            guard let descRaw = IOPSGetPowerSourceDescription(psInfo, source as CFTypeRef) else { continue }
            let desc = descRaw.takeUnretainedValue() as? [String: Any]
            if let state = desc?[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }
}
