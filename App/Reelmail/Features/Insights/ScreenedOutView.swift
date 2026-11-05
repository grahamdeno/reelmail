import SwiftUI

/// One quiet row on Home for first-time senders.
struct ScreenedOutRow: View {
    @Environment(Router.self) private var router
    let count: Int
    var body: some View {
        Button { router.open(.screenedOut) } label: {
            HStack(spacing: 10) {
                Text("New senders · \(count)").font(.subheadline.weight(.medium)).foregroundStyle(CalmStyle.ink)
                Spacer()
                Text("Accept or decline").font(.caption).foregroundStyle(CalmStyle.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.secondary)
            }
            .padding(.horizontal, 14).frame(minHeight: 48).background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

/// People and companies writing to you for the first time. Accept keeps them; Decline files them under Lovely/Screened Out.
struct ScreenedOutView: View {
    @Environment(FeedStore.self) private var store
    @State private var preview: ActionPreview?
    @State private var target: ScreenedOut.Candidate?
    @State private var oldIDs: [String] = []
    @State private var trashPreview: ActionPreview?

    private var candidates: [ScreenedOut.Candidate] { store.newSenders }

    var body: some View {
        List {
            if candidates.isEmpty { Text("No new senders.").foregroundStyle(CalmStyle.secondary) }
            ForEach(candidates) { c in
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.name).font(.headline)
                    Text(c.address).font(.caption).foregroundStyle(CalmStyle.secondary)
                    Text(c.subject).font(.subheadline).lineLimit(2)
                    HStack {
                        Button("Accept") { store.accept(c) }.buttonStyle(CalmActionStyle(prominent: true))
                        if store.actions != nil {
                            Button("Decline", role: .destructive) { target = c; preview = ScreenedOut.declinePreview(c) }.buttonStyle(CalmActionStyle())
                        }
                    }
                }.padding(.vertical, 4)
            }
            if store.actions != nil {
                Section {
                    Button("Check for screened-out mail older than \(ScreenedOut.trashAfterDays) days") {
                        Task {
                            oldIDs = await store.oldScreenedOutIDs()
                            trashPreview = ActionPreview(kind: .trashScreened, title: "Move old screened-out mail to Trash",
                                                         lines: [oldIDs.isEmpty ? "Nothing is older than \(ScreenedOut.trashAfterDays) days." : "\(oldIDs.count) messages go to Gmail's Trash, where you can still recover them for 30 days."])
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("New senders").navigationBarTitleDisplayMode(.inline)
        .task { await store.verifyNewSenders() }
        .sheet(item: $preview) { p in
            ActionPreviewSheet(preview: p, confirmTitle: "Decline", destructive: true) { confirmed in
                guard let c = target else { return }
                Task { await store.decline(c, confirmed: confirmed) }
            }
        }
        .sheet(item: $trashPreview) { p in
            ActionPreviewSheet(preview: p, confirmTitle: "Move to Trash", destructive: true) { _ in
                guard !oldIDs.isEmpty else { return }
                Task { await store.trashScreenedOut(oldIDs) }
            }
        }
    }
}
