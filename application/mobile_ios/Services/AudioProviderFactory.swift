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
        configureAudioSession()
    }

    /// Ensures AVAudioSession is set to .playback so audio plays even when physical Silent/Mute switch is ON
    func configureAudioSession() {
        guard AudioSessionCoordinator.shared.mode != .liveVoice else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("[AudioProviderFactory] Primary audio session config failed: \(error). Falling back to basic .playback")
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                print("[AudioProviderFactory] Basic audio session config failed: \(error)")
            }
        }
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

    var currentTime: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return audioPlayer?.currentTime ?? 0
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            audioPlayer?.currentTime = newValue
        }
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return audioPlayer?.duration ?? 0
    }

    var isAudioPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return audioPlayer?.isPlaying ?? false
    }

    func pause() {
        lock.lock()
        audioPlayer?.pause()
        lock.unlock()
    }

    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let player = audioPlayer, player.currentTime < player.duration - 0.1 else {
            return false
        }
        configureAudioSession()
        return player.play()
    }

    func seek(to time: TimeInterval) {
        lock.lock()
        audioPlayer?.currentTime = max(0, time)
        lock.unlock()
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

    /// Speaks or plays a piece of text (e.g. full page). Suspends until playback is finished.
    func speak(
        text: String,
        provider: String,
        voice: String,
        speed: String,
        lang: String = "en-US",
        startRatio: Double = 0.0
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        configureAudioSession()

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

        try await playAudioData(audioData, speed: speed, startRatio: startRatio)
    }

    /// Play in-memory MP3 audio data
    private func playAudioData(_ data: Data, speed: String, startRatio: Double = 0.0) async throws {
        guard !data.isEmpty else {
            throw NSError(domain: "AudioPlayback", code: -4, userInfo: [NSLocalizedDescriptionKey: "Dữ liệu âm thanh trống"])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                do {
                    self.configureAudioSession()

                    let player = try AVAudioPlayer(data: data)
                    player.delegate = self
                    player.volume = 1.0
                    player.enableRate = true
                    if let rate = Float(speed), rate > 0 {
                        player.rate = rate
                    }
                    player.prepareToPlay()
                    if startRatio > 0 && startRatio < 1.0 && player.duration > 0 {
                        player.currentTime = startRatio * player.duration
                    }

                    self.lock.lock()
                    self.audioPlayer = player
                    self.playbackContinuation = continuation
                    self.lock.unlock()

                    guard player.play() else {
                        self.resumeContinuation(with: NSError(domain: "AudioPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không thể phát âm thanh"]))
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
        lock.lock()
        if audioPlayer === player {
            audioPlayer = nil
        }
        lock.unlock()
        resumeContinuation(with: flag ? nil : NSError(domain: "AudioPlayback", code: -2, userInfo: [NSLocalizedDescriptionKey: "Playback did not complete successfully"]))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        lock.lock()
        if audioPlayer === player {
            audioPlayer = nil
        }
        lock.unlock()
        resumeContinuation(with: error ?? NSError(domain: "AudioPlayback", code: -3, userInfo: [NSLocalizedDescriptionKey: "Decode error occurred"]))
    }
}
