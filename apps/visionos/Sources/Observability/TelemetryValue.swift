import Foundation

/// A `Sendable`, JSON-encodable property value for telemetry events. Constraining event
/// properties to primitives keeps the whole event graph `Sendable` (Swift 6) and maps
/// cleanly onto PostHog's JSON `properties` object (ADR-0007).
enum TelemetryValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// The value boxed for `JSONSerialization` (`String`/`Int`/`Double`/`Bool` are all
    /// valid top-level JSON fragments).
    var jsonObject: Any {
        switch self {
        case let .string(value): value
        case let .int(value): value
        case let .double(value): value
        case let .bool(value): value
        }
    }
}
