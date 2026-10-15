import Foundation
import AVFoundation

final class AudioProviderFactory: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioProviderFactory()

    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    // In-memory audio cache & prefetch tracking
    private let audioCache = NSCache<NSString, NSData>()
    private var prefetchTasks: [String: Task<Data, Error>] = [:]
    private let prefetchLock = NSLock()

    private override init() {
        super.init()
        audioCache.countLimit = 200
    }

    private func getPrefetchTask(for key: String) -> Task<Data, Error>? {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        return prefetchTasks[key]
    }

    private func setPrefetchTask(_ task: Task<Data, Error>, for key: String) {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        prefetchTasks[key] = task
    }

    private func removePrefetchTask(for key: String) {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        prefetchTasks.removeValue(forKey: key)
    }

    /// Prefetch synthesized audio data in the background ahead of time
    func prefetch(
        text: String,
        provider: String,
        voice: String,
        speed: String,
        lang: String = "en-US"
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, provider != "device" else { return }

        let cacheKey = "\(provider):\(voice):\(speed):\(lang):\(trimmed)"

        if audioCache.object(forKey: cacheKey as NSString) != nil {
            return
        }

        if getPrefetchTask(for: cacheKey) != nil {
            return
        }

        let task = Task { () -> Data in
            let data = try await APIService.shared.synthesizeAudio(
                text: trimmed,
                provider: provider,
                voice: voice.isEmpty ? nil : voice,
                speed: speed.isEmpty ? nil : speed,
                lang: lang.hasPrefix("vi") ? "vi" : "en"
            )
            self.audioCache.setObject(data as NSData, forKey: cacheKey as NSString)
            self.removePrefetchTask(for: cacheKey)
            return data
        }
        setPrefetchTask(task, for: cacheKey)
    }

    func clearCache() {
        audioCache.removeAllObjects()
        prefetchLock.lock()
        prefetchTasks.removeAll()
        prefetchLock.unlock()
    }

    /// Preview a test phrase with given audio settings
    func preview(provider: String, voice: String, speed: String, lang: String = "en-US") async throws {
        let sampleText = lang.hasPrefix("vi")
            ? "Xin chào! Đây là âm thanh đọc thử sách bằng tiếng Việt."
            : "Hello! This is a test of your audiobook reading voice."
        try await speak(
            text: sampleText,
            provider: provider,
            voice: voice,
            speed: speed,
            lang: lang
        )
    }

    /// Speaks or plays a sentence of text. Suspends until the sentence is completely read.
    func speak(
        text: String,
        provider: String,
        voice: String,
        speed: String,
        lang: String = "en-US"
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()

        // 1. Native Device TTS (AVSpeechSynthesizer via DeviceSpeech)
        if provider == "device" {
            try await DeviceSpeech.shared.speak(trimmed, language: lang)
            return
        }

        // 2. Cloud Providers via Backend Proxy (/api/audio/synthesize)
        let cacheKey = "\(provider):\(voice):\(speed):\(lang):\(trimmed)"
        let audioData: Data

        if let cached = audioCache.object(forKey: cacheKey as NSString) as Data? {
            audioData = cached
        } else if let task = getPrefetchTask(for: cacheKey) {
            audioData = try await task.value
        } else {
            audioData = try await APIService.shared.synthesizeAudio(
                text: trimmed,
                provider: provider,
                voice: voice.isEmpty ? nil : voice,
                speed: speed.isEmpty ? nil : speed,
                lang: lang.hasPrefix("vi") ? "vi" : "en"
            )
            audioCache.setObject(audioData as NSData, forKey: cacheKey as NSString)
        }

        try await playAudioData(audioData, speed: speed)
    }

    /// Play in-memory MP3 audio data
    private func playAudioData(_ data: Data, speed: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                do {
                    self.audioPlayer = try AVAudioPlayer(data: data)
                    self.audioPlayer?.delegate = self
                    self.audioPlayer?.enableRate = true
                    if let rate = Float(speed), rate > 0 {
                        self.audioPlayer?.rate = rate
                    }
                    self.lock.lock()
                    self.playbackContinuation = continuation
                    self.lock.unlock()

                    guard self.audioPlayer?.play() == true else {
                        self.resumeContinuation(with: NSError(domain: "AudioPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start audio playback"]))
                        return
                    }
                } catch {
                    self.resumeContinuation(with: error)
                }
            }
        }
    }

    func stop() {
        DeviceSpeech.shared.stop()

        lock.lock()
        audioPlayer?.stop()
        audioPlayer = nil
        let cont = playbackContinuation
        playbackContinuation = nil
        lock.unlock()

        cont?.resume(throwing: CancellationError())
    }

    private func resumeContinuation(with error: Error?) {
        lock.lock()
        let cont = playbackContinuation
        playbackContinuation = nil
        lock.unlock()

        if let error = error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: ())
        }
    }

    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        resumeContinuation(with: flag ? nil : NSError(domain: "AudioPlayback", code: -2, userInfo: [NSLocalizedDescriptionKey: "Playback did not complete successfully"]))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        resumeContinuation(with: error ?? NSError(domain: "AudioPlayback", code: -3, userInfo: [NSLocalizedDescriptionKey: "Decode error occurred"]))
    }
}
