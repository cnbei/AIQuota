import Foundation
import IOKit.ps

enum TokenStepPowerSource: Equatable {
    case ac
    case battery
}

enum EnergyRefreshPolicy {
    static let acBackgroundFloorSeconds = 15 * 60
    static let batteryBackgroundFloorSeconds = 30 * 60
    static let quotaTTL: TimeInterval = 15 * 60
    static let rankTTL: TimeInterval = 30 * 60
    static let usageSyncTTL: TimeInterval = 20 * 60
    static let minimumAutomaticRetryTTL: TimeInterval = 60
    static let maximumForegroundTickSeconds = 60
    static let acSourceChangeFloorSeconds = 15
    static let batterySourceChangeFloorSeconds = 30

    static func backgroundInterval(
        requestedSeconds: Int,
        powerSource: TokenStepPowerSource,
        lowPowerMode: Bool
    ) -> Int? {
        guard requestedSeconds > 0 else { return nil }
        let floor = powerSource == .battery || lowPowerMode
            ? batteryBackgroundFloorSeconds
            : acBackgroundFloorSeconds
        return max(requestedSeconds, floor)
    }

    static func shouldRefreshForForeground(
        generatedAt: Date?,
        requestedSeconds: Int,
        now: Date
    ) -> Bool {
        guard requestedSeconds > 0 else { return false }
        guard let generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) >= TimeInterval(requestedSeconds)
    }

    static func isFresh(lastAttemptAt: Date?, ttl: TimeInterval, now: Date) -> Bool {
        guard let lastAttemptAt else { return false }
        return now.timeIntervalSince(lastAttemptAt) < ttl
    }

    static func automaticRetryTTL(requestedSeconds: Int) -> TimeInterval {
        max(minimumAutomaticRetryTTL, TimeInterval(max(0, requestedSeconds)))
    }

    static func foregroundTickInterval(requestedSeconds: Int) -> Int? {
        guard requestedSeconds > 0 else { return nil }
        return min(requestedSeconds, maximumForegroundTickSeconds)
    }

    static func sourceChangeFloorSeconds(
        powerSource: TokenStepPowerSource,
        lowPowerMode: Bool
    ) -> Int {
        powerSource == .battery || lowPowerMode
            ? batterySourceChangeFloorSeconds
            : acSourceChangeFloorSeconds
    }

    static func shouldRefreshForSourceChange(
        lastAttemptAt: Date?,
        powerSource: TokenStepPowerSource,
        lowPowerMode: Bool,
        now: Date
    ) -> Bool {
        sourceChangeRetryDelay(
            lastAttemptAt: lastAttemptAt,
            powerSource: powerSource,
            lowPowerMode: lowPowerMode,
            now: now
        ) == nil
    }

    static func sourceChangeRetryDelay(
        lastAttemptAt: Date?,
        powerSource: TokenStepPowerSource,
        lowPowerMode: Bool,
        now: Date
    ) -> TimeInterval? {
        guard let lastAttemptAt else { return nil }
        let remaining = TimeInterval(
            sourceChangeFloorSeconds(
                powerSource: powerSource,
                lowPowerMode: lowPowerMode
            )
        ) - now.timeIntervalSince(lastAttemptAt)
        return remaining > 0 ? remaining : nil
    }
}

enum TokenStepPowerState {
    static var source: TokenStepPowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let raw = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return .ac
        }
        return raw == kIOPSBatteryPowerValue ? .battery : .ac
    }

    static var lowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
