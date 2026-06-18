import AVFoundation
import Foundation

/// Native OpenAI Realtime client over WebSocket (PCM16 @ 24 kHz both directions).
///
/// Ported from HintTalk's `RealtimeVoiceEngine`. Key additions for bilingual reader:
/// - **Tool call support**: `onToolCall` callback + `sendToolResult()` for function calling
/// - Simplified: no recording/review playback (HintTalk-specific features removed)
///
/// AVAudioEngine handles capture + playback; echo on the speaker route is prevented
/// by gating the mic while AI audio drains (see `handleCapturedBuffer`).
final class RealtimeVoiceEngine: NSObject {
    // MARK: Callbacks (delivered on the main actor)

    var onConnected: (() -> Void)?
    var onAiResponseStarted: (() -> Void)?
    var onAiTranscriptDelta: ((String) -> Void)?
    var onAiTranscriptDone: ((String) -> Void)?
    var onAiAudioFinished: (() -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onUserSpeakingChanged: ((Bool) -> Void)?
    var onLevels: ((Float, Float) -> Void)? // (input, output) RMS 0...1
    var onError: ((String) -> Void)?
    var onDisconnected: (() -> Void)?

    /// Called when the AI invokes a function call tool.
    /// Parameters: (callId, functionName, argumentsJSON)
    var onToolCall: ((String, String, String) -> Void)?

    // MARK: State

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputConverter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var pendingOutputBuffers = 0
    private var responseActive = false
    private var closed = false

    /// When muted we keep the engine running but stop streaming mic audio.
    var isMuted = true

    // Tool call accumulation
    private var pendingToolCallId: String?
    private var pendingToolCallName: String?
    private var pendingToolCallArgs: String = ""

    private let sampleRate: Double = 24000
    private lazy var wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private lazy var playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: 1
    )!

    // MARK: Lifecycle

