import SwiftUI

/// One quiet row on Home that opens the Kids page. Shown once a child has been added in Settings.
struct KidsRow: View {
    @Environment(Router.self) private var router
    let count: Int
    var body: some View {
        Button { router.open(.kids) } label: {
            HStack(spacing: 10) {
                Text("Kids").font(.subheadline.weight(.medium)).foregroundStyle(CalmStyle.ink)
                Spacer()
                Text(count == 0 ? "Nothing new" : "\(count) in mail").font(.caption).foregroundStyle(CalmStyle.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.secondary)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

/// Every child, with the mail that mentions them.
struct KidsView: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let kids = InsightSettings().load().kids
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if kids.isEmpty {
                    Text("Add your children in Settings, then Lovely can gather their school and activity mail here.")
                        .font(.subheadline).foregroundStyle(CalmStyle.secondary)
                }
                ForEach(kids) { kid in
                    let mail = store.kidMail(for: kid)
                    Button { router.open(.kid(kid.id)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kid.name).font(.headline)
                                Text(kid.school.isEmpty ? "No school entered" : kid.school).font(.caption).foregroundStyle(CalmStyle.secondary)
                            }
                            Spacer()
                            Text("\(mail.count)").foregroundStyle(CalmStyle.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(CalmStyle.secondary)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 56).background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
                Button { router.open(.insightSettings) } label: { Label("Households and kids", systemImage: "person.2").frame(maxWidth: .infinity) }
                    .buttonStyle(CalmActionStyle())
            }.padding(20)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle("Kids").navigationBarTitleDisplayMode(.inline)
    }
}

/// One child's page: the mail that mentions them, why it matched, and a summary of any long newsletter.
struct KidView: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    let kidID: String
    @State private var summaries: [String: [String]] = [:]
    @State private var working: Set<String> = []
    @State private var shoeboxPreview: ActionPreview?
    @State private var shoeboxSender: String?
    @State private var shoeboxIDs: [String] = []
    @State private var shoeboxNote: String?

    var body: some View {
        let kid = InsightSettings().load().kids.first { $0.id == kidID }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let kid {
                    let mail = store.kidMail(for: kid)
                    if mail.isEmpty { Text("No mail about \(kid.name) in your inbox right now.").font(.subheadline).foregroundStyle(CalmStyle.secondary) }
                    ForEach(mail) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { router.open(.email(item.post.id)) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.post.summary.headline).font(.headline).multilineTextAlignment(.leading)
                                    Text(item.post.email.from.name + " · " + item.post.email.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(CalmStyle.secondary)
                                    Text(item.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(CalmStyle.secondary)
                                }
                            }.buttonStyle(.plain)
                            if store.actions != nil {
                                Button("Send this sender to Shoebox") { Task { await prepareShoebox(item.post.email.from.email) } }.font(.subheadline)
                            }
                            if item.post.email.body.count > 1_500 {
                                if let list = summaries[item.id] {
                                    ForEach(list, id: \.self) { Text("• " + $0).font(.subheadline) }
                                    if list.isEmpty { Text("Nothing specific found.").font(.caption).foregroundStyle(CalmStyle.secondary) }
                                } else {
                                    Button(working.contains(item.id) ? "Reading…" : "Summarize on this phone") { summarize(item, kid: kid) }
                                        .font(.subheadline).disabled(working.contains(item.id))
                                }
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    Text("This child is no longer in Settings.").font(.subheadline).foregroundStyle(CalmStyle.secondary)
                }
            }.padding(20)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle(kid?.name ?? "Kid").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shoeboxPreview) { p in
            ActionPreviewSheet(preview: p, confirmTitle: "Create rule") { confirmed in
                if let sender = shoeboxSender, let box = ShoeboxRule.address() { store.sendSenderToShoebox(sender: sender, shoebox: box, ids: shoeboxIDs, confirmed: confirmed) }
            }
        }
        .alert("Shoebox", isPresented: Binding(get: { shoeboxNote != nil }, set: { if !$0 { shoeboxNote = nil } })) { Button("OK") {} } message: { Text(shoeboxNote ?? "") }
    }

    private func prepareShoebox(_ sender: String) async {
        guard let box = ShoeboxRule.address(), ForwardAllowlist().contains(box) else {
            shoeboxNote = "Set your Shoebox address first: Settings, Forwarding addresses."; return
        }
        let ids = await store.shoeboxBackfillIDs(sender: sender)
        shoeboxSender = sender
        shoeboxIDs = ids
        shoeboxPreview = ShoeboxRule.preview(sender: sender, shoebox: box, count: ids.count)
    }

    private func summarize(_ item: KidMail, kid: KidProfile) {
        working.insert(item.id)
        Task {
            let list = await NewsletterSummarizer().items(from: item.post.email.body, childName: kid.name)
            summaries[item.id] = list
            working.remove(item.id)
        }
    }
}

/// Households and children, kept on this phone. Names here never leave it.
struct InsightSettingsView: View {
    @State private var data = InsightSettings().load()
    @State private var newKid = ""
    @State private var newHousehold = ""

    var body: some View {
        Form {
            Section("Households") {
                ForEach($data.households) { $h in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $h.name)
                        TextField("Sender domains, comma separated", text: Binding(
                            get: { h.payeeDomains.joined(separator: ", ") },
                            set: { h.payeeDomains = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }))
                            .font(.caption).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Ends on a date", isOn: Binding(get: { h.endsOn != nil }, set: { h.endsOn = $0 ? (h.endsOn ?? Date()) : nil }))
                        if let end = h.endsOn { DatePicker("Ends", selection: Binding(get: { end }, set: { h.endsOn = $0 }), displayedComponents: .date) }
                    }
                }
                .onDelete { data.households.remove(atOffsets: $0) }
                HStack { TextField("Add a household", text: $newHousehold); Button("Add") { add(household: newHousehold) }.disabled(newHousehold.isEmpty) }
            }
            Section("Kids") {
                ForEach($data.kids) { $k in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $k.name)
                        TextField("School", text: $k.school)
                        TextField("Teachers, comma separated", text: list($k.teacherNames))
                        TextField("Activities, comma separated", text: list($k.activities))
                    }
                }
                .onDelete { data.kids.remove(atOffsets: $0) }
                HStack { TextField("Add a child", text: $newKid); Button("Add") { add(kid: newKid) }.disabled(newKid.isEmpty) }
            }
            Section { Text("Saved on this phone only. Deleted when you disconnect Gmail.").font(.caption).foregroundStyle(CalmStyle.secondary) }
        }
        .navigationTitle("Households and kids").navigationBarTitleDisplayMode(.inline)
        .onChange(of: data) { _, new in InsightSettings().save(new) }
    }

    private func list(_ b: Binding<[String]>) -> Binding<String> {
        Binding(get: { b.wrappedValue.joined(separator: ", ") },
                set: { b.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    private func add(household name: String) { data.households.append(Household(id: UUID().uuidString, name: name)); newHousehold = "" }
    private func add(kid name: String) { data.kids.append(KidProfile(id: UUID().uuidString, name: name, school: "")); newKid = "" }
}
