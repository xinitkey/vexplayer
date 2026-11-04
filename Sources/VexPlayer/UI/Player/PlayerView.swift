import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    let session: InstanceSession
    let screen: ScreenView
    @Bindable var ui: PlayerUIState

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                ScreenHost(view: screen)
                GeometryReader { geo in
                    let rect = session.geometry.fitRect(in: geo.size)
                    if ui.editingKeymap {
                        KeymapEditorView(session: session, rect: rect, isPresented: $ui.editingKeymap)
                    } else if session.state == .running, session.keymapEnabled, session.keymap.showHints,
                              !session.typing, !session.aimLocked {
                        KeymapHintsView(map: session.keymap, rect: rect, aspect: session.geometry.aspect)
                            .allowsHitTesting(false)
                    }
                }
                if session.state != .running {
                    BootOverlay(session: session, ui: ui)
                }
                VStack {
                    if session.aimLocked {
                        Text("Cursor locked · press ` or Esc to release")
                            .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.top, 8)
                    }
                    Spacer()
                    if let toast = session.toast {
                        Text(toast)
                            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                            .padding(.bottom, 16)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: session.toast)
            }
            .background(Color.black)
            .clipped()

            if !ui.isFullScreen {
                PlayerSidebar(session: session, ui: ui)
                    .frame(width: PlayerWindowController.sidebarWidth)
            }
        }
        .sheet(isPresented: $ui.showLocation) { LocationSheet(session: session) }
        .sheet(isPresented: $ui.showLogs) { LogView(session: session) }
        .onChange(of: ui.editingKeymap) { _, editing in
            session.input.releaseAll()
            session.input.suspended = editing
        }
    }
}

/// Hosts the AppKit screen view inside SwiftUI without ever recreating it.
struct ScreenHost: NSViewRepresentable {
    let view: ScreenView
    func makeNSView(context: Context) -> ScreenView { view }
    func updateNSView(_ nsView: ScreenView, context: Context) {}
}

struct BootOverlay: View {
    let session: InstanceSession
    let ui: PlayerUIState

