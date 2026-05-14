import SwiftUI
import AppKit
import KeyboardShortcuts

@MainActor
final class AppState: ObservableObject {
    @Published var isSpeaking = false
    @Published var statusText = "Idle"
    @Published var voice: String = "af_heart" { didSet { UserDefaults.standard.set(voice, forKey: "voice") } }
    @Published var speed: Double = 1.0 { didSet { UserDefaults.standard.set(speed, forKey: "speed") } }

    let availableVoices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "am_adam", "am_michael"]

    private let speech = SpeechClient()
    private var currentTask: Task<Void, Never>?

    init() {
        if let v = UserDefaults.standard.string(forKey: "voice") { self.voice = v }
        let s = UserDefaults.standard.double(forKey: "speed")
        if s > 0 { self.speed = s }

        // One-shot reset of persisted shortcuts so the new in-code defaults
        // take effect after rebinding. Safe to bump the version string when we
        // need to do it again in the future.
        let migrationKey = "hotkeyMigration_v2"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            KeyboardShortcuts.reset(.speakSelection, .stopSpeaking)
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        KeyboardShortcuts.onKeyDown(for: .speakSelection) { [weak self] in
            Task { @MainActor in self?.toggleSpeak() }
        }
        KeyboardShortcuts.onKeyDown(for: .stopSpeaking) { [weak self] in
            Task { @MainActor in self?.stop() }
        }

        ensureAccessibility()
    }

    /// Called by hotkey OR menubar button. Defer by a short delay so that, if
    /// this fires from a menubar click, the menu has time to dismiss and the
    /// previously-focused app gets its focus back before we read selection.
    func toggleSpeak(deferred: Bool = false) {
        if isSpeaking { stop(); return }
        let go: () -> Void = { [weak self] in self?.doSpeakFromSelection() }
        if deferred {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: go)
        } else {
            go()
        }
    }

    private func doSpeakFromSelection() {
        let text = TextSelection.grab() ?? ""
        fputs("KokoroSpeak: grab returned \(text.count) chars\n", stderr)
        guard !text.isEmpty else {
            statusText = "No selection"
            notify(title: "Nothing to speak", body: "Highlight some text first, then trigger again.")
            return
        }
        speak(text)
    }

    private func notify(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func speak(_ text: String) {
        currentTask?.cancel()
        isSpeaking = true
        statusText = "Synthesizing…"
        let voice = self.voice
        let speed = self.speed
        currentTask = Task { [weak self] in
            do {
                let data = try await SpeechClient().synthesize(text: text, voice: voice, speed: speed)
                if Task.isCancelled { return }
                await MainActor.run { self?.statusText = "Speaking" }
                try await SpeechClient.player.play(data: data)
                await MainActor.run {
                    self?.statusText = "Idle"
                    self?.isSpeaking = false
                    self?.currentTask = nil
                }
            } catch is CancellationError {
                // stopped on purpose
            } catch {
                let msg = error.localizedDescription
                fputs("KokoroSpeak: error — \(msg)\n", stderr)
                await MainActor.run {
                    self?.statusText = "Error: \(msg)"
                    self?.isSpeaking = false
                    self?.notify(title: "TTS failed", body: msg)
                }
            }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        SpeechClient.player.stop()
        isSpeaking = false
        statusText = "Idle"
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        statusText = trusted ? "Idle" : "Grant accessibility to enable hotkey"
    }
}
