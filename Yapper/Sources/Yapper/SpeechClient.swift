import Foundation
import AVFoundation

struct SpeechClient {
    private let baseURL = URL(string: ProcessInfo.processInfo.environment["YAPPER_URL"] ?? "http://127.0.0.1:8765")!

    /// Streams sentence-level WAV chunks from `/speak_stream` as Kokoro
    /// produces them. The async sequence yields one complete WAV per chunk;
    /// the caller is responsible for sequencing playback (see `StreamPlayer`).
    func synthesizeStream(text: String, voice: String, speed: Double) -> AsyncThrowingStream<Data, Error> {
        let url = baseURL.appendingPathComponent("speak_stream")
        let voiceVal = voice
        let speedVal = speed
        let textVal = text
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = SpeakRequest(text: textVal, voice: voiceVal, speed: speedVal)
                    req.httpBody = try JSONEncoder().encode(body)
                    // Idle timeout between bytes — server flushes per sentence,
                    // so 30s is far more than worst-case per-sentence synth time.
                    req.timeoutInterval = 30

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        throw NSError(domain: "Yapper", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Server status \(code)"])
                    }

                    let reader = ByteReader(bytes)
                    while true {
                        try Task.checkCancellation()
                        guard let header = try await reader.readExact(4) else { break }
                        let length = header.withUnsafeBytes { raw -> UInt32 in
                            raw.load(as: UInt32.self).bigEndian
                        }
                        if length == 0 { break }
                        guard let wav = try await reader.readExact(Int(length)) else {
                            throw NSError(domain: "Yapper", code: 4,
                                          userInfo: [NSLocalizedDescriptionKey: "Stream truncated mid-frame"])
                        }
                        continuation.yield(wav)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct SpeakRequest: Encodable {
    let text: String
    let voice: String
    let speed: Double
    let lang_code: String = "a"
}

/// Reads exact-sized byte runs from a URLSession byte stream. Single-task use.
private final class ByteReader: @unchecked Sendable {
    private var iter: URLSession.AsyncBytes.AsyncIterator

    init(_ bytes: URLSession.AsyncBytes) {
        self.iter = bytes.makeAsyncIterator()
    }

    func readExact(_ n: Int) async throws -> Data? {
        var buf = Data()
        buf.reserveCapacity(n)
        while buf.count < n {
            guard let byte = try await iter.next() else {
                return buf.isEmpty ? nil : buf
            }
            buf.append(byte)
        }
        return buf
    }
}

/// Plays a sequence of WAV blobs back-to-back. Each chunk is pre-prepared at
/// enqueue time (AVAudioPlayer.prepareToPlay) so the cross-chunk gap is just
/// the cost of `.play()` on a primed buffer — typically tens of milliseconds,
/// effectively continuous.
actor StreamPlayer {
    private var pending: [PlayerInstance] = []
    private var nowPlaying: PlayerInstance?
    private var streamEnded = false
    private var stopped = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ data: Data) {
        guard !stopped else { return }
        do {
            let instance = try PlayerInstance(data: data)
            pending.append(instance)
            pumpIfIdle()
        } catch {
            fputs("Yapper: failed to init player for chunk (\(data.count) bytes): \(error)\n", stderr)
        }
    }

    func markStreamEnd() {
        streamEnded = true
        if nowPlaying == nil && pending.isEmpty { signalDone() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for p in pending { p.stop() }
        pending.removeAll()
        nowPlaying?.stop()
        nowPlaying = nil
        signalDone()
    }

    func waitUntilDone() async {
        if stopped || (streamEnded && pending.isEmpty && nowPlaying == nil) { return }
        await withCheckedContinuation { c in
            finishWaiters.append(c)
        }
    }

    private func pumpIfIdle() {
        guard !stopped, nowPlaying == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        nowPlaying = next
        next.start { [weak self] in
            Task { await self?.handleFinish() }
        }
    }

    private func handleFinish() {
        nowPlaying = nil
        if stopped { return }
        if !pending.isEmpty {
            pumpIfIdle()
        } else if streamEnded {
            signalDone()
        }
    }

    private func signalDone() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for c in waiters { c.resume() }
    }
}

private final class PlayerInstance: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let player: AVAudioPlayer
    private var onFinish: (@Sendable () -> Void)?

    init(data: Data) throws {
        self.player = try AVAudioPlayer(data: data)
        super.init()
        self.player.delegate = self
        self.player.prepareToPlay()
    }

    func start(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
        if !player.play() {
            fputs("Yapper: AVAudioPlayer.play() returned false\n", stderr)
            fireFinish()
        }
    }

    func stop() {
        onFinish = nil
        player.stop()
    }

    private func fireFinish() {
        let cb = onFinish
        onFinish = nil
        cb?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        fireFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        fputs("Yapper: decode error: \(error?.localizedDescription ?? "?")\n", stderr)
        fireFinish()
    }
}
