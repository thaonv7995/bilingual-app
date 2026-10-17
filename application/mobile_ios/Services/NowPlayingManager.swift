import Foundation
import MediaPlayer
import AVFoundation
import UIKit

/// Manages Lock Screen / Control Center playback metadata (MPNowPlayingInfoCenter)
/// and hardware/headphone/lock screen media commands (MPRemoteCommandCenter).
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private var isConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false

    private var onPlayAction: (() -> Void)?
    private var onPauseAction: (() -> Void)?
    private var onToggleAction: (() -> Void)?
    private var onNextTrackAction: (() -> Void)?
    private var onPrevTrackAction: (() -> Void)?
    private var onSeekAction: ((TimeInterval) -> Void)?

    private init() {
        setupInterruptionHandling()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Sets up the MPRemoteCommandCenter handlers once.
    func setupRemoteCommands(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onNextTrack: @escaping () -> Void,
        onPrevTrack: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.onPlayAction = onPlay
        self.onPauseAction = onPause
        self.onToggleAction = onToggle
        self.onNextTrackAction = onNextTrack
        self.onPrevTrackAction = onPrevTrack
        self.onSeekAction = onSeek

        guard !isConfigured else { return }
        isConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        // 1. Play / Pause / Toggle
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPlayAction?() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPauseAction?() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onToggleAction?() }
            return .success
        }

        // 2. Next / Previous (sentence / page navigation)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onNextTrackAction?() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPrevTrackAction?() }
            return .success
        }

        // 3. Skip 10 seconds
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onNextTrackAction?() }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPrevTrackAction?() }
            return .success
        }

        // 4. Scrubbing / Seeking
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let targetTime = posEvent.positionTime
            DispatchQueue.main.async { self?.onSeekAction?(targetTime) }
            return .success
        }
    }

    /// Updates the Lock Screen and Control Center Now Playing widget
    func updateNowPlaying(
        title: String,
        artist: String,
        albumTitle: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        playbackRate: Double,
        artworkImage: UIImage? = nil
    ) {
        var info: [String: Any] = [:]

        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = albumTitle
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = max(0.1, duration)
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if let image = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clears the lock screen media information
    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Audio Interruption Handling (Phone calls, Siri, etc.)
    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = AudioProviderFactory.shared.isAudioPlaying
                if self.wasPlayingBeforeInterruption {
                    self.onPauseAction?()
                }
            case .ended:
                guard self.wasPlayingBeforeInterruption else { return }
                self.wasPlayingBeforeInterruption = false

                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        AudioProviderFactory.shared.configureAudioSession()
                        self.onPlayAction?()
                    }
                }
            @unknown default:
                break
            }
        }
    }
}
