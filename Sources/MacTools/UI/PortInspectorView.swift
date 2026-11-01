import SwiftUI

struct PortInspectorView: View {
    @ObservedObject var model: PortInspectorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if let banner = model.banner {
                bannerBar(banner)
                Divider()
            }
            content
            Divider()
            footer
        }
        .background(Palette.panel)
        .task { model.loadIfNeeded() }
        .sheet(item: $model.pendingStopItem) { item in
            PortStopConfirmationSheet(
                item: item,
                force: model.pendingForceStop,
                isDemo: model.isDemo,
                onCancel: model.cancelStop,
                onConfirm: model.confirmStop
            )
        }
        .alert("Active Ports", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Active Ports").font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)

            HelpTip(
                text: "Lists local processes listening on TCP or UDP ports. You can filter by port number or process name, reveal the executable in Finder, or stop user-owned processes after confirmation.",
                label: "About Active Ports"
            )
        }
        .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 22)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by port (e.g. 3000), process, or PID", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(8)
            .frame(maxWidth: 300)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))

            Picker("Protocol", selection: $model.transportFilter) {
                Text("All").tag(nil as NetworkTransportProtocol?)
                ForEach(NetworkTransportProtocol.allCases) { proto in
                    Text(proto.rawValue).tag(Optional(proto))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Toggle("My processes only", isOn: $model.onlyUserProcesses)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Spacer()
        }
        .padding(.horizontal, 36).padding(.vertical, 12)
    }

    private func bannerBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { model.banner = nil }
                .buttonStyle(.link).font(.system(size: 12))
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isRefreshing && model.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Inspecting local ports…").font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredItems.isEmpty {
            ContentUnavailableView(
                model.query.isEmpty ? "No listening ports found" : "No matching ports",
                systemImage: "network",
                description: Text(model.query.isEmpty ? "Refresh to scan active local TCP and UDP listeners." : "Try another port number or process name.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                portList
                    .frame(maxWidth: .infinity)
                Divider()
                detailPane
                    .frame(width: 310)
            }
        }
    }

    private var portList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Port").frame(width: 84, alignment: .leading)
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 68, alignment: .trailing)
                Text("Address").frame(width: 120, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredItems) { item in
                        portRow(item)
                        Divider()
                    }
                }
            }
        }
    }

    private func portRow(_ item: ListeningPortItem) -> some View {
        let isSelected = model.selectedItem?.id == item.id
        return Button {
            model.selectedID = item.id
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Text(String(item.port))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(item.transport.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 84, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.processName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    if let path = item.executablePath {
                        Text(displayPath(path))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(String(item.pid))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)

                Text("\(item.address) (\(item.ipVersion))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isSelected ? Palette.accent.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Port (\(item.port))") { model.copyText(String(item.port), label: "port \(item.port)") }
            Button("Copy PID (\(item.pid))") { model.copyText(String(item.pid), label: "PID \(item.pid)") }
            if item.executablePath != nil {
                Button("Show Executable in Finder") { model.revealExecutable(item) }
            }
            if item.isCurrentUser {
                Divider()
                Button("Quit Process…") { model.requestStop(item, force: false) }
                Button("Force Quit…", role: .destructive) { model.requestStop(item, force: true) }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = model.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.processName)
                            .font(.system(size: 18, weight: .semibold))
                        Text("\(item.transport.rawValue) · \(item.displayEndpoint) (\(item.ipVersion))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                    }

                    Divider()

                    detailField("Port", value: String(item.port))
                    detailField("Process ID (PID)", value: String(item.pid))
                    detailField("Bind Address", value: item.address)
                    if let path = item.executablePath {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Executable").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    model.revealExecutable(item)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Show executable in Finder")
                            }
                            Text(displayPath(path))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Button("Copy Port") {
                            model.copyText(String(item.port), label: "port \(item.port)")
                        }
                        .controlSize(.small)
                        Button("Copy PID") {
                            model.copyText(String(item.pid), label: "PID \(item.pid)")
                        }
                        .controlSize(.small)
                    }

                    if item.isCurrentUser {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Quit Process…") {
                                model.requestStop(item, force: false)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Force Quit…", role: .destructive) {
                                model.requestStop(item, force: true)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    } else {
                        Text("Owned by another system account.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(22)
            }
        }
    }

    private func detailField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.filteredItems.count) listening \(model.filteredItems.count == 1 ? "port" : "ports")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if let item = model.selectedItem, item.isCurrentUser {
                Button("Quit Process…") {
                    model.requestStop(item, force: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 18)
    }
}

private struct PortStopConfirmationSheet: View {
    let item: ListeningPortItem
    let force: Bool
    let isDemo: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(force ? "Force quit" : "Quit") “\(item.processName)” (PID \(item.pid))?")
                .font(.system(size: 20, weight: .semibold))
            Text(force
                 ? "Force quitting immediately terminates the process on port \(item.port) (\(item.transport.rawValue)) without allowing it to save state."
                 : "Sends a standard termination signal (SIGTERM) to the process listening on port \(item.port) (\(item.transport.rawValue)).")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let path = item.executablePath {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if isDemo {
                Text("Demo · Process termination is simulated.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(force ? "Force Quit" : "Quit Process", role: force ? .destructive : nil, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(Palette.panel)
    }
}
