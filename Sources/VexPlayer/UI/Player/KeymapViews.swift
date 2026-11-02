import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Semi-transparent key labels over the game, like MuMu's on-screen hints.
struct KeymapHintsView: View {
    let map: Keymap
    let rect: CGRect
    let aspect: Double

    var body: some View {
        ZStack {
            ForEach(map.controls) { c in
                ControlGlyph(control: c, rect: rect, selected: false)
                    .position(x: rect.minX + c.x * rect.width, y: rect.minY + c.y * rect.height)
                if c.kind == .swipe {
                    SwipeArrow(control: c, rect: rect)
                }
            }
        }
        .opacity(map.hintOpacity)
    }
}

/// Visual for one control (used by both hints and editor).
struct ControlGlyph: View {
    let control: KeyControl
    let rect: CGRect
    let selected: Bool

    var body: some View {
        let radiusPx = control.radius * rect.width
        ZStack {
            switch control.kind {
            case .joystick:
                Circle().stroke(Color.white.opacity(0.8), lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: radiusPx * 2, height: radiusPx * 2)
                if control.keys.count == 4 {
                    keyCap(KeyCode.name(control.keys[0])).offset(y: -radiusPx)
                    keyCap(KeyCode.name(control.keys[1])).offset(x: -radiusPx)
                    keyCap(KeyCode.name(control.keys[2])).offset(y: radiusPx)
                    keyCap(KeyCode.name(control.keys[3])).offset(x: radiusPx)
                }
            case .aim:
                Circle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.white.opacity(0.6))
                    .frame(width: radiusPx * 2, height: radiusPx * 2)
                VStack(spacing: 2) {
                    Image(systemName: "scope").font(.system(size: 18, weight: .semibold))
                    keyCap(control.label)
                }
            case .skill:
                Circle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(.white.opacity(0.5))
                    .frame(width: radiusPx * 2, height: radiusPx * 2)
                keyCap(control.label, symbol: "sparkles")
            case .fire:
                keyCap(control.label, symbol: "flame.fill")
            case .repeatTap:
                keyCap(control.label, symbol: "repeat")
            case .swipe:
                keyCap(control.label, symbol: "hand.draw")
            case .tap:
                keyCap(control.label)
            }
        }
        .foregroundStyle(.white)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(-6)
            }
        }
    }

    private func keyCap(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.7), lineWidth: 1))
    }
}

struct SwipeArrow: View {
    let control: KeyControl
    let rect: CGRect
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + control.x * rect.width, y: rect.minY + control.y * rect.height))
            p.addLine(to: CGPoint(x: rect.minX + control.x2 * rect.width, y: rect.minY + control.y2 * rect.height))
        }
        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }
}

// MARK: - Editor

private enum BindSlot: Equatable {
    case primary(UUID)
    case joystick(UUID, Int)
}

struct KeymapEditorView: View {
    let session: InstanceSession
    let rect: CGRect
    @Binding var isPresented: Bool

    @State private var map: Keymap
    @State private var selection: UUID?
    @State private var binding: BindSlot?
    @State private var monitor: Any?
    /// Set only by "Отменить изменения"; every other way of closing saves.
    @State private var discard = false

