import AppKit
import SwiftUI

struct NetworkPanel: View {
    @Bindable var monitor: NetworkMonitor
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statsColumn
            graphColumn
            appsSection
            Divider()
            footer
            if let loginMessage {
                Text(loginMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 400)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            loginMessage = launchAtLogin ? nil : LoginItem.statusMessage
        }
    }

    private var graphColumn: some View {
        VStack(spacing: 2) {
            modeMenu
            ActivityGraph(
                samples: monitor.samples,
                mode: monitor.graphMode,
                capacity: NetworkMonitor.historyLength
            )
            .frame(height: 72)
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(GraphMode.allCases) { mode in
                Button {
                    monitor.graphMode = mode
                } label: {
                    if monitor.graphMode == mode {
                        Label(mode.title.capitalized, systemImage: "checkmark")
                    } else {
                        Text(mode.title.capitalized)
                    }
                }
            }
        } label: {
            Text(monitor.graphMode.title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statsColumn: some View {
        VStack(spacing: 0) {
            switch monitor.graphMode {
            case .data:
                statRow("Data received:", value: NetworkFormat.bytes(Double(monitor.bytesIn)))
                hairline
                statRow("Data sent:", value: NetworkFormat.bytes(Double(monitor.bytesOut)))
                hairline
                statRow("Download:", value: NetworkFormat.speed(monitor.downloadBytesPerSecond), color: NetworkColor.download)
                hairline
                statRow("Upload:", value: NetworkFormat.speed(monitor.uploadBytesPerSecond), color: NetworkColor.upload)
            case .packets:
                statRow("Packets in:", value: NetworkFormat.packets(Double(monitor.packetsIn)))
                hairline
                statRow("Packets out:", value: NetworkFormat.packets(Double(monitor.packetsOut)))
                hairline
                statRow("Packets in/sec:", value: NetworkFormat.packetSpeed(monitor.downloadPacketsPerSecond), color: NetworkColor.download)
                hairline
                statRow("Packets out/sec:", value: NetworkFormat.packetSpeed(monitor.uploadPacketsPerSecond), color: NetworkColor.upload)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }

    private func statRow(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(color)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.vertical, 5)
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                monitor.showApps.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: monitor.showApps ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12, alignment: .center)
                    Text("Top 20 apps")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Top 20 apps")
            .accessibilityValue(monitor.showApps ? "expanded" : "collapsed")

            if monitor.showApps {
                appsBody
                    .frame(height: 188, alignment: .top)
                    .padding(.top, 6)
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private var appsBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !monitor.appsReady {
                Text("Measuring apps…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            } else if monitor.appTraffic.isEmpty {
                Text("No app traffic right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(monitor.appTraffic) { app in
                            appRow(app)
                        }
                    }
                }
            }
            Text("Live connections, refreshed every 2 seconds.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func appRow(_ app: AppTraffic) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("↓ \(NetworkFormat.speed(app.downloadPerSecond))")
                    .foregroundStyle(NetworkColor.download)
                    .monospacedDigit()
                Text("↑ \(NetworkFormat.speed(app.uploadPerSecond))")
                    .foregroundStyle(NetworkColor.upload)
                    .monospacedDigit()
            }
            Text("\(NetworkFormat.bytes(Double(app.bytesIn))) received · \(NetworkFormat.bytes(Double(app.bytesOut))) sent")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            interfaceMenu
            intervalMenu
            Spacer(minLength: 8)
            Toggle("Open at login", isOn: launchBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var interfaceMenu: some View {
        Menu {
            Button {
                monitor.interfaceID = NetworkCounters.allInterfaces
            } label: {
                menuItem("All interfaces", selected: monitor.interfaceID == NetworkCounters.allInterfaces)
            }
            if !monitor.interfaces.isEmpty {
                Divider()
            }
            ForEach(monitor.interfaces) { choice in
                Button {
                    monitor.interfaceID = choice.id
                } label: {
                    menuItem(choice.title, selected: monitor.interfaceID == choice.id)
                }
            }
        } label: {
            Text(monitor.selectedInterfaceTitle)
                .lineLimit(1)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("All interfaces uses the same non-loopback totals as Activity Monitor.")
    }

    private var intervalMenu: some View {
        Menu {
            ForEach([1.0, 2.0, 5.0], id: \.self) { seconds in
                Button {
                    monitor.interval = seconds
                } label: {
                    menuItem(intervalTitle(seconds), selected: monitor.interval == seconds)
                }
            }
        } label: {
            Text(intervalTitle(monitor.interval))
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Same choices as Activity Monitor’s Update Frequency. One second is the live reading.")
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: LoginItem.preferenceKey)
                do {
                    try LoginItem.setEnabled(newValue)
                    launchAtLogin = LoginItem.isEnabled
                    loginMessage = launchAtLogin ? nil : LoginItem.statusMessage
                    if newValue, !launchAtLogin {
                        loginMessage = LoginItem.statusMessage
                            ?? "Move MacNetSpeed into the Applications folder, then turn Open at login on again."
                    }
                } catch {
                    launchAtLogin = LoginItem.isEnabled
                    loginMessage = error.localizedDescription
                }
            }
        )
    }

    private func intervalTitle(_ seconds: Double) -> String {
        seconds == 1 ? "1 sec" : "\(Int(seconds)) sec"
    }

    @ViewBuilder
    private func menuItem(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
