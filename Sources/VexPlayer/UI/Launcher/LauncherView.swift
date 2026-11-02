import AppKit
import SwiftUI

enum EditorTarget: Identifiable {
    case new
    case edit(InstanceConfig)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let c): return c.id
        }
    }
}

struct LauncherView: View {
    @State private var store = InstanceStore.shared
    @State private var sdk = SDKManager.shared
    @State private var editor: EditorTarget?
    @State private var showImages = false
    @State private var selection = Set<String>()
    @State private var errorText: String?
    @State private var pendingDelete: InstanceConfig?
    @State private var pendingWipe: InstanceConfig?

    var body: some View {
        Group {
            if !sdk.emulatorInstalled || !sdk.adbInstalled || sdk.installedImages.isEmpty {
                SetupView()
            } else {
                instanceList
            }
        }
        .frame(minWidth: 780, minHeight: 500)
        .toolbar { toolbar }
        .sheet(item: $editor) { target in InstanceEditorView(target: target) }
        .sheet(isPresented: $showImages) { ImageManagerView() }
        .alert("Ошибка", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Удалить «\(pendingDelete?.name ?? "")»? Все данные инстанса будут удалены.",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let c = pendingDelete { perform { try store.delete(c.id) } }
                pendingDelete = nil
            }
        }
        .confirmationDialog("Сбросить «\(pendingWipe?.name ?? "")» к заводскому состоянию?",
                            isPresented: Binding(get: { pendingWipe != nil }, set: { if !$0 { pendingWipe = nil } })) {
            Button("Сбросить данные", role: .destructive) {
                if let c = pendingWipe { perform { try store.wipeData(c.id) } }
                pendingWipe = nil
            }
        }
        .task {
            if sdk.catalog == nil { await sdk.refreshCatalog() }
        }
    }

    // MARK: List

    private var instanceList: some View {
        VStack(spacing: 0) {
            if store.instances.isEmpty {
                ContentUnavailableView {
                    Label("Нет инстансов", systemImage: "iphone.gen3")
                } description: {
                    Text("Создайте первый Android-инстанс.")
                } actions: {
                    Button("Создать инстанс") { editor = .new }.buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(store.instances) { config in
                        InstanceRow(config: config, session: store.sessions[config.id],
                                    start: { start(config) },
                                    actions: rowActions(config))
                            .tag(config.id)
                            .contextMenu { rowMenu(config) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            let running = store.sessions.values.filter { $0.state.isAlive }.count
            Label("\(store.instances.count) инстанс(ов), запущено \(running)", systemImage: "square.stack.3d.up")
            if let free = freeDisk { Label("Свободно \(formatBytes(free))", systemImage: "internaldrive") }
            Spacer()
            if let v = sdk.emulatorVersion { Text("Движок: Android Emulator \(v) · Hypervisor.framework").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }

    private var freeDisk: Int64? {
        (try? AppPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { startSelected() } label: { Label("Запустить выбранные", systemImage: "play.fill") }
                .disabled(selection.isEmpty)
                .help("Запустить выбранные инстансы")
            Button { stopAll() } label: { Label("Остановить все", systemImage: "stop.fill") }
                .help("Остановить все запущенные инстансы")
            Button { PlayerWindows.shared.arrange() } label: { Label("Упорядочить окна", systemImage: "rectangle.grid.2x2") }
                .help("Разложить окна инстансов сеткой")
            Button { showImages = true } label: { Label("Образы Android", systemImage: "externaldrive.badge.plus") }
                .help("Скачать или удалить версии Android")
            Button { editor = .new } label: { Label("Новый инстанс", systemImage: "plus") }
                .help("Создать новый инстанс")
                .disabled(sdk.installedImages.isEmpty)
        }
    }

    // MARK: Actions

    private func start(_ config: InstanceConfig) {
        let s = store.session(for: config)
        s.config = config
        if !s.state.isAlive { s.start() }
        PlayerWindows.shared.show(s)
    }

    private func startSelected() {
        // Stagger boots a little so they don't all fight for disk at the same moment.
        let configs = store.instances.filter { selection.contains($0.id) }
        Task {
            for c in configs {
                start(c)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopAll() {
        store.sessions.values.forEach { $0.stop() }
    }

    private func rowActions(_ c: InstanceConfig) -> InstanceRow.Actions {
        InstanceRow.Actions(
            stop: { store.sessions[c.id]?.stop() },
            settings: { editor = .edit(c) },
            clone: { perform { _ = try store.clone(c.id, name: "\(c.name) (копия)") } },
            wipe: { pendingWipe = c },
            delete: { pendingDelete = c },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([c.avdDir]) }
        )
    }

    @ViewBuilder
    private func rowMenu(_ c: InstanceConfig) -> some View {
        let running = store.isRunning(c.id)
        let a = rowActions(c)
        Button(running ? "Показать окно" : "Запустить") { start(c) }
        if running { Button("Остановить") { a.stop() } }
        Divider()
        Button("Настройки…") { a.settings() }.disabled(running)
        Button("Клонировать") { a.clone() }.disabled(running)
        Button("Сбросить данные…") { a.wipe() }.disabled(running)
        Button("Показать в Finder") { a.reveal() }
        Divider()
        Button("Удалить…", role: .destructive) { a.delete() }.disabled(running)
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { errorText = error.localizedDescription }
    }
}

struct InstanceRow: View {
    struct Actions {
        var stop: () -> Void
        var settings: () -> Void
        var clone: () -> Void
        var wipe: () -> Void
        var delete: () -> Void
        var reveal: () -> Void
    }

    let config: InstanceConfig
    let session: InstanceSession?
    let start: () -> Void
    let actions: Actions

    private var state: InstanceSession.State { session?.state ?? .stopped }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.gradient).frame(width: 40, height: 40)
                Image(systemName: config.isLandscape ? "ipad.landscape" : "iphone").foregroundStyle(.white).font(.system(size: 18))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(config.name).font(.headline)
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
                if case .failed(let e) = state {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(1)
                } else if state.isAlive {
                    Text(stateText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isAlive {
                Button("Показать", action: start)
                Button { actions.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Остановить (с сохранением быстрого старта)")
                    .disabled(state == .stopping)
            } else {
                Button { start() } label: { Label("Запустить", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            }
            Button { actions.settings() } label: { Image(systemName: "gearshape") }
                .help("Настройки инстанса").disabled(state.isAlive)
            Menu {
                Button("Клонировать") { actions.clone() }.disabled(state.isAlive)
                Button("Сбросить данные…") { actions.wipe() }.disabled(state.isAlive)
                Button("Показать в Finder") { actions.reveal() }
                Divider()
                Button("Удалить…", role: .destructive) { actions.delete() }.disabled(state.isAlive)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 6)
    }

    private var details: String {
        let image = SDKManager.shared.image(forPath: config.imagePath)
        let version = image?.title ?? config.platform
        return "\(version) · \(config.width)×\(config.height) · \(config.dpi) dpi · \(config.cpuCores) ядер · \(config.ramMB / 1024) ГБ"
    }

    private var stateText: String {
        var s = state.label
        if state == .running, let boot = session?.bootSeconds { s += String(format: " · загрузка %.1f с", boot) }
        return s
    }

    private var dotColor: Color {
        switch state {
        case .running: return .green
        case .starting, .booting, .preparing, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }
}
