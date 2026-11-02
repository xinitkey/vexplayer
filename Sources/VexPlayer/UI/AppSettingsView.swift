import SwiftUI

struct AppSettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Изображение") {
                Toggle("Вертикальная синхронизация (плавнее; выкл — меньше задержка)", isOn: $settings.vsync)
                Toggle("Показывать FPS в заголовке окна", isOn: $settings.showFPS)
            }
            Section("Ввод") {
                Toggle("Печатать на языке, выбранном на Mac (метод ввода VexPlayer)", isOn: $settings.macInputMethod)
                Toggle("Синхронизировать буфер обмена с Android", isOn: $settings.clipboardSync)
                Toggle("Инвертировать колесо мыши", isOn: $settings.invertWheel)
            }
            Section("Окна") {
                Toggle("Останавливать инстанс при закрытии окна", isOn: $settings.stopOnWindowClose)
                Toggle("Скрытые окна в фоновом режиме", isOn: $settings.backgroundWhenHidden)
                Text("Свёрнутый или закрытый инстанс продолжает работать на энергоэффективных ядрах и не мешает другим программам.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Ставить на паузу свёрнутые инстансы", isOn: $settings.pauseWhenMinimized)
                Text("Android в свёрнутом окне замирает и совсем не тратит процессор, а при разворачивании продолжает с того же места. Онлайн-игры за время паузы могут отключиться от сервера.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Движок (для опытных)") {
                Toggle("Qt-сборка со скрытым окном вместо headless", isOn: $settings.hiddenQtWindow)
                Toggle("Отразить кадры по вертикали", isOn: $settings.flipFrames)
                TextField("Доп. аргументы эмулятора", text: $settings.extraEmulatorArgs)
                    .font(.body.monospaced())
                Text("Изменения движка применяются при следующем запуске инстанса.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Данные") {
                LabeledContent("Папка VexPlayer") {
                    Button("Показать в Finder") { NSWorkspace.shared.open(AppPaths.root) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }
}
