import Foundation
import LocalAuthentication

/// Outcome of a device-owner check. `unavailable` is distinct from `failure`: it means
/// the platform offers no Optic ID / passcode to evaluate (Simulator, or a device with
/// nothing enrolled), and the gate treats it as a graceful pass rather than locking the
/// owner out of their own app (ADR-0008 "graceful fallback per platform").
enum LocalAuthOutcome: Equatable {
    case success
    /// The user failed or cancelled the check, or evaluation errored — stay locked.
    case failure(String)
    /// No biometric/passcode mechanism to evaluate — degrade to unlocked.
    case unavailable
}

/// The Optic ID seam (LocalAuthentication). Abstracted behind a protocol so the lock
/// state machine is driven without the framework in previews and on hosts where no
/// owner is enrolled, mirroring the `WebAuthenticating` seam used for OAuth.
protocol LocalAuthenticating: Sendable {
    func evaluate(reason: String) async -> LocalAuthOutcome
}

/// Production authenticator. Evaluates `.deviceOwnerAuthentication`, which prompts Optic
/// ID and falls back to the device passcode automatically — the owner gate ADR-0008 asks
/// for. A fresh `LAContext` per evaluation so a prior result is never reused.
struct OpticIDAuthenticator: LocalAuthenticating {
    func evaluate(reason: String) async -> LocalAuthOutcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failure("Optic ID could not verify you.")
        } catch let laError as LAError where laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
            return .failure("Authentication cancelled.")
        } catch {
            return .failure("Optic ID could not verify you.")
        }
    }
}
