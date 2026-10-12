import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showWiFi = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PortHole").font(.headline)

            if let error = model.startupError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }

            if model.needsExtensionApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Turn on PortHole in System Settings to see your phone in Finder.",
                          systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { model.openExtensionSettings() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            let rows = model.rows
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Android devices connected").foregroundStyle(.secondary)
                    Text("Connect your phone with USB, unlock it, and choose “File transfer”, or turn on USB debugging for faster access.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(rows) { row in
                    DeviceRowView(row: row)
                    if row.id != rows.last?.id { Divider() }
                }
            }

            if let problem = model.adbProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            DisclosureGroup("Connect over Wi-Fi", isExpanded: $showWiFi) {
                WiFiConnectView().padding(.top, 4)
            }
            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

private struct DeviceRowView: View {
    @Environment(AppModel.self) private var model
    let row: DeviceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: row.networkSerial != nil ? "wifi" : "cable.connector")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            if case .needsAction(let message) = row.status {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") { model.retry(row) }
                    if row.isMTPFailure {
                        Button("Release from Image Capture") { model.releaseFromCameraService() }
                            .help("Stops macOS's ptpcamerad, which can hold the phone's MTP interface")
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var subtitle: String {
        let transport = row.transport == .adb ? (row.networkSerial != nil ? "ADB · Wi-Fi" : "ADB · USB") : "MTP · USB"
        switch row.status {
        case .mounted: return "\(transport) · Mounted"
        case .unmounted: return "\(transport) · Not mounted"
        case .connecting: return "\(transport) · Connecting…"
        case .duplicate: return "\(transport) · Using ADB instead"
        case .needsAction: return transport
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch row.status {
            case .mounted:
                Button { model.open(row.id) } label: { Image(systemName: "folder") }.help("Show in Finder")
                Button { model.refresh(row.id) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { model.setMounted(row.id, false) } label: { Image(systemName: "eject") }.help("Unmount")
            case .unmounted:
                Button("Mount") { model.setMounted(row.id, true) }
            case .connecting:
                ProgressView().controlSize(.small)
            case .duplicate, .needsAction:
                EmptyView()
            }
            if let serial = row.networkSerial {
                Button { model.disconnectWiFi(serial) } label: { Image(systemName: "xmark.circle") }.help("Disconnect")
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct WiFiConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var message: String?
    @State private var isError = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone: Settings › Developer options › Wireless debugging.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("IP address:port", text: $address).textFieldStyle(.roundedBorder)
                Button("Connect") { run { await model.connectWiFi(address) } }
                    .disabled(address.isEmpty || busy)
            }
            Text("First time? Tap “Pair device with pairing code” on the phone:")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("IP:port", text: $pairAddress).textFieldStyle(.roundedBorder)
                TextField("Code", text: $pairCode).textFieldStyle(.roundedBorder).frame(width: 70)
                Button("Pair") { run { await model.pairWiFi(pairAddress, code: pairCode) } }
                    .disabled(pairAddress.isEmpty || pairCode.isEmpty || busy)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(isError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(_ action: @escaping () async -> Result<String, Error>) {
        busy = true
        Task {
            switch await action() {
            case .success(let text):
                message = text
                isError = false
            case .failure(let error):
                message = error.localizedDescription
                isError = true
            }
            busy = false
        }
    }
}
