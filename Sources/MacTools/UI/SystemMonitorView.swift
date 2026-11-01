import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject var model: SystemMonitorModel
    @AppStorage("showSystemMonitorMenuBar") private var showInMenuBar = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("System Monitor").font(.system(size: 28, weight: .semibold))
                if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Toggle("Menu bar", isOn: $showInMenuBar).toggleStyle(.checkbox).font(.system(size: 12))
                HelpTip(text: Self.help, label: "About system monitor")
            }
            .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 30)

            ScrollView {
                VStack(spacing: 0) {
                    metric("CPU", value: percent(model.snapshot?.cpuPercent), symbol: "cpu", fraction: (model.snapshot?.cpuPercent).map { min(1, max(0, $0 / 100)) })
                    Divider()
                    metric("Active memory", value: memory, symbol: "memorychip", fraction: memoryFraction)
                    Divider()
                    metric("Storage", value: storage, symbol: "internaldrive", fraction: storageFraction)
                    Divider()
                    metric("Disk activity", value: "↓ \(rate(model.snapshot?.diskRead))   ↑ \(rate(model.snapshot?.diskWrite))", symbol: "arrow.up.arrow.down")
                        .accessibilityLabel("Disk activity, read \(rate(model.snapshot?.diskRead)), write \(rate(model.snapshot?.diskWrite))")
                    Divider()
                    metric("Network", value: "↓ \(rate(model.snapshot?.networkReceive))   ↑ \(rate(model.snapshot?.networkSend))", symbol: "network")
                        .accessibilityLabel("Network, received \(rate(model.snapshot?.networkReceive)), sent \(rate(model.snapshot?.networkSend))")
                }.padding(.horizontal, 36)
            }
            Divider()
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.isRunning ? "Updating every 2 seconds" : "Paused")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh readings").accessibilityLabel("Refresh readings")
            }.padding(.horizontal, 36).padding(.vertical, 18)
        }
        .background(Palette.panel)
    }

    private func metric(_ name: String, value: String, symbol: String, fraction: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 15) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 26)
                Text(name).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 20)
                Text(value).font(.system(size: 16)).monospacedDigit().textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            if let fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Palette.accent.opacity(0.10))
                        RoundedRectangle(cornerRadius: 4).fill(Palette.accent)
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                }
                .frame(height: 6)
                .padding(.leading, 41)
            }
        }.padding(.vertical, 24)
    }

    private var memoryFraction: Double? {
        guard let value = model.snapshot, let used = value.memoryUsed, value.memoryTotal > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(value.memoryTotal)))
    }
    private var storageFraction: Double? {
        guard let value = model.snapshot, let used = value.diskUsed, let total = value.diskTotal, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    private var memory: String {
        guard let value = model.snapshot, let used = value.memoryUsed else { return "Unavailable" }
        return "\(bytes(Int64(clamping: used))) / \(bytes(Int64(clamping: value.memoryTotal)))"
    }
    private var storage: String {
        guard let value = model.snapshot, let used = value.diskUsed, let total = value.diskTotal else { return "Unavailable" }
        return "\(bytes(used)) / \(bytes(total))"
    }
    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }

    static let help = "CPU is averaged across all cores. Active memory includes active, wired, and compressed pages; it differs from Activity Monitor’s Memory Used. Storage is used space on your home volume. Disk activity covers available physical storage drivers. Network totals active Ethernet, Wi-Fi, and cellular interfaces, excluding loopback, bridges, and VPN tunnels. Rates need two readings; unavailable metrics show a dash. No network requests are made."
}

struct SystemMonitorMenuView: View {
    @ObservedObject var model: SystemMonitorModel

    var body: some View {
        if model.isDemo { Text("Demo readings") }
        Text(model.summaryTitle)
        if let value = model.snapshot {
            if let used = value.memoryUsed { Text("Active memory: \(bytes(Int64(clamping: used)))") }
            if let used = value.diskUsed, let total = value.diskTotal { Text("Storage: \(bytes(used)) / \(bytes(total))") }
            Text("Disk: ↓ \(rate(value.diskRead))  ↑ \(rate(value.diskWrite))")
            Text("Network: ↓ \(rate(value.networkReceive))  ↑ \(rate(value.networkSend))")
        }
        Divider()
        Button("Refresh") { model.refresh() }
    }
}

private func rate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
    return "\(bytes(Int64(value.rounded())))/s"
}
