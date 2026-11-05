import SwiftUI

/// Settings: account, addresses, appearance, pictures, rules, testing tools and how Lovely handles mail.
struct SettingsView: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    @State private var showingFiltered = false

    private var sourceDetail: String {
        switch (store.mode, store.gmailConfigured) {
        case (.gmail, _):
            var parts = [store.account ?? ""]
            parts.append("\(store.posts.count) inbox messages, \(store.sentByMe.count) sent")
            if let fetched = store.lastFetched { parts.append("updated " + MailTime.label(fetched).lowercased()) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        case (.sample, true): return "Fictional mail. Connect Gmail to see your own."
        case (.sample, false): return "This build has no Gmail configuration, so it shows fictional mail."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsHeader(text: "Account", first: true)
                ProfileCard(title: "Mail source", value: store.mode == .gmail ? "Gmail" : "Demo", detail: sourceDetail)

                if store.needsReconnect {
                    Text(store.needsMailAccess
                         ? "Google didn't give Lovely access to your mail. Tap Reconnect, and on Google's screen tick the Gmail box (or Select all) before Continue."
                         : "Google signed you out. While Lovely is in testing this happens every 7 days. Your loaded mail is still here.")
                        .font(.subheadline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(CalmStyle.warning, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(CalmStyle.warningInk)
                }
                if store.gmailConfigured, !(store.mode == .gmail && !store.needsReconnect) {
                    Button { Task { await store.connectGmail() } } label: {
                        Label(store.needsReconnect ? "Reconnect Gmail" : "Connect Gmail", systemImage: "envelope.badge.shield.half.filled").frame(maxWidth: .infinity)
                    }.buttonStyle(CalmActionStyle(prominent: true))
                }
                if let error = store.errorMessage, !store.needsReconnect {
                    Text(error).font(.caption).foregroundStyle(CalmStyle.secondary)
                }
                if store.gmailConfigured, store.mode == .gmail, !store.needsReconnect {
                    // Quiet on purpose: it clears the mail kept on this phone.
                    Button(role: .destructive) { Task { await store.disconnectGmail() } } label: {
                        Label("Disconnect Gmail", systemImage: "envelope.badge.shield.half.filled")
                            .font(.subheadline).foregroundStyle(CalmStyle.roseInk)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }

                SettingsHeader(text: "Your other addresses")
                OtherAddressesCard()

                SettingsHeader(text: "Appearance")
                AppearanceCard()

                SettingsHeader(text: "Pictures")
                PicturesCard()

                SettingsHeader(text: "Morning brief")
                MorningBriefCard()

                SettingsHeader(text: "Households and kids")
                SettingsRow(title: "Households and kids") { router.open(.insightSettings) }
                ICloudBackupCard()

                SettingsHeader(text: "Gmail actions")
                SettingsRow(title: "Forwarding addresses") { router.open(.forwardingAddresses) }
                SettingsRow(title: "Gmail filters") { router.open(.gmailFilters) }
                SettingsRow(title: "Gmail activity") { router.open(.gmailActivity) }

                SettingsHeader(text: "Rules")
                ProfileCard(title: "Your rules", value: rulesSummary, detail: "Long-press a message to filter a sender or move it to Reading. Rules change this app only.")
                Button { showingFiltered = true } label: { Label("Review filtered senders", systemImage: "line.3.horizontal.decrease.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(CalmActionStyle())
                if !store.hiddenPosts.isEmpty {
                    Button { store.restoreAll() } label: { Label("Show hidden mail (\(store.hiddenPosts.count))", systemImage: "eye").frame(maxWidth: .infinity) }
                        .buttonStyle(CalmActionStyle())
                }
                let later = store.laterPosts
                if !later.isEmpty {
                    SettingsHeader(text: "Later (\(later.count))")
                    ForEach(later, id: \.post.id) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.post.email.from.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("Back " + LaterSchedule.label(item.until, now: Date())).font(.caption).foregroundStyle(CalmStyle.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Bring back now") { store.bringBack(item.post.id) }
                                .font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.blue).frame(minHeight: 44)
                        }
                    }
                }

                SettingsHeader(text: "Testing")
                SettingsRow(title: "Testing tools") { router.open(.testingTools) }

                SettingsHeader(text: "About")
                let status = ModelStatus.current
                ProfileCard(title: "On-device AI", value: status.title, detail: status.detail)
                SettingsRow(title: "How Lovely handles your mail") { router.open(.aboutPrivacy) }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showingFiltered) { FilteredMailReview() }
    }

    private var rulesSummary: String {
        let filtered = Set(store.filteredPosts.map(\.email.from.email)).count
        return filtered == 0 ? "No senders filtered" : (filtered == 1 ? "1 sender filtered" : "\(filtered) senders filtered")
    }
}

/// Morning brief: off until switched on. Counts only on the lock screen unless names are turned on.
struct MorningBriefCard: View {
    @Environment(FeedStore.self) private var store
    @AppStorage(BriefSettings.enabledKey) private var enabled = false
    @AppStorage(BriefSettings.minutesKey) private var minutes = BriefSettings.defaultMinutes
    @AppStorage(BriefSettings.namesKey) private var names = false
    @AppStorage(BriefSettings.nudgeKey) private var nudge = false
    @State private var declined = false
    @State private var chosenByHand = BriefSettings().manualMinutes != nil

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: Date())) ?? Date() },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes = (c.hour ?? 7) * 60 + (c.minute ?? 30) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Send a morning brief", isOn: Binding(get: { enabled }, set: { turn($0) }))
            if declined {
                Text("Notifications are off for Lovely. Turn them on in the Settings app.").font(.caption).foregroundStyle(CalmStyle.secondary)
            }
            if enabled {
                DatePicker("Time", selection: Binding(get: { time.wrappedValue }, set: { time.wrappedValue = $0; chosenByHand = true }), displayedComponents: .hourAndMinute)
                if chosenByHand {
                    Button("Let Lovely choose the time") {
                        UserDefaults.standard.removeObject(forKey: BriefSettings.minutesKey); chosenByHand = false
                        Task { await MorningBriefScheduler.reschedule(store: store) }
                    }.font(.subheadline)
                } else {
                    Text("Lovely chooses: 9:30 on weekdays, 10:00 on weekends, then it adjusts to when you open the app.").font(.caption).foregroundStyle(CalmStyle.secondary)
                }
                Toggle("Evening check at 7 PM", isOn: $nudge)
                Toggle("Show names in the brief", isOn: $names)
                Text("Names can appear on your lock screen.").font(.caption).foregroundStyle(CalmStyle.secondary)
            }
            Text("A short note with counts, built on this iPhone from mail already loaded. It skips mornings with nothing to say.")
                .font(.caption).foregroundStyle(CalmStyle.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: minutes) { _, _ in Task { await MorningBriefScheduler.reschedule(store: store) } }
        .onChange(of: names) { _, _ in Task { await MorningBriefScheduler.reschedule(store: store) } }
        .onChange(of: nudge) { _, _ in Task { await MorningBriefScheduler.reschedule(store: store) } }
    }

    private func turn(_ on: Bool) {
        guard on else {
            enabled = false; declined = false
            Task { await MorningBriefScheduler.reschedule(store: store) }
            return
        }
        Task {
            let granted = await MorningBriefScheduler.requestPermission()
            enabled = granted; declined = !granted
            UserDefaults.standard.set(true, forKey: BriefSettings.offerSeenKey)
            await MorningBriefScheduler.reschedule(store: store)
        }
    }
}

