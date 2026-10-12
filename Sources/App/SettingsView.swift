import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.enableADB) private var enableADB = true
    @AppStorage(SettingsKey.enableMTP) private var enableMTP = true
    @AppStorage(SettingsKey.preferADB) private var preferADB = true
    @AppStorage(SettingsKey.adbPath) private var adbPath = ""
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 30
    @AppStorage(SettingsKey.openFinderOnMount) private var openFinderOnMount = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Connections") {
                Toggle("MTP (File transfer mode)", isOn: $enableMTP)
                Toggle("ADB (USB debugging, USB or Wi-Fi)", isOn: $enableADB)
                Toggle("When both are available, use ADB", isOn: $preferADB)
                    .disabled(!(enableADB && enableMTP))
                TextField("adb path", text: $adbPath, prompt: Text(ADBHost.locateADB() ?? "Not found"))
                    .disabled(!enableADB)
            }
            Section("Finder") {
                Picker("Check phone for changes", selection: $refreshInterval) {
                    Text("Every 10 seconds").tag(10)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Only when I click Refresh").tag(0)
                }
                Toggle("Open in Finder when a phone is mounted", isOn: $openFinderOnMount)
            }
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: enableADB) { model.applySettings() }
        .onChange(of: enableMTP) { model.applySettings() }
        .onChange(of: preferADB) { model.applySettings() }
        .onChange(of: refreshInterval) { model.applySettings() }
    }
}
