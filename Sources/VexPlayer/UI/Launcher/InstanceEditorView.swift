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

    /// Every installed image is offered as is and as Lite; Android 16 and newer also as Minimal.
    private struct ImageChoice: Hashable {
        let path: String
        let edition: ImageEdition
    }

    private var imageChoice: Binding<ImageChoice> {
        Binding(
            get: { ImageChoice(path: config.imagePath, edition: config.edition) },
            set: { choice in
                if choice.edition != config.edition {
                    config.ramMB = InstanceConfig.defaultRAM(for: choice.edition)
                }
                config.imagePath = choice.path
                config.edition = choice.edition
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $config.name)
                    Picker("Android", selection: imageChoice) {
                        ForEach(sdk.installedImages) { img in
                            Text(img.title).tag(ImageChoice(path: img.path, edition: .full))
                            Text("\(img.title) Lite").tag(ImageChoice(path: img.path, edition: .lite))
                            if img.apiMajor >= LiteEdition.minimalMinAPI || (img.path == config.imagePath && config.isMinimal) {
                                Text("\(img.title) Minimal").tag(ImageChoice(path: img.path, edition: .minimal))
                            }
                        }
                    }
                    .disabled(!isNew)
                    if config.isMinimal {
                        Text("Minimal: Lite without Google Play services, Play Store, Gboard and the system apps a game and a browser don't need; Bluetooth, location and background scanning are off. Android uses about 0.3 GB less memory than Lite and the idle instance wakes the Mac less. Install games from the browser; apps that need Google services (Play Store, Google sign-in, push notifications) won't work. Anything can be turned back on in Android's Settings → Apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if config.isLite {
                        Text("Lite: the same Android without the Google apps and services a game doesn't need (Assistant, Photos, Gmail, Maps, YouTube and more). Android uses about 0.5 GB less memory, so the instance gets 1 GB less RAM by default. Disabled apps can be turned back on in Android's Settings → Apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !isNew {
                        Text("The Android version of an existing instance can't be changed. Create a new instance or clone this one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Performance") {
                    Stepper("CPU cores: \(config.cpuCores) of \(InstanceConfig.hostCores)",
                            value: $config.cpuCores, in: 1...max(1, InstanceConfig.hostCores))
                    Picker("Memory", selection: $config.ramMB) {
                        ForEach(ramOptions, id: \.self) { mb in Text("\(InstanceConfig.gigabytes(mb)) GB").tag(mb) }
                    }
                    Picker("Graphics", selection: $config.gpuMode) {
                        ForEach(GPUMode.allCases) { Text($0.title).tag($0) }
                    }
                    if config.effectiveGPUMode != config.gpuMode {
                        Text("Android 14 and older can't draw through Vulkan on a Mac, so this instance uses OpenGL (GLES 3.0).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if config.effectiveGPUMode.supportsQuickboot {
                        Toggle("Quickboot (save the state when stopping)", isOn: $config.fastBoot)
                    } else {
                        Toggle("Quickboot (save the state when stopping)", isOn: .constant(false)).disabled(true)
                        Text("The emulator can't restore a Vulkan screen from a snapshot (the picture freezes), so this instance always does a full boot: 10–30 s.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Recommended: no more than \(InstanceConfig.performanceCores) cores (the Mac's performance cores keep games smooth) and no more than half of the RAM (\(InstanceConfig.hostRAMMB / 1024) GB).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Screen") {
                    Picker("Resolution", selection: $preset) {
                        ForEach(DisplayPreset.all) { Text($0.title).tag($0.id) }
                        Text("Custom").tag("custom")
                    }
                    .onChange(of: preset) { _, id in
                        guard let p = DisplayPreset.all.first(where: { $0.id == id }) else { return }
                        config.width = p.width
                        config.height = p.height
                        config.dpi = p.dpi
                    }
                    if preset == "custom" {
                        HStack {
                            TextField("Width", value: $config.width, format: .number.grouping(.never))
                            Text("×")
                            TextField("Height", value: $config.height, format: .number.grouping(.never))
                            TextField("DPI", value: $config.dpi, format: .number.grouping(.never)).frame(width: 70)
                        }
                    }
                    Picker("Refresh rate", selection: $config.refreshRate) {
                        Text("60 Hz").tag(60)
                        Text("90 Hz").tag(90)
                        Text("120 Hz (ProMotion)").tag(120)
                    }
                }

                Section("Other") {
                    Toggle("Sound", isOn: $config.audioEnabled)
                    Toggle("Microphone", isOn: $config.microphoneEnabled)
                    Picker("Device model", selection: $config.deviceProfile) {
                        Text("Android emulator (no masking)").tag(String?.none)
                        ForEach(DeviceProfile.all) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .disabled(!(image?.supportsRoot ?? false))
                    if !(image?.supportsRoot ?? false) {
                        Text("Device masking works on Google APIs images: Google Play images keep their system partitions locked. Some games refuse “Android SDK” devices on their servers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Root (adb root) on start", isOn: $config.rootOnBoot)
                        .disabled(!(image?.supportsRoot ?? false))
                    if !(image?.supportsRoot ?? false) {
                        Text("Root is only available on Google APIs images (without the Play Store).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Disk size", selection: $config.dataSizeGB) {
                        ForEach([8, 16, 32, 64, 128], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .disabled(!isNew)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let errorText { Text(errorText).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(config.name.isEmpty || config.imagePath.isEmpty || config.width < 320 || config.height < 320)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    private var ramOptions: [Int] {
        [2048, 2560, 3072, 4096, 6144, 8192, 12288, 16384].filter { $0 <= max(2048, InstanceConfig.hostRAMMB - 2048) }
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
