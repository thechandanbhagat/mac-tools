import SwiftUI

/// Rectangles preserve the relative sizes of the scan results. Tiny entries
/// remain available in the accessible item list below the map.
struct StorageMapChart: View {
    let nodes: [StorageMapNode]
    let onOpen: (StorageMapNode) -> Void
    let onShowAll: () -> Void
    let onReveal: (StorageMapNode) -> Void
    let onTrash: (StorageMapNode) -> Void
    let canTrash: (StorageMapNode) -> Bool

    private struct Segment: Identifiable {
        let id: String
        let node: StorageMapNode?
        let title: String
        let byteCount: Int64
        let otherCount: Int
    }

    private struct Tile: Identifiable {
        let segment: Segment
        let rect: CGRect
        let index: Int
        var id: String { segment.id }
    }

    private var segments: [Segment] {
        let positive = nodes.filter { $0.byteCount > 0 }
        let displayed = positive.count > 12 ? Array(positive.prefix(11)) : positive
        var values = displayed.map {
            Segment(id: $0.id, node: $0, title: $0.name, byteCount: $0.byteCount, otherCount: 0)
        }
        if positive.count > 12 {
            let remainder = positive.dropFirst(11)
            values.append(Segment(
                id: "storage-map-other", node: nil, title: "Other items",
                byteCount: remainder.reduce(0) { $0 + $1.byteCount }, otherCount: remainder.count
            ))
        }
        return values
    }

    var body: some View {
        GeometryReader { geometry in
            let values = segments
            let tiles = StorageMapLayout.rectangles(weights: values.map(\.byteCount), in: CGRect(origin: .zero, size: geometry.size)).map {
                Tile(segment: values[$0.index], rect: $0.rect, index: $0.index)
            }
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    tileView(tile)
                        .frame(width: max(0, tile.rect.width - 4), height: max(0, tile.rect.height - 4))
                        .offset(x: tile.rect.minX + 2, y: tile.rect.minY + 2)
                }
            }
        }
        .frame(height: 206)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage map. Area is proportional to scanned size.")
    }

    private func tileView(_ tile: Tile) -> some View {
        let segment = tile.segment
        let roomForName = tile.rect.width >= 85 && tile.rect.height >= 40
        let roomForSize = tile.rect.width >= 100 && tile.rect.height >= 73
        return Button {
            if let node = segment.node { onOpen(node) }
            else { onShowAll() }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                if roomForName {
                    HStack(spacing: 6) {
                        if tile.rect.width >= 145 {
                            Image(systemName: segment.node.map { $0.isPackage ? "shippingbox" : $0.isDirectory ? "folder" : "doc" } ?? "ellipsis")
                                .foregroundStyle(Palette.accent)
                        }
                        Text(segment.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if roomForSize {
                        Text(bytes(segment.byteCount))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .padding(roomForName ? 12 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.accent.opacity(segment.node == nil ? 0.065 : 0.21 - Double(tile.index % 6) * 0.022))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Palette.accent.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(segment.node.map { "\($0.name) · \(bytes($0.byteCount)). \($0.isDirectory && !$0.isPackage ? "Open and scan folder" : "Show in Finder")" }
              ?? "\(segment.otherCount) other items · \(bytes(segment.byteCount)). View the full list below.")
        .accessibilityLabel(segment.title)
        .accessibilityValue(bytes(segment.byteCount))
        .accessibilityHint(segment.node.map { $0.isDirectory && !$0.isPackage ? "Opens and scans this folder" : "Shows this item in Finder" }
                           ?? "Scrolls to the full item list")
        .accessibilityActions {
            if let node = segment.node, !node.isPackage && canTrash(node) {
                Button("Move to Trash…") { onTrash(node) }
            }
        }
        .contextMenu {
            if let node = segment.node {
                if node.isDirectory && !node.isPackage { Button("Open folder") { onOpen(node) } }
                Button("Show in Finder") { onReveal(node) }
                if !node.isPackage {
                    Divider()
                    Button("Move to Trash…", role: .destructive) { onTrash(node) }
                        .disabled(!canTrash(node))
                }
            }
        }
    }
}

struct StorageMapRectangle {
    let index: Int
    let rect: CGRect
}

/// Pure geometry, kept separate so the visual's proportionality can be tested.
enum StorageMapLayout {
    static func rectangles(weights: [Int64], in rect: CGRect) -> [StorageMapRectangle] {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return [] }
        let values = weights.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, weight: Double($0.element)) }
        var output: [StorageMapRectangle] = []
        func split(_ items: ArraySlice<(index: Int, weight: Double)>, in bounds: CGRect) {
            guard !items.isEmpty else { return }
            if items.count == 1, let item = items.first {
                output.append(StorageMapRectangle(index: item.index, rect: bounds))
                return
            }
            let total = items.reduce(0.0) { $0 + $1.weight }
            guard total > 0 else { return }
            var sum = 0.0
            var splitCount = 1
            var closest = Double.greatestFiniteMagnitude
            for (index, item) in items.dropLast().enumerated() {
                sum += item.weight
                let distance = abs(total / 2 - sum)
                if distance < closest {
                    closest = distance
                    splitCount = index + 1
                }
            }
            let first = items.prefix(splitCount)
            let ratio = first.reduce(0.0) { $0 + $1.weight } / total
            var firstBounds = bounds
            var secondBounds = bounds
            if bounds.width >= bounds.height {
                firstBounds.size.width = bounds.width * ratio
                secondBounds.origin.x += firstBounds.width
                secondBounds.size.width -= firstBounds.width
            } else {
                firstBounds.size.height = bounds.height * ratio
                secondBounds.origin.y += firstBounds.height
                secondBounds.size.height -= firstBounds.height
            }
            split(first, in: firstBounds)
            split(items.dropFirst(splitCount), in: secondBounds)
        }
        split(values[...], in: rect)
        return output
    }
}
