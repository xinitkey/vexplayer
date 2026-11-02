import SwiftUI

/// First run: download the emulator engine, platform-tools and one Android image.
struct SetupView: View {
    @State private var sdk = SDKManager.shared
    @State private var imagePath: String?
    @State private var accepted = false
    @State private var showLicenses = false
    @State private var installing = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "apple.terminal.on.rectangle")
                        .font(.system(size: 46)).foregroundStyle(Color.accentColor)
                    Text("VexPlayer").font(.largeTitle.bold())
                    Text("Android for Apple Silicon: native ARM64 without translation, Hypervisor.framework and GPU through Metal.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
                }

                if let catalog = sdk.catalog {
                    form(catalog)
                } else if sdk.isLoadingCatalog {
                    ProgressView("Loading the Android catalog…").padding()
                } else {
                    VStack(spacing: 8) {
                        Text(sdk.catalogError ?? String(localized: "The catalog didn't load")).foregroundStyle(.red)
                        Button("Retry") { Task { await sdk.refreshCatalog() } }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .task { if sdk.catalog == nil { await sdk.refreshCatalog() } }
        .sheet(isPresented: $showLicenses) { LicenseSheet(ids: neededLicenses) }
    }

    private func form(_ catalog: SDKCatalog) -> some View {
        let packages = selectedPackages(catalog)
        let total = packages.filter { !$0.isInstalled }.reduce(Int64(0)) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Android version", selection: Binding(get: { imagePath ?? catalog.recommendedImage?.path }, set: { imagePath = $0 })) {
                ForEach(catalog.systemImages) { img in
                    Text("\(img.title) — \(formatBytes(img.size))").tag(Optional(img.path))
                }
            }
            .disabled(installing)
            Text("Google Play includes the Play Store. Google APIs has no Play Store but allows root through adb. You can download other versions later.")
                .font(.caption).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(packages) { p in
                        PackageProgressRow(package: p, progress: sdk.progress[p.path])
                    }
                }
                .padding(4)
            }

            HStack {
                Toggle("I accept the Android SDK license agreements", isOn: $accepted).disabled(installing)
                Button("Read…") { showLicenses = true }.buttonStyle(.link)
            }

            HStack {
                if let errorText { Text(errorText).foregroundStyle(.red).font(.caption) }
                Spacer()
                if installing {
                    Button("Cancel") { sdk.cancelAll() }
                }
                Button {
                    install(packages)
                } label: {
                    Text(total > 0 ? "Download and install (\(formatBytes(total)))" : "Done")
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!accepted || installing)
            }
        }
        .frame(maxWidth: 620)
    }

    private func selectedPackages(_ catalog: SDKCatalog) -> [SDKPackage] {
        let image = catalog.systemImages.first { $0.path == (imagePath ?? catalog.recommendedImage?.path) }
        return [catalog.emulator, catalog.platformTools, image].compactMap { $0 }
    }

    private var neededLicenses: [String] {
        guard let catalog = sdk.catalog else { return [] }
        return Array(Set(selectedPackages(catalog).map(\.licenseID))).sorted()
    }

    private func install(_ packages: [SDKPackage]) {
        installing = true
        errorText = nil
        sdk.acceptLicenses(Set(packages.map(\.licenseID)))
        Task {
            defer { installing = false }
            do {
                try await sdk.install(packages)
                // Create a ready-to-go instance on first setup.
                let store = InstanceStore.shared
                if store.instances.isEmpty, let img = packages.first(where: \.isSystemImage) {
                    try store.create(InstanceConfig(id: store.nextID(), name: store.nextName(), imagePath: img.path))
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

struct PackageProgressRow: View {
    let package: SDKPackage
    let progress: InstallProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(package.title).font(.callout.weight(.medium))
                if !package.isSystemImage { Text(package.revision).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if package.isInstalled && !(progress?.isActive ?? false) {
                    Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else {
                    Text(progress?.label ?? formatBytes(package.size)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = progress, p.isActive {
                ProgressView(value: p.fraction).progressViewStyle(.linear)
            }
        }
    }
}

struct LicenseSheet: View {
    let ids: [String]
    var onAccept: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("License agreements").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ids, id: \.self) { id in
                        Text(id).font(.headline)
                        Text(SDKManager.shared.catalog?.licenses[id]?.text ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                if let onAccept {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Accept and download") {
                        onAccept()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 700, height: 560)
    }
}

/// Download / remove Android versions.
struct ImageManagerView: View {
    @State private var sdk = SDKManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?
    @State private var pendingLicense: SDKPackage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Android images").font(.title2.bold())
                Spacer()
                if sdk.isLoadingCatalog { ProgressView().controlSize(.small) }
                Button { Task { await sdk.refreshCatalog() } } label: { Image(systemName: "arrow.clockwise") }
            }
            Text("All images are native ARM64: on Apple Silicon they run without instruction translation.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(images) { img in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(img.title).font(.callout.weight(.medium))
                            (Text("API \(img.apiString ?? "?") · rev. \(img.revision)") + Text(img.supportsRoot ? " · root through adb" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if let p = sdk.progress[img.path], p.isActive {
                                ProgressView(value: p.fraction)
                                Text(p.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if img.isInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                            Button("Remove") { remove(img) }.disabled(isUsed(img))
                                .help(isUsed(img) ? "Used by an instance" : "")
                        } else {
                            Text(formatBytes(img.size)).font(.caption).foregroundStyle(.secondary)
                            Button("Download") { install(img) }
                                .disabled(sdk.progress[img.path]?.isActive ?? false)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            HStack {
                if let errorText { Text(errorText).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 560)
        .task { if sdk.catalog == nil { await sdk.refreshCatalog() } }
        .sheet(item: $pendingLicense) { img in
            LicenseSheet(ids: [img.licenseID]) {
                sdk.acceptLicenses([img.licenseID])
                install(img)
            }
        }
    }

    private var images: [SDKPackage] {
        var list = sdk.catalog?.systemImages ?? []
        for local in sdk.installedImages where !list.contains(where: { $0.path == local.path }) { list.append(local) }
        return list
    }

    private func isUsed(_ img: SDKPackage) -> Bool {
        InstanceStore.shared.instances.contains { $0.imagePath == img.path }
    }

    private func install(_ img: SDKPackage) {
        errorText = nil
        guard sdk.isLicenseAccepted(img.licenseID) else {
            pendingLicense = img
            return
        }
        Task {
            do { try await sdk.install([img]) } catch { errorText = error.localizedDescription }
        }
    }

    private func remove(_ img: SDKPackage) {
        do { try sdk.uninstall(img) } catch { errorText = error.localizedDescription }
    }
}
