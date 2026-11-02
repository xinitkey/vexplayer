import SwiftUI

struct AppSettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Language") {
                Picker("Interface language", selection: $settings.interfaceLanguage) {
                    Text("Same as macOS").tag("")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
                if settings.interfaceLanguage != settings.launchInterfaceLanguage {
                    HStack {
                        Text("The new language applies after VexPlayer restarts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if Bundle.main.bundleURL.pathExtension == "app" {
                            Button("Restart now") { relaunch() }
                        }
                    }
                }
            }
            Section("Display") {
                Toggle("Vertical sync (smoother; off means lower latency)", isOn: $settings.vsync)
                Toggle("Show FPS in the window title", isOn: $settings.showFPS)
            }
            Section("Input") {
                Toggle("Type in the Mac's current input language (VexPlayer input method)", isOn: $settings.macInputMethod)
                Toggle("Sync the clipboard with Android", isOn: $settings.clipboardSync)
                Toggle("Invert the mouse wheel", isOn: $settings.invertWheel)
            }
            Section("Windows") {
                Toggle("Stop the instance when its window closes", isOn: $settings.stopOnWindowClose)
                Toggle("Run hidden windows in the background", isOn: $settings.backgroundWhenHidden)
                Text("A minimized or closed instance keeps running on the efficiency cores and stays out of other apps' way.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Pause minimized instances", isOn: $settings.pauseWhenMinimized)
                Text("Android in a minimized window freezes and uses no CPU at all, then continues right where it was. Online games may lose their server connection during the pause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Engine (advanced)") {
                Toggle("Qt build with a hidden window instead of headless", isOn: $settings.hiddenQtWindow)
                Toggle("Flip frames vertically", isOn: $settings.flipFrames)
                TextField("Extra emulator arguments", text: $settings.extraEmulatorArgs)
                    .font(.body.monospaced())
                Text("Engine changes apply the next time an instance starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("VexPlayer folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.root) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
    }

    /// Quits (running instances save their Quickboot state) and opens the app again once this process is gone.
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
