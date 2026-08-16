import AVFoundation

/// Device-local pronunciation — the stand-in for Voca audio when Voca cannot produce any.
///
/// Voca 2.0 removed client-supplied TTS credentials (`POST /v1/audio/{id}` takes only
/// `{text?, voiceModel?}`), so a Voca server with no TTS provider answers every generate with
/// `503 TTS_NOT_CONFIGURED`. `AVSpeechSynthesizer` fills that hole: free, offline, no
/// configuration — and lower quality than edge-tts, which is why Voca stays the preferred
/// source (see `VocaAudioSource` / `VocaService.playCardAudio`).
///
/// Two things about this API are easy to get wrong and are handled here on purpose:
///
/// - **the synthesizer has to outlive the call.** A locally-scoped `AVSpeechSynthesizer` is
///   deallocated the moment the function returns and the speech stops mid-word, so the single
///   instance is owned by `shared` for the life of the process.
/// - **completion arrives through a delegate**, bridged to `async` with a `CheckedContinuation`
///   — which traps on a double resume and hangs the caller on a missed one. Every resume goes
///   through code that *takes* the continuation out under `lock` and matches on utterance
///   identity, so exactly one path can ever resume a given call: `didFinish`, `didCancel`, a
///   newer utterance superseding it, or task cancellation.
///
/// AUDIO SESSION: this type never calls `AVAudioSession.setCategory` / `setActive`.
/// `AudioSessionCoordinator` is the single owner of the shared session, and `speak` refuses
/// outright while its mode is `.liveVoice` — see the policy note on `speak(_:language:)`.
/// `AVSpeechSynthesizer.usesApplicationAudioSession` is left at its default (`true`) for the
/// same reason: flipping it would hand the synthesizer a private session of its own, i.e.
/// exactly the behind-the-coordinator's-back coupling the coordinator exists to prevent.
final class DeviceSpeech: NSObject {
    static let shared = DeviceSpeech()

    /// *** The retained synthesizer. *** Never make a local one — see the type doc.
    private let synthesizer = AVSpeechSynthesizer()

    /// One `speak` call. The continuation is *taken* out of here under `lock` by whichever
    /// path answers first, so every other path finds `nil` and does nothing — that is the
    /// whole single-resume argument, in one place.
    private final class Call {
        let utterance: AVSpeechUtterance
        var continuation: CheckedContinuation<Void, Error>?
        /// Set when the task is cancelled before `start` managed to install the continuation.
        var cancelled = false

        init(utterance: AVSpeechUtterance) { self.utterance = utterance }

        func takeContinuation() -> CheckedContinuation<Void, Error>? {
            defer { continuation = nil }
            return continuation
        }
    }

    private let lock = NSLock()
    /// The in-flight call, if any. `stopSpeaking` makes the *previous* utterance report
    /// `didCancel` after the next one has already started, so delegate callbacks are matched
    /// against this call's utterance and stale ones are dropped rather than resuming somebody
    /// else's continuation.
    private var current: Call?
    /// `speechVoices()` is not free; cache it once it has answered "yes" (a "no" can become a
    /// "yes" later when the user downloads a voice, so only positives are cached).
    private var hasVoices = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Availability

    /// Whether the device can speak at all. False on a stripped simulator with no installed
    /// voices — callers in `auto` mode treat that as "no fallback" and surface the Voca error.
    var isAvailable: Bool {
        lock.lock()
        let cached = hasVoices
        lock.unlock()
        if cached { return true }
        let available = !AVSpeechSynthesisVoice.speechVoices().isEmpty
        if available {
            lock.lock()
            hasVoices = true
            lock.unlock()
        }
        return available
    }

    /// A realtime conversation is running, so the shared session is `.playAndRecord` with a
    /// hot mic. See `speak(_:language:)` for why that means "do not speak".
    var isBlockedByLiveVoice: Bool {
        AudioSessionCoordinator.shared.mode == .liveVoice
    }

    // MARK: - Speaking

