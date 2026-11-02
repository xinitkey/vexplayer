import SwiftUI

struct InstanceEditorView: View {
    let target: EditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var config: InstanceConfig
    @State private var preset: String
    @State private var errorText: String?
    private let sdk = SDKManager.shared

    init(target: EditorTarget) {
        self.target = target
        let store = InstanceStore.shared
        let initial: InstanceConfig
        switch target {
        case .new:
            let image = SDKManager.shared.installedImages.first { $0.hasPlayStore } ?? SDKManager.shared.installedImages.first
            initial = InstanceConfig(id: store.nextID(), name: store.nextName(), imagePath: image?.path ?? "")
        case .edit(let c):
            initial = c
        }
        _config = State(initialValue: initial)
        _preset = State(initialValue: DisplayPreset.all.first {
            $0.width == initial.width && $0.height == initial.height && $0.dpi == initial.dpi
        }?.id ?? "custom")
    }

    private var isNew: Bool { if case .new = target { return true } else { return false } }
    private var image: SDKPackage? { sdk.image(forPath: config.imagePath) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Основное") {
                    TextField("Название", text: $config.name)
                    Picker("Android", selection: $config.imagePath) {
                        ForEach(sdk.installedImages) { img in Text(img.title).tag(img.path) }
                    }
                    .disabled(!isNew)
                    if !isNew {
                        Text("Версию Android нельзя сменить у существующего инстанса — создайте новый или клонируйте.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Производительность") {
                    Stepper("Ядра CPU: \(config.cpuCores) из \(InstanceConfig.hostCores)",
                            value: $config.cpuCores, in: 1...max(1, InstanceConfig.hostCores))
                    Picker("Память", selection: $config.ramMB) {
                        ForEach(ramOptions, id: \.self) { mb in Text("\(mb / 1024) ГБ").tag(mb) }
                    }
                    Picker("Графика", selection: $config.gpuMode) {
                        ForEach(GPUMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Быстрый старт (сохранять состояние при выключении)", isOn: $config.fastBoot)
                    Text("Рекомендуем: ядер не больше \(InstanceConfig.performanceCores) (производительные ядра Mac — на них игры идут ровнее), память — не больше половины ОЗУ (\(InstanceConfig.hostRAMMB / 1024) ГБ).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Экран") {
                    Picker("Разрешение", selection: $preset) {
                        ForEach(DisplayPreset.all) { Text($0.title).tag($0.id) }
                        Text("Своё").tag("custom")
                    }
                    .onChange(of: preset) { _, id in
                        guard let p = DisplayPreset.all.first(where: { $0.id == id }) else { return }
                        config.width = p.width
                        config.height = p.height
                        config.dpi = p.dpi
                    }
                    if preset == "custom" {
                        HStack {
                            TextField("Ширина", value: $config.width, format: .number.grouping(.never))
                            Text("×")
                            TextField("Высота", value: $config.height, format: .number.grouping(.never))
                            TextField("DPI", value: $config.dpi, format: .number.grouping(.never)).frame(width: 70)
                        }
                    }
                    Picker("Частота обновления", selection: $config.refreshRate) {
                        Text("60 Гц").tag(60)
                        Text("90 Гц").tag(90)
                        Text("120 Гц (ProMotion)").tag(120)
                    }
                }

                Section("Прочее") {
                    Toggle("Звук", isOn: $config.audioEnabled)
                    Toggle("Микрофон", isOn: $config.microphoneEnabled)
                    Picker("Модель устройства", selection: $config.deviceProfile) {
                        Text("Эмулятор Android (без подмены)").tag(String?.none)
                        ForEach(DeviceProfile.all) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .disabled(!(image?.supportsRoot ?? false))
                    if !(image?.supportsRoot ?? false) {
                        Text("Подмена модели работает на образах Google APIs: в образах с Google Play системные разделы закрыты. Некоторые игры не пускают на серверы устройство «Android SDK».")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Root (adb root) при запуске", isOn: $config.rootOnBoot)
                        .disabled(!(image?.supportsRoot ?? false))
                    if !(image?.supportsRoot ?? false) {
                        Text("Root доступен только на образах Google APIs (без Play Маркета).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Размер диска", selection: $config.dataSizeGB) {
                        ForEach([8, 16, 32, 64, 128], id: \.self) { Text("\($0) ГБ").tag($0) }
                    }
                    .disabled(!isNew)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let errorText { Text(errorText).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Создать" : "Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(config.name.isEmpty || config.imagePath.isEmpty || config.width < 320 || config.height < 320)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    private var ramOptions: [Int] {
        [2048, 3072, 4096, 6144, 8192, 12288, 16384].filter { $0 <= max(2048, InstanceConfig.hostRAMMB - 2048) }
    }

    private func save() {
        config.dpi = min(max(config.dpi, 120), 640)
        do {
            if isNew { try InstanceStore.shared.create(config) } else { try InstanceStore.shared.update(config) }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