    func connect(apiKey: String, model: String, sessionConfig: [String: Any]) {
        closed = false
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else {
            emitError("Invalid realtime model")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        receiveLoop()

        do {
            try startAudio()
        } catch {
            emitError("Audio engine failed: \(error.localizedDescription)")
            return
        }

        sendEvent(["type": "session.update", "session": sessionConfig])
    }

    func disconnect() {
        closed = true
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        stopAudio()
    }

    func requestResponse() {
        sendEvent(["type": "response.create"])
    }

    /// Stops AI playback immediately.
    func stopPlayback() {
        playerNode.stop()
        lock.lock()
        pendingOutputBuffers = 0
        lock.unlock()
    }

    /// Inject a system-level conversation item (bypasses instructions token limit).
    func injectConversationItem(text: String) {
        sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    ["type": "input_text", "text": text]
                ]
            ]
        ])
    }

    /// Send the result of a tool call back to the AI.
    func sendToolResult(callId: String, output: String) {
        sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ])
        // After providing tool output, request the AI to continue responding.
        sendEvent(["type": "response.create"])
    }

    // MARK: Session config builder

    static func sessionConfig(
        voice: String,
        instructions: String,
        tools: [[String: Any]]
    ) -> [String: Any] {
        var config: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "instructions": instructions,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": ["model": "whisper-1"],
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 400,
                        "silence_duration_ms": 1200,
                    ],
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": voice,
                ],
            ],
        ]
        if !tools.isEmpty {
            config["tools"] = tools
            config["tool_choice"] = "auto"
        }
        return config
    }

    // MARK: - Audio engine

    private func startAudio() throws {
        try AudioSessionCoordinator.shared.activate(.liveVoice)

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        inputConverter = AVAudioConverter(from: hwFormat, to: wireFormat)

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()

        // Category/route changes can stop a freshly started engine; restart it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.restartEngineIfNeeded()
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            AudioSessionCoordinator.shared.reactivate()
            self?.restartEngineIfNeeded()
        }
    }

    private func restartEngineIfNeeded() {
        guard !closed else { return }
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        if audioEngine.isRunning, !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func stopAudio() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        playerNode.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        AudioSessionCoordinator.shared.deactivate()
    }

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        let inputLevel = isMuted ? 0 : Self.rms(of: buffer)
        notifyLevels(input: inputLevel)

        guard !isMuted, let converter = inputConverter else { return }

        // Echo guard: while AI audio is still draining through the built-in speaker
        // the mic would pick the AI voice back up. Skip streaming in that window.
        lock.lock()
        let aiAudioActive = pendingOutputBuffers > 0 || responseActive
        lock.unlock()
        if aiAudioActive, AudioSessionCoordinator.shared.isSpeakerRoute { return }

        let ratio = sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData else { return }

        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channel[0], count: byteCount)

        sendEvent([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    private func playAudioDelta(_ base64: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0 ..< Int(frameCount) {
                channel[0][i] = Float(samples[i]) / 32768.0
            }
        }

        notifyLevels(output: Self.rms(of: buffer))

        lock.lock()
        pendingOutputBuffers += 1
        lock.unlock()

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingOutputBuffers -= 1
            let drained = self.pendingOutputBuffers <= 0
            let responseDone = !self.responseActive
            self.lock.unlock()
            if drained {
                self.notifyLevels(output: 0)
                if responseDone {
                    DispatchQueue.main.async { self.onAiAudioFinished?() }
                }
            }
        }
        restartEngineIfNeeded()
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let floats = buffer.floatChannelData {
            for i in 0 ..< frames { sum += floats[0][i] * floats[0][i] }
        } else if let ints = buffer.int16ChannelData {
            for i in 0 ..< frames {
                let v = Float(ints[0][i]) / 32768.0
                sum += v * v
            }
        } else {
            return 0
        }
        return min(1, sqrt(sum / Float(frames)) * 4)
    }

    private var lastLevelNotify = Date.distantPast
    private var latestInput: Float = 0
    private var latestOutput: Float = 0

    private func notifyLevels(input: Float? = nil, output: Float? = nil) {
        if let input { latestInput = input }
        if let output { latestOutput = output }
        let now = Date()
        guard now.timeIntervalSince(lastLevelNotify) > 0.05 else { return }
        lastLevelNotify = now
        let i = latestInput
        let o = latestOutput
        DispatchQueue.main.async { [weak self] in self?.onLevels?(i, o) }
    }

    // MARK: - WebSocket

    private func sendEvent(_ event: [String: Any]) {
        guard let webSocket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webSocket.send(.string(json)) { [weak self] error in
            if error != nil, self?.closed == false {
                // Transient send failures surface via the receive loop; ignore here.
            }
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .string(text):
                    self.handleServerEvent(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleServerEvent(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case let .failure(error):
                if !self.closed {
                    self.emitError("Connection lost: \(error.localizedDescription)")
                    DispatchQueue.main.async { self.onDisconnected?() }
                }
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "session.created", "session.updated":
            if type == "session.created" {
                DispatchQueue.main.async { self.onConnected?() }
            }

        case "response.created":
            lock.lock()
            responseActive = true
            lock.unlock()
            DispatchQueue.main.async { self.onAiResponseStarted?() }

        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String {
                playAudioDelta(delta)
            }

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                DispatchQueue.main.async { self.onAiTranscriptDelta?(delta) }
            }

        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let transcript = event["transcript"] as? String {
                DispatchQueue.main.async { self.onAiTranscriptDone?(transcript) }
            }

        // MARK: Function call handling
        case "response.output_item.added":
            // A new output item was added. Check if it's a function_call.
            if let item = event["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                pendingToolCallId = item["call_id"] as? String
                pendingToolCallName = item["name"] as? String
                pendingToolCallArgs = ""
            }

        case "response.function_call_arguments.delta":
            if let delta = event["delta"] as? String {
                pendingToolCallArgs += delta
            }

        case "response.function_call_arguments.done":
            if let callId = pendingToolCallId,
               let name = pendingToolCallName {
                let args = event["arguments"] as? String ?? pendingToolCallArgs
                DispatchQueue.main.async { self.onToolCall?(callId, name, args) }
            }
            pendingToolCallId = nil
            pendingToolCallName = nil
            pendingToolCallArgs = ""

        case "response.done":
            lock.lock()
            responseActive = false
            let drained = pendingOutputBuffers <= 0
            lock.unlock()
            if drained {
                DispatchQueue.main.async { self.onAiAudioFinished?() }
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async { self.onUserTranscript?(transcript) }
            }

        case "input_audio_buffer.speech_started":
            DispatchQueue.main.async { self.onUserSpeakingChanged?(true) }

        case "input_audio_buffer.speech_stopped":
            DispatchQueue.main.async { self.onUserSpeakingChanged?(false) }

        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "Realtime error"
            emitError(message)

        default:
            break
        }
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async { self.onError?(message) }
    }
}
