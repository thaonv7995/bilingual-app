import Foundation
import AVFoundation

enum DeviceSpeechError: LocalizedError {
    case nothingToSpeak
    case unavailable

    var errorDescription: String? {
        switch self {
        case .nothingToSpeak: return "Không có nội dung để đọc."
        case .unavailable: return "Trình đọc văn bản hệ thống không khả dụng."
        }
    }
}

/// Offline pronunciation / text-to-speech on macOS via AVSpeechSynthesizer.
final class DeviceSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = DeviceSpeech()

    private let synthesizer = AVSpeechSynthesizer()
    private var activeContinuation: CheckedContinuation<Void, Error>?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var isAvailable: Bool {
        !AVSpeechSynthesisVoice.speechVoices().isEmpty
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeContinuation?.resume()
        activeContinuation = nil
    }

    @MainActor
    func speak(_ text: String, language: String = "en-US", rate: Float = AVSpeechUtteranceDefaultSpeechRate) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeviceSpeechError.nothingToSpeak }
        guard isAvailable else { throw DeviceSpeechError.unavailable }

        stop()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en")
        utterance.rate = rate

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.activeContinuation = continuation
            self.synthesizer.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        activeContinuation?.resume()
        activeContinuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        activeContinuation?.resume()
        activeContinuation = nil
    }
}

