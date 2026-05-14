import Foundation
import AVFoundation

struct SpeechClient {
    private let baseURL = URL(string: ProcessInfo.processInfo.environment["KOKORO_URL"] ?? "http://127.0.0.1:8765")!

    static let player = PlayerActor()

    func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("speak"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = SpeakRequest(text: text, voice: voice, speed: speed)
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "KokoroSpeak", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server: \(msg)"])
        }
        return data
    }
}

private struct SpeakRequest: Encodable {
    let text: String
    let voice: String
    let speed: Double
    let lang_code: String = "a"
}

/// Holds the current AVAudioPlayer and exposes async play/stop semantics. The
/// `play` call returns when playback finishes naturally, or throws
/// `CancellationError` if `stop()` interrupts it.
final class PlayerActor: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    func play(data: Data) async throws {
        if let c = continuation { continuation = nil; c.resume(throwing: CancellationError()) }
        player?.stop()
        player = try AVAudioPlayer(data: data)
        player?.delegate = self
        player?.prepareToPlay()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            if self.player?.play() != true {
                self.continuation = nil
                c.resume(throwing: NSError(domain: "KokoroSpeak", code: 2, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"]))
            }
        }
    }

    func stop() {
        player?.stop()
        if let c = continuation { continuation = nil; c.resume(throwing: CancellationError()) }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let c = continuation { continuation = nil; c.resume(returning: ()) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let c = continuation { continuation = nil; c.resume(throwing: error ?? NSError(domain: "KokoroSpeak", code: 3)) }
    }
}
