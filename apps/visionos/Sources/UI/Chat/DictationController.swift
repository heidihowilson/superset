import AVFoundation
import Foundation
import Observation
import Speech

/// On-device voice dictation for the composer (PRD §9), a co-equal input alongside the
/// keyboard. Streams partial `Speech` transcriptions into a callback the composer writes
/// to its reviewable draft — it never auto-sends (explicit send only, §9).
///
/// Privacy (§13): recognition prefers on-device when `supportsOnDeviceRecognition` is
/// true. When the recognizer can only fall back to Apple's *servers*, that is disclosed
/// via `usesServerRecognition` so the composer can warn (or the user can stay on the
/// keyboard). Authorization denial / unavailability degrade to a disabled mic, never a
/// crash.
///
/// `@MainActor` so all state and the audio-graph lifecycle live on one actor; the
/// recognition and audio-tap callbacks hop back to the main actor before touching state.
@MainActor
@Observable
final class DictationController {
    /// Whether dictation can run, and (when it can) whether it stays on-device.
    enum Availability: Equatable {
        /// Authorization not requested yet.
        case unknown
        /// Ready to dictate; `onDevice` is false when recognition would use Apple servers.
        case ready(onDevice: Bool)
        /// The user denied microphone or speech permission.
        case denied
        /// No recognizer for the locale, or the device can't recognize speech.
        case unavailable
    }

    enum State: Equatable {
        case idle
        case listening
    }

    private(set) var availability: Availability = .unknown
    private(set) var state: State = .idle

    /// Partial + final transcriptions, delivered on the main actor. The composer assigns
    /// these to its draft so the user reviews/edits before sending.
    var onTranscript: (@MainActor (String) -> Void)?

    /// True only while a live session is recognizing on Apple's servers rather than
    /// on-device — the trigger for the composer's privacy disclosure (§13).
    var usesServerRecognition: Bool {
        if case .ready(let onDevice) = availability { return !onDevice }
        return false
    }

    var isReady: Bool {
        if case .ready = availability { return true }
        return false
    }

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Request microphone + speech-recognition authorization and resolve `availability`.
    /// Idempotent and safe to call before each dictation start.
    func requestAuthorization() async {
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            availability = speechStatus == .denied || speechStatus == .restricted ? .denied : .unavailable
            return
        }

        let micGranted = await Self.requestRecordPermission()
        guard micGranted else {
            availability = .denied
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            availability = .unavailable
            return
        }
        availability = .ready(onDevice: recognizer.supportsOnDeviceRecognition)
    }

    /// Bridges to the TCC authorization callbacks, which fire on an arbitrary background
    /// queue. These are `nonisolated static` so their completion closures do NOT inherit
    /// the type's `@MainActor` isolation — otherwise Swift's executor-isolation assertion
    /// traps when TCC resumes them off the main actor. The continuation is safe to resume
    /// from any queue; `availability` is assigned back on the main actor after the `await`.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    /// Begin a live recognition session, configuring the audio graph and forcing
    /// on-device recognition when supported. Throws if the audio session or graph can't
    /// start; the caller leaves the mic visually off.
    func start() throws {
        guard let recognizer, state == .idle else { return }
        stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let finished = error != nil || (result?.isFinal ?? false)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let transcript {
                        self.onTranscript?(transcript)
                    }
                    if finished {
                        self.stop()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
        } catch {
            stop()
            throw error
        }
    }

    /// Tear down the live session. Safe to call repeatedly and when already idle.
    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
    }
}
