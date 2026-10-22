import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press a shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var app
    let name: String
    let fallback: KeyCombo?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        let combo = app.prefs.shortcut(for: name, fallback: fallback)

        HStack(spacing: 6) {
            if app.hotKeys.conflicts.contains(name) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app already uses this shortcut. Pick a different one.")
            }

            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Type Shortcut" : (combo?.display ?? "Record Shortcut"))
                    .foregroundStyle(isRecording || combo == nil ? .secondary : .primary)
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)

            Menu {
                Button("Clear") { update(nil) }.disabled(combo == nil)
                if fallback != nil {
                    Button("Reset to Default") {
                        app.prefs.resetShortcut(for: name)
                        app.registerShortcuts()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        app.hotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let bare = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                switch Int(event.keyCode) {
                case kVK_Escape where bare:
                    stopRecording()
                case kVK_Delete where bare, kVK_ForwardDelete where bare:
                    update(nil)
                    stopRecording()
                default:
                    guard let combo = KeyCombo(event: event) else {
                        NSSound.beep()
                        return
                    }
                    update(combo)
                    stopRecording()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        app.hotKeys.resume()
    }

    private func update(_ combo: KeyCombo?) {
        app.prefs.setShortcut(combo, for: name)
        app.registerShortcuts()
    }
}
