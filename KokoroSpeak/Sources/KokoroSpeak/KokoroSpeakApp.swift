import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let speakSelection = Self("speakSelection", default: .init(.s, modifiers: [.control, .shift]))
    static let stopSpeaking = Self("stopSpeaking", default: .init(.period, modifiers: [.control, .shift]))
}

@main
struct KokoroSpeakApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(systemName: state.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
        }
        .menuBarExtraStyle(.menu)

        Window("KokoroSpeak Settings", id: "settings") {
            SettingsView(state: state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct MenuView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusText).font(.caption).foregroundStyle(.secondary)
        Divider()

        Button(state.isSpeaking ? "Stop" : "Speak selected text") {
            state.toggleSpeak(deferred: true)
        }

        Menu("Voice — \(state.voice)") {
            ForEach(state.availableVoices, id: \.self) { v in
                Button(v) { state.voice = v }
            }
        }

        Menu("Speed — \(String(format: "%.2fx", state.speed))") {
            ForEach([0.75, 0.9, 1.0, 1.1, 1.25, 1.5], id: \.self) { s in
                Button(String(format: "%.2fx", s)) { state.speed = s }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Open accessibility settings") { state.openAccessibilitySettings() }
        Button("Quit KokoroSpeak") { NSApplication.shared.terminate(nil) }
    }
}
