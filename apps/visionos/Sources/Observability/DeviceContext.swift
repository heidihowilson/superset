import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stable, non-PII context attached to every event so PostHog can segment by **device
/// and model** (the §17 acceptance) with no user identifier.
///
/// `distinctID` is a random per-install UUID persisted in `UserDefaults` — it identifies
/// the headset install, not the person — and `device_model` is the hardware identifier
/// (e.g. `RealityDevice14,1`). No gaze, account, or location data is ever included (§13).
struct DeviceContext: Sendable {
    let distinctID: String
    let properties: [String: TelemetryValue]

    private static let distinctIDKey = "observability.distinct_id.v1"

    static func resolve(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> DeviceContext {
        var properties: [String: TelemetryValue] = [
            "device_model": .string(hardwareModel()),
        ]
        #if canImport(UIKit)
        properties["os_name"] = .string(UIDevice.current.systemName)
        properties["os_version"] = .string(UIDevice.current.systemVersion)
        #else
        properties["os_version"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
        #endif
        if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            properties["app_version"] = .string(version)
        }
        if let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            properties["app_build"] = .string(build)
        }
        return DeviceContext(distinctID: persistedDistinctID(defaults: defaults), properties: properties)
    }

    private static func persistedDistinctID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: distinctIDKey) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: distinctIDKey)
        return generated
    }

    /// Hardware model identifier. On the Simulator `uname` reports the host arch, so the
    /// simulated model from `SIMULATOR_MODEL_IDENTIFIER` is preferred when present.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
