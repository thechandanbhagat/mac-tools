import SwiftUI

struct StartupManagerView: View {
    @ObservedObject var model: StartupManagerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Startup Manager").font(.system(size: 28, weight: .semibold))
                if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Login Items…", action: model.openLoginItems).disabled(model.isDemo)
                    .help("Open Login Items in System Settings")
                HelpTip(text: "Reviews launch configurations in ~/Library/LaunchAgents, /Library/LaunchAgents, and /Library/LaunchDaemons. Conditions come from the files, not the current launchd state; system overrides may differ. Modern app-managed login and background items aren’t all represented here. Use Login Items in System Settings to manage them. No launch configurations are changed.", label: "About startup manager")
            }
            .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)

            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search launch items", text: $model.query).textFieldStyle(.plain)
                        .accessibilityLabel("Search launch items")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear search").accessibilityLabel("Clear search")
                    }
                }.font(.system(size: 13)).padding(10)
                    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                Picker("Scope", selection: $model.scope) {
                    Text("All").tag(nil as StartupScope?)
                    ForEach(StartupScope.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().frame(width: 140).accessibilityLabel("Startup scope")
            }.padding(.horizontal, 36).padding(.bottom, 18)

            HStack {
                Text("Launch agents & daemons").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Configured trigger").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 36).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredItems) { item in
                        row(item)
                        Divider()
                    }
                    if model.filteredItems.isEmpty && !model.isBusy && model.hasLoaded {
                        Text(model.query.isEmpty && model.scope == nil ? "No launch configurations found." : "No matching launch items.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 50)
                    }
                }.padding(.horizontal, 36)
            }
            Divider()
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Reading launch items…")
                } else {
                    Text("\(model.filteredItems.count) \(model.filteredItems.count == 1 ? "item" : "items")")
                }
                if !model.issues.isEmpty {
                    Button { model.showIssues = true } label: {
                        Label("\(model.issues.count) couldn’t be read", systemImage: "exclamationmark.circle")
                    }.buttonStyle(.link)
                }
                Spacer()
                Button("Refresh", action: model.refresh).disabled(model.isBusy)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 36).padding(.vertical, 18)
        }
        .background(Palette.panel)
        .task { model.loadIfNeeded() }
        .alert("Startup manager", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showIssues) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Unreadable items").font(.system(size: 23, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.issues) { issue in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(issue.path).font(.system(size: 12)).textSelection(.enabled)
                                Text(issue.message).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 540, height: 400)
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.scope == .system ? "gearshape" : "app.badge")
                .font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.program ?? item.url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(item.scope.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.trigger).font(.system(size: 12))
                if item.disabledInFile {
                    Text("Disabled in file").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("The file requests disabled status. A launchd override may differ.")
                }
            }
            Button { model.reveal(item) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isDemo)
                .help("Show configuration in Finder").accessibilityLabel("Show \(item.label) in Finder")
        }
        .padding(.vertical, 17)
        .help(item.url.path)
        .contextMenu { Button("Show in Finder") { model.reveal(item) }.disabled(model.isDemo) }
    }
}
