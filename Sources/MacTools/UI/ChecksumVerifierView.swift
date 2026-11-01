import QuickLook
import SwiftUI

struct ChecksumVerifierView: View {
    @ObservedObject var model: ChecksumVerifierModel
    @State private var showingIssues = false
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controlsBar
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
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isComputing else { return false }
            let regularURLs = urls.filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
            guard !regularURLs.isEmpty else { return false }
            model.addFiles(regularURLs)
            return true
        }
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $showingIssues) {
            ChecksumIssuesSheet(issues: model.issues)
        }
        .onAppear {
            model.prepareDemoIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Checksums")
                .font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add files…") {
                model.chooseFiles()
            }
            .disabled(model.isComputing)

            if !model.records.isEmpty {
                Button("Clear") {
                    model.clearFiles()
                }
                .disabled(model.isComputing)
            }

            HelpTip(
                text: "Computes SHA-256, SHA-512, SHA-1, and MD5 digests for local regular files and compares them against an expected checksum without uploading files.",
                label: "About Checksums"
            )
        }
        .padding(.horizontal, 36)
        .padding(.top, 45)
        .padding(.bottom, 22)
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Picker("Algorithm", selection: $model.algorithm) {
                ForEach(ChecksumAlgorithm.allCases) { algorithm in
                    Text(algorithm.rawValue).tag(algorithm)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Expected checksum to compare", text: $model.expectedChecksum)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                if !model.expectedChecksum.isEmpty {
                    Button {
                        model.expectedChecksum = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear expected checksum")
                    .accessibilityLabel("Clear expected checksum")
                }
            }
            .padding(8)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 12)
    }

    private func bannerBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { model.banner = nil }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isComputing && model.records.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Computing checksums…")
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.records.isEmpty {
            ContentUnavailableView {
                Label("Choose files to inspect", systemImage: "checkmark.shield")
            } description: {
                Text("Select one or more local files to compute SHA-256, SHA-512, SHA-1, and MD5 digests.")
            } actions: {
                Button("Choose files…") {
                    model.chooseFiles()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                fileList
                    .frame(width: 280)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.records) { record in
                    fileRow(record)
                    Divider()
                }
            }
        }
    }

    private func fileRow(_ record: ChecksumRecord) -> some View {
        let isSelected = model.selectedRecord?.id == record.id
        let comparison = model.comparison(for: record)
        return HStack(spacing: 10) {
            Button {
                model.selectedID = record.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(bytes(record.byteCount))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 6)
                    comparisonBadge(comparison)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.removeFile(id: record.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Remove from list")
            .accessibilityLabel("Remove \(record.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isSelected ? Palette.accent.opacity(0.10) : Color.clear)
    }

    @ViewBuilder
    private func comparisonBadge(_ comparison: ChecksumComparison) -> some View {
        switch comparison {
        case .notProvided:
            EmptyView()
        case .matches:
            Label("Match", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
        case .mismatch:
            Label("Mismatch", systemImage: "xmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = model.selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 18, weight: .semibold))
                            Text(displayPath(record.url.path))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            quickLookURL = record.url
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.borderless)
                        .help("Quick Look")
                        .accessibilityLabel("Quick Look \(record.name)")
                        Button {
                            model.reveal(record)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        .accessibilityLabel("Show \(record.name) in Finder")
                    }

                    HStack(spacing: 24) {
                        metadataItem(label: "Size", value: bytes(record.byteCount))
                        metadataItem(
                            label: "Modified",
                            value: record.modifiedDate.formatted(date: .abbreviated, time: .shortened)
                        )
                        if model.comparison(for: record) != .notProvided {
                            metadataItem(
                                label: "Verification",
                                value: model.comparison(for: record) == .matches ? "Matches expected" : "Does not match"
                            )
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ChecksumAlgorithm.allCases) { algorithm in
                            if let digest = record.digest(for: algorithm) {
                                digestRow(algorithm: algorithm, digest: digest)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
    }

    private func digestRow(algorithm: ChecksumAlgorithm, digest: String) -> some View {
        let isSelectedAlgorithm = model.algorithm == algorithm
        let comparison = isSelectedAlgorithm
            ? ChecksumVerifier.compare(digest: digest, expected: model.expectedChecksum)
            : .notProvided
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(algorithm.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelectedAlgorithm ? Palette.accent : .secondary)
                comparisonBadge(comparison)
                Spacer()
                Button("Copy") {
                    model.copyDigest(digest)
                }
                .controlSize(.small)
            }
            Text(digest)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelectedAlgorithm ? Palette.accent.opacity(0.08) : Palette.canvas)
                )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !model.issues.isEmpty {
                Button("\(model.issues.count) skipped") {
                    showingIssues = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            Spacer()

            if model.isComputing {
                Button("Cancel") {
                    model.cancel()
                }
                .controlSize(.large)
            } else if model.records.isEmpty {
                Button("Choose files…") {
                    model.chooseFiles()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Copy \(model.algorithm.rawValue)") {
                    model.copySelectedDigest()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedRecord == nil)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
    }

    private var summaryText: String {
        guard !model.records.isEmpty else { return "No files selected" }
        let fileWord = model.records.count == 1 ? "1 file" : "\(model.records.count) files"
        if !ChecksumVerifier.normalizeDigest(model.expectedChecksum).isEmpty {
            return "\(fileWord) · \(model.matchingCount) matching \(model.algorithm.rawValue)"
        }
        return "\(fileWord) · \(model.algorithm.rawValue)"
    }
}

private struct ChecksumIssuesSheet: View {
    let issues: [ChecksumIssue]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Skipped items")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayPath(issue.path))
                                .font(.system(size: 12, design: .monospaced))
                            Text(issue.message)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 520, height: 320)
        .background(Palette.panel)
    }
}