/// A small-caps group title in Settings.
private struct SettingsHeader: View {
    let text: String
    var first = false
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(CalmStyle.secondary)
            .padding(.top, first ? 4 : 18)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A full-width row that opens another screen.
private struct SettingsRow: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.body)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(CalmStyle.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading)
            .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Review sorting and Summary Lab: tools for checking Lovely, not everyday settings.
struct TestingToolsView: View {
    @Environment(Router.self) private var router
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { router.open(.sortingReview) } label: { Label("Review sorting", systemImage: "checkmark.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(CalmActionStyle())
                Button { router.open(.summaryLab) } label: { Label("Summary Lab", systemImage: "flask").frame(maxWidth: .infinity) }
                    .buttonStyle(CalmActionStyle())
                MorningBriefTestCard()
                ChatSwitchCard()
            }.padding(20)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle("Testing tools").navigationBarTitleDisplayMode(.inline)
    }
}

/// Testing tools: see the morning brief now instead of waiting for the morning.
struct MorningBriefTestCard: View {
    @Environment(FeedStore.self) private var store
    @State private var note: String?

    var body: some View {
        let brief = MorningBriefScheduler.preview(store: store)
        VStack(alignment: .leading, spacing: 10) {
            Text("MORNING BRIEF").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(CalmStyle.secondary)
            if let brief {
                Text(brief.title).font(.subheadline.weight(.semibold))
                Text(brief.body).font(.subheadline)
            } else {
                Text("The next brief would be skipped: nothing to say.").font(.subheadline)
            }
            Button {
                Task {
                    let sent = await MorningBriefScheduler.sendTest(store: store)
                    note = sent ? "Sent. Leave Lovely now and it arrives in 5 seconds." : "Nothing sent. Notifications may be off for Lovely, or there is nothing to say."
                }
            } label: { Label("Send a test brief", systemImage: "bell").frame(maxWidth: .infinity) }
                .buttonStyle(CalmActionStyle())
            if let note { Text(note).font(.caption).foregroundStyle(CalmStyle.secondary) }
            Text("The test does not turn on the real brief.").font(.caption).foregroundStyle(CalmStyle.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The privacy paragraph.
struct AboutPrivacyView: View {
    var body: some View {
        ScrollView {
            Text("Lovely reads your Gmail and writes summaries on this iPhone. Apart from Gmail, the only thing it fetches from the internet is company logos, from each company's own website, and you can turn that off in Settings under Pictures. It changes Gmail in only two ways, both when you ask and both undoable: moving a message to Trash, and marking a message read when you tap Done. It never sends mail, never deletes anything for good, and never changes other labels. Loaded mail is kept encrypted on this phone and removed when you disconnect.")
                .font(.body).foregroundStyle(CalmStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle("How Lovely handles your mail").navigationBarTitleDisplayMode(.inline)
    }
}

/// Light, dark, or follow the iPhone's setting.
struct AppearanceCard: View {
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(appearance == .neon ? "Midnight violet, hot pink and electric cyan. Totally tubular."
                                     : "Automatic follows your iPhone's light and dark setting.")
                .font(.caption).foregroundStyle(CalmStyle.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Where avatar pictures come from. Both stay on this phone.
struct PicturesCard: View {
    @State private var images = AvatarImages.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Photos from your Contacts", isOn: Binding(get: { images.useContacts },
                                                             set: { on in Task { await images.setUseContacts(on) } }))
                .font(.subheadline)
            Text("Matched by email address on this iPhone. Nothing is uploaded.").font(.caption).foregroundStyle(CalmStyle.secondary)
            if !images.contactsStatus.isEmpty {
                Text(images.contactsStatus).font(.caption).foregroundStyle(CalmStyle.roseInk)
            }
            Toggle("Company logos", isOn: $images.showLogos).font(.subheadline)
            Text("Fetched once from each company's own website and kept on this iPhone. Never for people, never through a third party.")
                .font(.caption).foregroundStyle(CalmStyle.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Other addresses of yours. Mail from them is "Notes to self". You declare them; Lovely never guesses from names.
struct OtherAddressesCard: View {
    @Environment(FeedStore.self) private var store
    @State private var newAddress = ""
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mail you send yourself from these shows under Notes to self, not Waiting on you.")
                .font(.caption).foregroundStyle(CalmStyle.secondary)
            ForEach(store.otherAddresses, id: \.self) { address in
                HStack {
                    Text(address).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Remove", role: .destructive) { store.removeOtherAddress(address) }
                        .font(.subheadline).foregroundStyle(CalmStyle.roseInk).frame(minWidth: 44, minHeight: 44)
                }
            }
            HStack(spacing: 8) {
                TextField("name@example.com", text: $newAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    .padding(10).background(CalmStyle.background, in: RoundedRectangle(cornerRadius: 10))
                    .submitLabel(.done).onSubmit(add)
                Button("Add", action: add).buttonStyle(CalmActionStyle(prominent: true))
                    .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(store.pendingOtherAddresses.sorted(), id: \.self) { address in
                Text("\(address) will be saved when your Gmail finishes loading.").font(.caption).foregroundStyle(CalmStyle.secondary)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(CalmStyle.roseInk) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
    private func add() {
        switch store.addOtherAddress(newAddress) {
        case .added, .pending: problem = nil; newAddress = ""
        case .invalid: problem = "That doesn't look like an email address."
        case .notSaved(let reason): problem = reason
        }
    }
}

struct ProfileCard: View {
    let title: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(CalmStyle.secondary)
            Text(value).font(.headline)
            Text(detail).font(.caption).foregroundStyle(CalmStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}


/// Owner switch for the chat walk-through, with one-tap rollback of everything it did.
struct ChatSwitchCard: View {
    @Environment(FeedStore.self) private var store
    @AppStorage(LearnedRuleStore.chatSwitchKey) private var enabled = false
    @State private var count = LearnedRuleStore().chatRules.count

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Chat walk-through", isOn: $enabled)
            Text("Adds a text box to the walk-through for sorting rules, such as hiding a sender. Rules apply only after you tap Apply.")
                .font(.caption).foregroundStyle(CalmStyle.secondary)
            Button("Remove rules made in chat (\(count))", role: .destructive) { store.removeChatRules(); count = LearnedRuleStore().chatRules.count }
                .foregroundStyle(count == 0 ? CalmStyle.secondary : CalmStyle.roseInk)
                .disabled(count == 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: enabled) { _, _ in count = LearnedRuleStore().chatRules.count }
    }
}

/// Backs up what you typed to your iCloud. Mail is never backed up.
struct ICloudBackupCard: View {
    @AppStorage(SettingsSync.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Back up to iCloud", isOn: $enabled)
                .onChange(of: enabled) { _, on in if on { SettingsSync.standard.start() } }
            Text("Households, kids, forwarding addresses and your Shoebox address, so a reinstall or a new iPhone gets them back. Mail and Gmail sign-in are never backed up.")
                .font(.caption).foregroundStyle(CalmStyle.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