    var body: some View {
        ZStack {
            Color.black.opacity(session.state == .booting ? 0.55 : 0.85)
            VStack(spacing: 14) {
                switch session.state {
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.yellow)
                    Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: 460).textSelection(.enabled)
                    HStack {
                        Button("Retry") { session.start() }.keyboardShortcut(.defaultAction)
                        Button("Log") { ui.showLogs = true }
                    }
                case .stopped:
                    Image(systemName: "power").font(.system(size: 34)).foregroundStyle(.white.opacity(0.7))
                    Text("The instance is stopped").foregroundStyle(.white.opacity(0.85))
                    Button("Start") { session.start() }.keyboardShortcut(.defaultAction)
                default:
                    ProgressView().controlSize(.large).tint(.white)
                    Text(session.state.label).font(.headline).foregroundStyle(.white)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(session.logLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                            .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).frame(maxWidth: 420)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct PlayerSidebar: View {
    let session: InstanceSession
    @Bindable var ui: PlayerUIState
    @State private var sync = SyncController.shared

    private var running: Bool { session.state == .running }

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls when the window is short (landscape at small sizes); system keys stay pinned below.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    SidebarButton(symbol: session.keymapEnabled ? "keyboard.fill" : "keyboard",
                                  help: session.keymapEnabled ? "Key mapping: on (⌥K)" : "Key mapping: off (⌥K)",
                                  active: session.keymapEnabled) { session.keymapEnabled.toggle() }
                        .keyboardShortcut("k", modifiers: .option)
                    SidebarButton(symbol: "slider.horizontal.3", help: "Key mapping editor (⌥E)", active: ui.editingKeymap) {
                        ui.editingKeymap.toggle()
                    }
                    .keyboardShortcut("e", modifiers: .option)
                    .disabled(!running)
                    schemeMenu.disabled(!running || ui.editingKeymap)

                    Divider().padding(.vertical, 3).padding(.horizontal, 10)

                    SidebarButton(symbol: "camera", help: "Screenshot (⌥S)") { session.takeScreenshot() }
                        .keyboardShortcut("s", modifiers: .option).disabled(!running)
                    SidebarButton(symbol: session.isRecordingVideo ? "stop.circle.fill" : "record.circle",
                                  help: session.isRecordingVideo ? "Stop recording" : "Screen recording (⌥R)",
                                  active: session.isRecordingVideo, tint: session.isRecordingVideo ? .red : nil) {
                        session.toggleVideoRecording()
                    }
                    .keyboardShortcut("r", modifiers: .option).disabled(!running)
                    SidebarButton(symbol: "shippingbox", help: "Install APK / XAPK") { pickFiles(apk: true) }.disabled(!running)
                    SidebarButton(symbol: "folder", help: "Send files to Android (Download)") { pickFiles(apk: false) }.disabled(!running)
                    SidebarButton(symbol: "location", help: "Virtual location") { ui.showLocation = true }.disabled(!running)
                    SidebarButton(symbol: "rotate.right", help: "Rotate the screen") { session.rotate() }.disabled(!running)
                    SidebarButton(symbol: "speaker.plus", help: "Volume up") { session.volumeUp() }.disabled(!running)
                    SidebarButton(symbol: "speaker.minus", help: "Volume down") { session.volumeDown() }.disabled(!running)

                    macroMenu.disabled(!running)
                    syncMenu

                    SidebarButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen (⌃⌘F)") {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                    SidebarButton(symbol: "square.grid.2x2", help: "Instance manager") {
                        NSApp.sendAction(#selector(AppDelegate.showLauncher), to: nil, from: nil)
                    }
                }
                .padding(.top, 6)
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 3)
            VStack(spacing: 1) {
                moreMenu
                SidebarButton(symbol: "chevron.backward", help: "Back") { session.back() }.disabled(!running)
                SidebarButton(symbol: "circle", help: "Home") { session.home() }.disabled(!running)
                SidebarButton(symbol: "square", help: "Recents") { session.recents() }.disabled(!running)
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.11))
    }

    private var schemeMenu: some View {
        Menu {
            ForEach(session.keymapProfile.schemes) { scheme in
                Button {
                    session.selectScheme(scheme.id)
                } label: {
                    if scheme.id == session.activeScheme?.id {
                        Label(scheme.name, systemImage: "checkmark")
                    } else {
                        Text(scheme.name)
                    }
                }
            }
            Divider()
            Button("New scheme…") {
                session.createScheme(copyingActive: false)
                ui.editingKeymap = true
            }
            Button("Edit the current one…") { ui.editingKeymap = true }
        } label: {
            SidebarIcon(symbol: "list.bullet.rectangle")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Control scheme: \(session.activeScheme?.name ?? "—")")
    }

    private var macroMenu: some View {
        Menu {
            let rec = session.recorder
            if rec.isRecording {
                Button("Stop recording") { rec.stopRecording() }
            } else {
                Button("Record actions") { rec.startRecording() }
            }
            Button(rec.isPlaying ? "Stop playback" : "Play (\(String(format: "%.1f", rec.duration)) s)") {
                rec.isPlaying ? rec.stop() : rec.play(on: session.input)
            }
            .disabled(rec.steps.isEmpty || rec.isRecording)
            Toggle("Loop", isOn: Binding(get: { rec.loop }, set: { rec.loop = $0 }))
            Divider()
            Button("Save macro…") { saveMacro() }.disabled(rec.steps.isEmpty)
            Button("Load macro…") { loadMacro() }
        } label: {
            SidebarIcon(symbol: session.recorder.isRecording ? "record.circle.fill" : "play.rectangle.on.rectangle",
                        active: session.recorder.isRecording || session.recorder.isPlaying,
                        tint: session.recorder.isRecording ? .red : nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Record and replay actions (macros)")
    }

    private var syncMenu: some View {
        Menu {
            Toggle("Synchronizer on", isOn: $sync.enabled)
            Button("Make this window the leader") {
                sync.leaderID = session.id
                sync.enabled = true
            }
            if let leader = sync.leaderID, let s = InstanceStore.shared.sessions[leader] {
                Text("Leader: \(s.config.name)")
            }
        } label: {
            SidebarIcon(symbol: "rectangle.on.rectangle",
                        active: sync.enabled && sync.leaderID == session.id)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Synchronizer: repeat actions in every instance")
    }

    private var moreMenu: some View {
        Menu {
            Button("Shake") { session.shake() }
            Button("Power button") { session.power() }
            Button("Restart Android") { session.restart() }
            Button("Arrange windows") { PlayerWindows.shared.arrange() }
            Divider()
            Button("Emulator log") { ui.showLogs = true }
            Button("Open the screenshots folder") { NSWorkspace.shared.open(AppPaths.screenshots) }
            Divider()
            Button("Stop the instance") { session.stop() }
        } label: {
            SidebarIcon(symbol: "ellipsis")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("More")
    }

    private func pickFiles(apk: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if apk {
            panel.allowedContentTypes = ["apk", "xapk", "apks", "apkm"].compactMap { UTType(filenameExtension: $0) }
            panel.message = String(localized: "Choose an APK, XAPK or APKS")
        }
        guard panel.runModal() == .OK else { return }
        session.install(panel.urls)
    }

    private func saveMacro() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macro.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.recorder.save(to: url)
    }

    private func loadMacro() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.recorder.load(from: url)
    }
}

struct SidebarIcon: View {
    let symbol: String
    var active = false
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(tint ?? (active ? Color.accentColor : Color.white.opacity(0.82)))
            .frame(width: 38, height: 30)
            .background(active ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

struct SidebarButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var active = false
    var tint: Color?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            SidebarIcon(symbol: symbol, active: active || hover, tint: tint)
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 && isEnabled }
    }
}

struct LogView: View {
    let session: InstanceSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log · \(session.config.name)").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.logLines.joined(), forType: .string)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(session.logLines.joined())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding()
        .frame(width: 760, height: 480)
    }
}
