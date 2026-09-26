import AVFoundation
import UIKit

extension Notification.Name {
    static let voicePlayerChanged = Notification.Name("voicePlayerChanged")
}

/// 播放语音消息：同一时间只放一条，状态变化通过通知告诉界面
@MainActor
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    private(set) var playingId: String?
    private(set) var loadingId: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var progress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    func toggle(_ message: Message) {
        if playingId == message.id {
            stop()
            return
        }
        stop()
        guard let media = message.media.first else { return }
        loadingId = message.id
        notify()
        Task {
            let data = await MediaCache.shared.data(media.id, thumb: false)
            guard loadingId == message.id, let data else {
                if loadingId == message.id { loadingId = nil; notify() }
                return
            }
            loadingId = nil
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.play()
                self.player = player
                playingId = message.id
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    Task { @MainActor in VoicePlayer.shared.notify() }
                }
            } catch {
                playingId = nil
            }
            notify()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingId = nil
        loadingId = nil
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .voicePlayerChanged, object: nil)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in VoicePlayer.shared.stop() }
    }
}

/// 录语音：AAC 单声道，录的同时采样音量做波形
@MainActor
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var levels: [Double] = []
    private(set) var startedAt: Date?
    var onLevel: ((Double, TimeInterval) -> Void)?

    var duration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw NSError(domain: "voice", code: 1) }
        self.recorder = recorder
        levels = []
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let level = max(0, min(1, Double((power + 50) / 50)))
        levels.append(level)
        onLevel?(level, duration)
    }

    /// 结束录音，返回文件、时长和 48 个波形采样
    func finish() -> (url: URL, durationMs: Int, waveform: [Double])? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard duration >= 0.8 else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        return (recorder.url, Int(duration * 1000), Self.downsample(levels, to: 48))
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func downsample(_ values: [Double], to count: Int) -> [Double] {
        guard !values.isEmpty else { return Array(repeating: 0.1, count: count) }
        return (0 ..< count).map { index in
            let start = index * values.count / count
            let end = max(start + 1, (index + 1) * values.count / count)
            let slice = values[start ..< min(end, values.count)]
            return (slice.max() ?? 0).rounded(toPlaces: 2)
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
