import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.enableADB) private var enableADB = true
    @AppStorage(SettingsKey.enableMTP) private var enableMTP = true
    @AppStorage(SettingsKey.preferADB) private var preferADB = true
    @AppStorage(SettingsKey.adbPath) private var adbPath = ""
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 30
    @AppStorage(SettingsKey.openFinderOnMount) private var openFinderOnMount = false
    @AppStorage(SettingsKey.cacheLimitMB) private var cacheLimitMB = 2048

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
                Picker("Keep opened phone files on this Mac", selection: $cacheLimitMB) {
                    Text("Up to 500 MB").tag(500)
                    Text("Up to 2 GB").tag(2048)
                    Text("Up to 10 GB").tag(10240)
                }
                Text("Older copies are removed from the Mac automatically (never from the phone), and all of them when the Mac is low on space.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: cacheLimitMB) { model.applySettings() }
    }
}
