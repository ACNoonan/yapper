import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Hotkeys") {
                KeyboardShortcuts.Recorder("Speak / toggle stop:", name: .speakSelection)
                KeyboardShortcuts.Recorder("Hard stop:", name: .stopSpeaking)
                Text("Tip: click the field and press your desired combination. Press ⌫ to clear.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Voice") {
                Picker("Voice", selection: $state.voice) {
                    ForEach(state.availableVoices, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $state.speed, in: 0.5...2.0, step: 0.05)
                    Text(String(format: "%.2f×", state.speed)).monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }

            Section("Status") {
                Text(state.statusText).font(.callout)
                Button("Open accessibility settings") { state.openAccessibilitySettings() }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
