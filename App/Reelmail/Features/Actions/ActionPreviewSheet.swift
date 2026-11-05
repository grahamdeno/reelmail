import SwiftUI

/// The one place a ConfirmedAction is made. Nothing is sent, forwarded, filtered or deleted until Confirm is tapped here.
struct ActionPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: ActionPreview
    var confirmTitle = "Confirm"
    /// Red confirm button for deletes, declines and Trash.
    var destructive = false
    let onConfirm: (ConfirmedAction) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(preview.title).font(.title3.weight(.semibold))
                    ForEach(preview.lines, id: \.self) { Text($0).font(.body) }
                    if !preview.recipients.isEmpty {
                        Text("TO").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(CalmStyle.secondary).padding(.top, 6)
                        ForEach(preview.recipients, id: \.self) { Text($0).font(.body.weight(.medium)) }
                    }
                    Text("Nothing happens until you tap \(confirmTitle).").font(.caption).foregroundStyle(CalmStyle.secondary).padding(.top, 6)
                    Button(confirmTitle, role: destructive ? .destructive : nil) {
                        onConfirm(ConfirmedAction(preview: preview))
                        dismiss()
                    }.buttonStyle(CalmActionStyle(prominent: true))
                    Button("Cancel") { dismiss() }.buttonStyle(CalmActionStyle())
                }.padding(20)
            }
            .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// A countdown banner for held sends and forwards, with Undo.
struct UndoBanner: View {
    @Environment(FeedStore.self) private var store
    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.undo.pending) { item in
                HStack {
                    Text(item.title).font(.subheadline).lineLimit(2)
                    Spacer()
                    Button("Undo") { store.undo.cancel(item.id) }.font(.subheadline.weight(.semibold))
                }
                .padding(12).background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 16)
        .animation(.default, value: store.undo.pending)
    }
}
