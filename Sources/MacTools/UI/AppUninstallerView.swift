import AppKit
import SwiftUI

struct AppUninstallerView: View {
    @ObservedObject var model: AppUninstallerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Uninstaller").font(.system(size: 28, weight: .semibold))
                if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                HelpTip(text: "Apps are found in /Applications and your Applications folder. Choose an app to measure it and find related files with its exact bundle identifier. Related files are optional and may contain settings or data. System apps, shared containers, and privileged helpers are not removed. Use the developer’s uninstaller for apps that install background services. Nothing moves until you confirm.",
                        label: "About app uninstaller")
            }
            .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)

            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.bottom, 16)
            }
            HStack(spacing: 24) {
                applicationList.frame(width: 260)
                Divider()
                details.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 36).padding(.bottom, 24)
            footer
        }
        .background(Palette.panel)
        .task { model.loadIfNeeded() }
        .sheet(isPresented: Binding(get: { model.pendingRequest != nil }, set: { if !$0 { model.cancelReview() } })) {
            if let request = model.pendingRequest {
                UninstallerConfirmation(request: request, isDemo: model.isDemo,
                                        onCancel: model.cancelReview, onConfirm: model.confirmUninstall)
            }
        }
        .sheet(isPresented: $model.showIssues) { issuesView }
        .alert("App uninstaller", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var applicationList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $model.query).textFieldStyle(.plain)
                    .accessibilityLabel("Search apps")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 13)).padding(10)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .disabled(model.isUninstalling)

            if model.phase == .loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding apps…") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("\(model.filteredApplications.count) \(model.filteredApplications.count == 1 ? "app" : "apps")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.filteredApplications) { app in
                        Button { model.select(app) } label: {
                            HStack(spacing: 10) {
                                AppIcon(url: app.url).frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if let version = app.version {
                                        Text(version).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(model.selectedApplication?.id == app.id ? Palette.accent.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).disabled(model.isUninstalling || model.phase == .loading)
                        .help(app.url.path)
                        .accessibilityLabel(app.name)
                        .accessibilityAddTraits(model.selectedApplication?.id == app.id ? [.isSelected] : [])
                    }
                    if model.filteredApplications.isEmpty && model.phase != .loading && model.hasLoaded {
                        Text(model.query.isEmpty ? "No apps found." : "No matching apps.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let app = model.selectedApplication {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 13) {
                        AppIcon(url: app.url).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.name).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                            Text(app.url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle).help(app.url.path)
                            if let inspection = model.inspection {
                                Text("\(bytes(inspection.appItem.byteCount))\(inspection.appItem.isPartial ? " · Partial size" : "")")
                                    .font(.system(size: 12)).monospacedDigit()
                            }
                        }
                        Spacer(minLength: 0)
                        Button { model.reveal(app.url) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Show app in Finder").accessibilityLabel("Show \(app.name) in Finder")
                    }
                    if model.phase == .inspecting {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking files…") }
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else if let inspection = model.inspection {
                        if inspection.isRunning {
                            Label("Quit \(app.name), then check again.", systemImage: "exclamationmark.circle")
                                .font(.system(size: 13))
                            Button("Check again") { model.select(app) }.disabled(model.isBusy)
                        } else if inspection.appItem.isPartial {
                            Label("The app couldn’t be fully checked.", systemImage: "exclamationmark.circle")
                                .font(.system(size: 13))
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Text("Related files").font(.system(size: 14, weight: .medium))
                                HelpTip(text: "Only exact bundle-identifier matches in your Library are listed. Select the files you want to include. They may contain settings and app data. Other locations and shared containers are left alone.", label: "About related files")
                                Spacer()
                                if !inspection.relatedItems.isEmpty {
                                    Button("Select all") { model.selectAllRelated() }
                                        .buttonStyle(.link).font(.system(size: 11))
                                        .disabled(model.isBusy || inspection.relatedItems.allSatisfy(\.isPartial))
                                    if !model.selectedRelatedIDs.isEmpty {
                                        Text("·").foregroundStyle(.secondary).font(.system(size: 11))
                                        Button("Clear selection") { model.clearRelatedSelection() }
                                            .buttonStyle(.link).font(.system(size: 11))
                                            .disabled(model.isBusy)
                                    }
                                }
                            }
                            if inspection.relatedItems.isEmpty {
                                Text("No exact matches found.").font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                ForEach(inspection.relatedItems) { item in relatedRow(item) }
                            }
                        }
                    } else if !model.isBusy {
                        Button("Check again") { model.select(app) }
                    }
                }
                .padding(.bottom, 12)
            }
        } else {
            ContentUnavailableView("Choose an app", systemImage: "app.dashed")
                .frame(maxHeight: .infinity)
        }
    }

    private func relatedRow(_ item: UninstallItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { model.selectedRelatedIDs.contains(item.id) }, set: { _ in model.toggleRelated(item) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(displayPath(item.url.deletingLastPathComponent().path)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if item.isPartial { Text("Couldn’t be fully checked").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            .toggleStyle(.checkbox).disabled(model.isBusy || item.isPartial)
            .help(item.url.path).accessibilityLabel("Include \(item.url.path)")
            Spacer(minLength: 8)
            Text(bytes(item.byteCount)).font(.system(size: 12)).monospacedDigit()
            Button { model.reveal(item.url) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show in Finder").accessibilityLabel("Show \(item.name) in Finder")
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if !model.allIssues.isEmpty {
                    Button { model.showIssues = true } label: {
                        Label("\(model.allIssues.count) \(model.allIssues.count == 1 ? "notice" : "notices")", systemImage: "exclamationmark.circle")
                    }.buttonStyle(.link).font(.system(size: 12))
                }
                Spacer()
                if model.isUninstalling {
                    ProgressView().controlSize(.small)
                    Text("Moving to Trash…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if model.isBusy {
                    Button("Cancel scan") { model.cancelScan() }.controlSize(.large)
                } else {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh apps (Command-R)").accessibilityLabel("Refresh apps")
                    if model.inspection != nil {
                        Text(bytes(model.selectedBytes)).font(.system(size: 12)).monospacedDigit()
                        Button("Review…") { model.review() }.buttonStyle(.borderedProminent)
                            .controlSize(.large).disabled(!model.canReview)
                    }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 18).frame(minHeight: 68)
        }
    }

    private var issuesView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Scan notices").font(.system(size: 22, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.allIssues) { issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.message).font(.system(size: 13))
                            Text(issue.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 240)
            HStack { Spacer(); Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 560)
    }
}

private struct AppIcon: View {
    let url: URL
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().accessibilityHidden(true)
    }
}

private struct UninstallerConfirmation: View {
    let request: AppUninstallerRequest
    let isDemo: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Uninstall “\(request.application.name)”?")
                .font(.system(size: 21, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(request.items.count > 1
                 ? "The app and selected related files will move to Trash. Related files may contain settings and data."
                 : "The app will move to Trash. Its related files will stay on your Mac.")
                .font(.system(size: 13))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(request.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(item.url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(3).truncationMode(.middle).help(item.url.path).textSelection(.enabled)
                            }
                            Spacer(minLength: 12)
                            Text(bytes(item.byteCount)).font(.system(size: 12)).monospacedDigit()
                        }
                    }
                }
            }.frame(maxHeight: 220)
            Text("You can restore these items from Trash in Finder.").font(.system(size: 12)).foregroundStyle(.secondary)
            if isDemo { Text("Demo · Moving files is disabled.").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Text(bytes(request.byteCount)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.defaultAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent).disabled(isDemo)
            }
        }
        .padding(26).frame(width: 560)
        .onExitCommand(perform: onCancel)
    }
}