    /// Speak `text`, returning when the utterance has actually finished.
    ///
    /// AUDIO SESSION POLICY — **skip, do not coordinate.** When
    /// `AudioSessionCoordinator.mode == .liveVoice` this throws `.liveVoiceActive` instead of
    /// speaking. The coordinator owns the session; during `.liveVoice` it is configured
    /// `.playAndRecord` with the mic live, and `RealtimeVoiceEngine` gates that mic only while
    /// *its own* AI audio is draining. A second voice coming out of the speaker would both talk
    /// over the companion and be captured as user speech, so the companion would answer itself.
    /// Asking the coordinator for a third mode instead would mean tearing the realtime engine's
    /// session down and back up mid-conversation for one word — far more disruptive than
    /// declining and saying why. Outside `.liveVoice` nothing here touches the session at all:
    /// the synthesizer plays on the app's default session, exactly like the `AVPlayer` that
    /// plays Voca's mp3.
    ///
    /// Throws `CancellationError` when a newer utterance supersedes this one (a second tap) or
    /// the calling task is cancelled — neither is a failure worth reporting to the user.
    func speak(_ text: String, language: String = "en-US") async throws {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw DeviceSpeechError.nothingToSpeak }
        guard isAvailable else { throw DeviceSpeechError.unavailable }
        guard !isBlockedByLiveVoice else { throw DeviceSpeechError.liveVoiceActive }

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice(for: language)
        // Slightly under the default: these are single vocabulary words being learned.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = 1
        let call = Call(utterance: utterance)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The synthesizer is driven from the main thread throughout, so a stop and the
                // speak that follows it stay ordered no matter which thread called in.
                if Thread.isMainThread {
                    self.start(call, continuation: continuation)
                } else {
                    DispatchQueue.main.async { self.start(call, continuation: continuation) }
                }
            }
        } onCancel: {
            self.cancel(call)
        }
    }

    /// Stop whatever is speaking. The in-flight caller (if any) is resumed with
    /// `CancellationError`; the `didCancel` this triggers is then dropped as stale.
    func stop() {
        lock.lock()
        let continuation = current?.takeContinuation()
        current = nil
        lock.unlock()

        _ = synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume(throwing: CancellationError())
    }

    // MARK: - Continuation plumbing (single-resume invariant)

    private func start(_ call: Call, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        // The task was cancelled while this call was hopping to the main thread.
        if call.cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        // Rapid taps must not queue up: the call this one replaces is answered here,
        // synchronously, and stops being `current` — so the `didCancel` that `stopSpeaking`
        // is about to deliver for it cannot resume the continuation being installed now.
        let superseded = current?.takeContinuation()
        call.continuation = continuation
        current = call
        lock.unlock()

        superseded?.resume(throwing: CancellationError())
        _ = synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(call.utterance)
    }

    /// Task cancellation for one specific call.
    private func cancel(_ call: Call) {
        lock.lock()
        // Marked even when the continuation is not installed yet: `start` reads this and
        // resumes with `CancellationError` instead of speaking. The flag lives on the call
        // object, so it dies with the call — nothing to leak, nothing to mismatch.
        call.cancelled = true
        let continuation = call.takeContinuation()
        if current === call { current = nil }
        lock.unlock()

        guard let continuation else { return }
        _ = synthesizer.stopSpeaking(at: .immediate)
        continuation.resume(throwing: CancellationError())
    }

    /// The ONLY place a delegate callback can resume a caller.
    private func finish(_ utterance: AVSpeechUtterance, with error: Error?) {
        lock.lock()
        guard let call = current, call.utterance === utterance,
              let continuation = call.takeContinuation()
        else {
            // A late callback for an utterance that was already answered (superseded, or
            // cancelled). Dropping it is what keeps the continuation single-resume.
            lock.unlock()
            return
        }
        current = nil
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // MARK: - Voice selection

    /// Best available voice for `language`, else the closest one sharing its base language,
    /// else `nil` — which tells the synthesizer to use the system default. A wrong accent
    /// beats silence.
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        if let exact = AVSpeechSynthesisVoice(language: tag) { return exact }
        let base = (tag.split(separator: "-").first.map(String.init) ?? tag).lowercased()
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.lowercased().hasPrefix(base) }
    }
}

// MARK: - Delegate

extension DeviceSpeech: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance, with: nil)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance, with: CancellationError())
    }
}

// MARK: - Errors

enum DeviceSpeechError: LocalizedError {
    /// No installed voices — the device cannot speak at all.
    case unavailable
    /// A realtime companion conversation owns the audio session right now.
    case liveVoiceActive
    case nothingToSpeak

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Thiết bị chưa có giọng đọc nào để phát âm."
        case .liveVoiceActive:
            return "Đang trò chuyện bằng giọng nói với AI nên chưa đọc được. Tạm dừng hội thoại rồi thử lại."
        case .nothingToSpeak:
            return "Không có từ nào để đọc."
        }
    }
}