    init(session: InstanceSession, rect: CGRect, isPresented: Binding<Bool>) {
        self.session = session
        self.rect = rect
        _isPresented = isPresented
        _map = State(initialValue: session.keymap)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture { selection = nil; binding = nil }

            ForEach($map.controls) { $c in
                if c.kind == .swipe {
                    SwipeArrow(control: c, rect: rect).allowsHitTesting(false)
                    Circle().fill(Color.accentColor.opacity(0.8)).frame(width: 14, height: 14)
                        .position(x: rect.minX + c.x2 * rect.width, y: rect.minY + c.y2 * rect.height)
                        .gesture(DragGesture(coordinateSpace: .named("editor")).onChanged { v in
                            c.x2 = clampU(v.location.x)
                            c.y2 = clampV(v.location.y)
                        })
                }
                ControlGlyph(control: c, rect: rect, selected: selection == c.id)
                    .contentShape(Rectangle())
                    .position(x: rect.minX + c.x * rect.width, y: rect.minY + c.y * rect.height)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))
                        .onChanged { v in
                            selection = c.id
                            c.x = clampU(v.location.x)
                            c.y = clampV(v.location.y)
                        })
                    .simultaneousGesture(TapGesture().onEnded { selection = c.id })
            }

            VStack(spacing: 8) {
                toolbar
                HStack(alignment: .top) {
                    if let idx = map.controls.firstIndex(where: { $0.id == selection }) {
                        inspector($map.controls[idx])
                    }
                    Spacer()
                }
            }
            .padding(10)
        }
        .coordinateSpace(name: "editor")
        .onAppear(perform: installMonitor)
        .onDisappear {
            removeMonitor()
            if !discard { session.saveKeymap(map) }
        }
    }

    private func clampU(_ x: CGFloat) -> Double { Double(min(max((x - rect.minX) / max(rect.width, 1), 0), 1)) }
    private func clampV(_ y: CGFloat) -> Double { Double(min(max((y - rect.minY) / max(rect.height, 1), 0), 1)) }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            schemeMenu
            Text(session.foregroundPackage ?? "общий профиль")
                .font(.caption2.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                .frame(maxWidth: 150, alignment: .leading)
                .help("Схемы хранятся отдельно для каждой игры")
            Divider().frame(height: 18)
            ForEach(KeyControlKind.allCases) { kind in
                Button {
                    var c = KeyControl.make(kind, at: 0.5, 0.5)
                    if kind == .tap || kind == .repeatTap || kind == .skill || kind == .swipe { c.key = nil }
                    map.controls.append(c)
                    selection = c.id
                    if c.key == nil { binding = .primary(c.id) }
                } label: {
                    Label(kind.title, systemImage: kind.symbol).labelStyle(.iconOnly)
                }
                .help("Добавить: \(kind.title)")
            }
            Button(role: .destructive) {
                map.controls.removeAll()
                selection = nil
            } label: {
                Label("Очистить", systemImage: "trash").labelStyle(.iconOnly)
            }
            .help("Убрать все элементы из схемы")
            .disabled(map.controls.isEmpty)
            Divider().frame(height: 18)
            Toggle("Подсказки", isOn: $map.showHints).toggleStyle(.checkbox)
            Slider(value: $map.hintOpacity, in: 0.15...1).frame(width: 70).help("Прозрачность подсказок")
            Divider().frame(height: 18)
            Button("Отменить изменения") {
                discard = true
                isPresented = false
            }
            Button("Готово") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .help("Сохраняется автоматически при закрытии редактора")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Schemes

    private var schemeMenu: some View {
        Menu {
            ForEach(session.keymapProfile.schemes) { scheme in
                Button {
                    switchScheme(to: scheme.id)
                } label: {
                    if scheme.id == session.activeScheme?.id {
                        Label(scheme.name, systemImage: "checkmark")
                    } else {
                        Text(scheme.name)
                    }
                }
            }
            Divider()
            Button("Новая пустая схема") { newScheme(copy: false) }
            Button("Копия текущей схемы") { newScheme(copy: true) }
            Button("Переименовать…") { renameActive() }
            Button("Удалить схему…", role: .destructive) { deleteActive() }
                .disabled(session.keymapProfile.schemes.count < 2)
            Divider()
            Button("Экспорт схемы…") { exportActive() }
            Button("Импорт схемы…") { importScheme() }
        } label: {
            Label(session.activeScheme?.name ?? "Схема", systemImage: "list.bullet.rectangle")
        }
        .fixedSize()
        .help("Схемы управления этой игры")
    }

    /// Keep edits of the scheme we leave, then load the other one.
    private func switchScheme(to id: UUID) {
        session.saveKeymap(map)
        session.selectScheme(id)
        map = session.keymap
        selection = nil
        binding = nil
    }

    private func newScheme(copy: Bool) {
        session.saveKeymap(map)
        session.createScheme(copyingActive: copy)
        map = session.keymap
        selection = nil
    }

    private func renameActive() {
        guard let scheme = session.activeScheme else { return }
        let alert = NSAlert()
        alert.messageText = "Название схемы"
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(string: scheme.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            session.saveKeymap(map)
            session.renameScheme(scheme.id, to: field.stringValue)
        }
    }

    private func deleteActive() {
        guard let scheme = session.activeScheme else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить схему «\(scheme.name)»?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.deleteScheme(scheme.id)
        map = session.keymap
        selection = nil
    }

    private func exportActive() {
        guard var scheme = session.activeScheme else { return }
        scheme.keymap = map
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(scheme.name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? KeymapStore.export(scheme, to: url)
    }

    private func importScheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scheme = try KeymapStore.importScheme(from: url)
            session.saveKeymap(map)
            session.addImportedScheme(scheme)
            map = session.keymap
            selection = nil
        } catch {
            session.showToast("Не удалось импортировать: \(error.localizedDescription)")
        }
    }

    // MARK: Inspector

    private func inspector(_ c: Binding<KeyControl>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(c.wrappedValue.kind.title, systemImage: c.wrappedValue.kind.symbol).font(.headline)
                Spacer()
                Button(role: .destructive) {
                    map.controls.removeAll { $0.id == c.wrappedValue.id }
                    selection = nil
                } label: { Image(systemName: "trash") }
                .help("Удалить (⌫)")
            }
            switch c.wrappedValue.kind {
            case .joystick:
                HStack {
                    ForEach(0..<4, id: \.self) { i in
                        bindButton(.joystick(c.wrappedValue.id, i), label: ["↑", "←", "↓", "→"][i],
                                   value: c.wrappedValue.keys.indices.contains(i) ? c.wrappedValue.keys[i] : nil)
                    }
                }
                slider("Ход стика", c.radius, 0.02...0.2)
            case .aim:
                bindRow(c, title: "Клавиша захвата курсора")
                slider("Чувствительность", c.sensitivity, 0.2...4)
                slider("Зона обзора", c.radius, 0.04...0.35)
            case .skill:
                bindRow(c, title: "Клавиша")
                slider("Дальность", c.radius, 0.03...0.25)
            case .repeatTap:
                bindRow(c, title: "Клавиша")
                Stepper("Интервал: \(c.wrappedValue.intervalMS) мс", value: c.intervalMS, in: 20...1000, step: 10)
            case .fire:
                bindRow(c, title: "Клавиша (ЛКМ — при захвате курсора)")
            case .swipe:
                bindRow(c, title: "Клавиша")
                Text("Перетащите синюю точку — конец свайпа").font(.caption).foregroundStyle(.secondary)
            case .tap:
                bindRow(c, title: "Клавиша")
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .controlSize(.small)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }

    private func bindRow(_ c: Binding<KeyControl>, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                bindButton(.primary(c.wrappedValue.id), label: nil, value: c.wrappedValue.key)
                Menu("Мышь / геймпад") {
                    Button("Левая кнопка мыши") { c.wrappedValue.key = KeyCode.mouseLeft }
                    Button("Правая кнопка мыши") { c.wrappedValue.key = KeyCode.mouseRight }
                    Button("Средняя кнопка мыши") { c.wrappedValue.key = KeyCode.mouseMiddle }
                    Divider()
                    ForEach(GamepadButton.allCases, id: \.rawValue) { b in
                        Button("Геймпад \(b.label)") { c.wrappedValue.key = KeyCode.gamepadBase + b.rawValue }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func bindButton(_ slot: BindSlot, label: String?, value: Int?) -> some View {
        let waiting = binding == slot
        return Button {
            binding = waiting ? nil : slot
        } label: {
            Text(waiting ? "Нажмите…" : [label, value.map(KeyCode.name)].compactMap { $0 }.joined(separator: " "))
                .frame(minWidth: 44)
        }
        .tint(waiting ? .accentColor : nil)
        .buttonStyle(.bordered)
    }

    // MARK: Key capture

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard binding != nil, !event.modifierFlags.intersection([.shift, .control, .option]).isEmpty else { return event }
                assign(Int(event.keyCode))
                return nil
            }
            if event.modifierFlags.contains(.command) { return event }
            if binding != nil {
                assign(Int(event.keyCode))
                return nil
            }
            if (event.keyCode == 51 || event.keyCode == 117), let sel = selection {
                map.controls.removeAll { $0.id == sel }
                selection = nil
                return nil
            }
            if event.keyCode == UInt16(KeyCode.escape) || event.keyCode == UInt16(KeyCode.returnKey) {
                isPresented = false   // closing saves
                return nil
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func assign(_ code: Int) {
        guard let slot = binding else { return }
        switch slot {
        case .primary(let id):
            if let i = map.controls.firstIndex(where: { $0.id == id }) { map.controls[i].key = code }
        case .joystick(let id, let k):
            if let i = map.controls.firstIndex(where: { $0.id == id }) {
                while map.controls[i].keys.count < 4 { map.controls[i].keys.append(0) }
                map.controls[i].keys[k] = code
            }
        }
        binding = nil
    }
}
