import SwiftUI

struct ReviewView: View {
    @ObservedObject var model: CleanerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Review before cleaning").font(.system(size: 23, weight: .semibold))
                    Text("\(model.selectedItems.count) \(model.selectedItems.count == 1 ? "file" : "files") · \(bytes(model.selectedBytes)) on disk")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                HelpTip(text: "Restore files in Finder with Put Back. Space is freed only after you empty Trash yourself. Mac Tools never empties Trash.", label: "About moving files to Trash")
            }
            Text("Selected files will move to Trash. Close any apps that use them first.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    ForEach(model.selectedItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(item.url.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(bytes(item.byteCount)).font(.system(size: 12)).monospacedDigit()
                        }
                    }
                }.padding(.vertical, 5)
            }.frame(height: 220)
            Divider()
            HStack {
                if model.isDemo {
                    Text("Demo · Cleaning disabled").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.showReview = false }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { model.cleanSelected() }
                    .buttonStyle(.borderedProminent).disabled(model.selectedItems.isEmpty || model.isDemo)
            }
        }.padding(28).frame(width: 610)
    }
}
