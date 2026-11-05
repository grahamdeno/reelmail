import SwiftUI

/// Settings › Forwarding addresses. Mail is forwarded only to addresses listed here.
/// Gmail's own Settings adds and verifies forwarding addresses; Lovely only reads what Gmail lists.
struct ForwardingAddressesView: View {
    @Environment(FeedStore.self) private var store
    @State private var addresses = ForwardAllowlist().addresses
    @State private var entry = ""
    @State private var status: String?
    @State private var gmailEntries: [ForwardingStatus.Entry]?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                ForEach(addresses, id: \.self) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a)
                        Button(ShoeboxRule.address() == a ? "This is your Shoebox address" : "Use as Shoebox address") { ShoeboxRule.setAddress(a); addresses = ForwardAllowlist().addresses }
                            .font(.caption).disabled(ShoeboxRule.address() == a)
                        if let gmailEntries {
                            let s = ForwardingStatus.of(a, in: gmailEntries)
                            Text(s.label).font(.caption).foregroundStyle(s == .verified ? CalmStyle.secondary : Color.orange)
                        }
                    }
                }
                .onDelete { offsets in offsets.map { addresses[$0] }.forEach { ForwardAllowlist().remove($0) }; addresses = ForwardAllowlist().addresses }
                HStack {
                    TextField("Add an address", text: $entry).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                    Button("Add") { if ForwardAllowlist().add(entry) { entry = ""; addresses = ForwardAllowlist().addresses; Task { await check() } } else { status = "That does not look like an email address." } }
                        .disabled(entry.isEmpty)
                }
            } header: { Text("Allowed addresses") } footer: {
                Text("Lovely forwards mail only to these, and only once Gmail shows them as verified. Add and verify an address in Gmail on the web: Settings > See all settings > Forwarding and POP/IMAP > Add a forwarding address.")
            }
            Section {
                Button(checking ? "Checking Gmail…" : "Check Gmail again") { Task { await check() } }.disabled(checking || store.actions == nil)
            }
            if let status { Section { Text(status).font(.caption) } }
        }
        .navigationTitle("Forwarding addresses").navigationBarTitleDisplayMode(.inline)
        .task { await check() }
    }

    /// Read-only: asks Gmail which forwarding addresses it has. Changes nothing.
    private func check() async {
        guard let actions = store.actions else { status = "Connect Gmail to see what Gmail has verified."; return }
        checking = true; defer { checking = false }
        do { gmailEntries = try await actions.forwardingStatus(); status = nil }
        catch { status = "Could not check Gmail. \(error.localizedDescription)" }
    }
}

/// Settings › Gmail filters: only filters Lovely made.
struct GmailFiltersView: View {
    @Environment(FeedStore.self) private var store
    @State private var filters = FilterRegistry().filters
    @State private var preview: ActionPreview?
    @State private var status: String?

    var body: some View {
        List {
            if filters.isEmpty { Text("Lovely has not made any filters.").foregroundStyle(CalmStyle.secondary) }
            ForEach(filters) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text("From " + f.sender)
                    if let to = f.forwardTo { Text("Forwards to " + to).font(.caption).foregroundStyle(CalmStyle.secondary) }
                    if f.label != nil { Text("Adds a Lovely label").font(.caption).foregroundStyle(CalmStyle.secondary) }
                    Button("Delete", role: .destructive) {
                        preview = ActionPreview(id: f.gmailID, kind: .deleteFilter, title: "Delete this filter",
                                                lines: ["Mail from \(f.sender) will no longer be forwarded or labeled by it.", "Mail already forwarded stays where it went."])
                    }.font(.caption)
                }
            }
            if let status { Text(status).font(.caption) }
        }
        .navigationTitle("Gmail filters").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { p in
            ActionPreviewSheet(preview: p, confirmTitle: "Delete filter", destructive: true) { confirmed in
                guard let actions = store.actions else { status = "Connect Gmail first."; return }
                Task {
                    do { try await actions.deleteFilter(id: p.id, confirmed: confirmed); filters = FilterRegistry().filters }
                    catch { status = error.localizedDescription }
                }
            }
        }
    }
}

/// Settings › Gmail activity: everything Lovely sent, forwarded, filed or filtered.
struct GmailActivityView: View {
    @State private var entries = ActivityLog().entries

    var body: some View {
        List {
            if entries.isEmpty { Text("Lovely has not changed anything in Gmail beyond Trash and Done.").foregroundStyle(CalmStyle.secondary) }
            ForEach(entries.reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.summary)
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(CalmStyle.secondary)
                }
            }
        }
        .navigationTitle("Gmail activity").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Clear", role: .destructive) { ActivityLog().clear(); entries = [] }.disabled(entries.isEmpty) }
    }
}
