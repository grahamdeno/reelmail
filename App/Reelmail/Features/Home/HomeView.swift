import SwiftUI

/// Lovely's Airmail palette. Source of truth: Design/Brand/README.md.
/// Each color has a light (letter paper) and dark (airmail at night) value and follows the iPhone's appearance.
/// Neon (an 80s gel palette: midnight violet, hot pink and electric cyan) replaces both when chosen in Settings.
enum CalmStyle {
    /// Letter paper.
    static let background = Color(light: 0xFBF8F4, dark: 0x17161A, neon: 0x120A24)
    /// Cards, pills and fields that sit on the background.
    static let card = Color(light: 0xFFFFFF, dark: 0x25232A, neon: 0x1F1240)
    static let ink = Color(light: 0x25222A, dark: 0xF2EFEA, neon: 0xF7F0FF)
    static let secondary = Color(light: 0x6D6870, dark: 0xA9A3AC, neon: 0xBBA8E8)
    /// Airmail blue: everything you can tap. In Neon, electric cyan.
    static let blue = Color(light: 0x2E58C8, dark: 0x5B7FE8, neon: 0x1FE5FF)
    /// Text and icons on `blue` (white, except dark ink on Neon's bright cyan).
    static let onBlue = Color(light: 0xFFFFFF, dark: 0xFFFFFF, neon: 0x120A24)
    /// Postmark rose: "Waiting on you" only. Graphics (rings, dots). In Neon, hot pink.
    static let rose = Color(light: 0xD2546E, dark: 0xE0708A, neon: 0xFF2BB4)
    /// Postmark rose for text; passes 4.5:1 on its background in every palette.
    static let roseInk = Color(light: 0xB8405A, dark: 0xF08DA3, neon: 0xFF7AD0)
    /// Done. Swipe tint only, with white text.
    static let green = Color(light: 0x2E8B57, dark: 0x3A9D66, neon: 0x1E8A55)
    static let divider = Color(light: 0xECE6E2, dark: 0x2F2D34, neon: 0x3A2466)
    static let field = card
    static let bubble = Color(light: 0xEFEBE8, dark: 0x2B2930, neon: 0x2C1A57)
    static let warning = Color(light: 0xFFF4E6, dark: 0x3A2E1F, neon: 0x3D1F45)
    static let warningInk = Color(light: 0x7A4A10, dark: 0xF3C98B, neon: 0xFFD36E)
    /// The Undo bar: dark in every palette, with white text.
    static let toast = Color(light: 0x25222A, dark: 0x3A3842, neon: 0x3A1F72)
    /// Neon's signature gel stripe: hot pink into cyan. Used for the line under the top bar.
    static let gel = LinearGradient(colors: [Color(hex: 0xFF2BB4), Color(hex: 0x9B4DFF), Color(hex: 0x1FE5FF)],
                                    startPoint: .leading, endPoint: .trailing)
}

/// The italic "lovely" wordmark. Apple's serif (New York) so nothing extra ships with the app.
struct Wordmark: View {
    var size: CGFloat = 30
    var body: some View {
        Text("lovely").font(.system(size: size, weight: .regular, design: .serif)).italic()
            .foregroundStyle(CalmStyle.blue)
            .accessibilityLabel("Lovely")
    }
}

struct CalmAvatar: View {
    let person: Person
    var size: CGFloat = 40
    /// Rose ring: this person is waiting on you. The only place besides labels that uses rose.
    var waiting = false
    /// Organizations show their company icon (when fetched); people show their Contacts photo.
    var organization = false
    var domain: String? = nil
    private var images: AvatarImages { AvatarImages.shared }

    private var picture: UIImage? {
        organization ? images.logo(for: domain ?? OrganizationKey.domain(of: person.email)) : images.contactPhoto(for: person.email)
    }

    var body: some View {
        Group {
            if let picture {
                if organization {
                    Image(uiImage: picture).resizable().scaledToFit()
                        .frame(width: size * 0.76, height: size * 0.76)
                        .frame(width: size, height: size)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.3))
                } else {
                    Image(uiImage: picture).resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.3))
                }
            } else {
                Text(person.initials).font(.system(size: size * 0.38, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(organization ? CalmStyle.secondary : CalmStyle.blue)
                    .frame(width: size, height: size)
                    .background(organization ? CalmStyle.bubble : CalmStyle.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.3))
            }
        }
            .padding(waiting ? 3 : 0)
            .overlay {
                if waiting { RoundedRectangle(cornerRadius: size * 0.3 + 3).strokeBorder(CalmStyle.rose, lineWidth: 1.75) }
            }
            .accessibilityHidden(true)
    }
}

/// Quiet pill button used for row and sheet actions.
struct CalmActionStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        // Delete, remove, decline and clear buttons (role: .destructive) are rose-red, never blue.
        let tint = configuration.role == .destructive ? CalmStyle.roseInk : CalmStyle.blue
        return configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).frame(minHeight: 40)
            .foregroundStyle(prominent ? CalmStyle.onBlue : tint)
            .background(prominent ? tint : tint.opacity(0.08), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One reversible action offered for a few seconds after a swipe.
enum UndoAction: Equatable {
    case notWaiting(Post)
    case trash(Post)
    case done(Post)
    case later(Post, Date)
    case promise(id: String, text: String)
    case waitingGone(id: String)
    var text: String {
        switch self {
        case .notWaiting: return "Moved out of Waiting on you"
        case .trash: return "Moved to Gmail Trash"
        case .done: return "Done. Marked read in Gmail"
        case .later(_, let date): return "Later: " + LaterSchedule.label(date, now: Date())
        case .promise(_, let text): return text
        case .waitingGone: return "Removed from Waiting on them"
        }
    }
    var id: String {
        switch self {
        case .notWaiting(let p): return "nw-" + p.id
        case .trash(let p): return "tr-" + p.id
        case .done(let p): return "dn-" + p.id
        case .later(let p, _): return "lt-" + p.id
        case .promise(let id, _): return "pr-" + id
        case .waitingGone(let id): return "wg-" + id
        }
    }
}

struct HomeView: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    @State private var undo: UndoAction?
    @AppStorage(BriefSettings.offerSeenKey) private var briefOfferSeen = false
    @AppStorage(BriefSettings.enabledKey) private var briefEnabled = false

    private let rowInsets = EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)

    var body: some View {
        VStack(spacing: 0) {
            // Pinned: the filter pills and account button stay put while the feed scrolls.
            TopBar()
            List {
                StatusNotices()
                    .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)

                if store.filter == .all {
                    digest(store.digest)
                } else {
                    ForEach(store.sections, id: \.section) { group in
                        SectionTitle(section: group.section, count: group.posts.count)
                            .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
                        rows(group.posts, compact: group.section != .waiting)
                    }
                }

                Group {
                    if !store.isLoading, store.sections.isEmpty { EmptyFeedNote() }
                    if !store.isLoading, !store.posts.isEmpty {
                        Text(footerText).font(.caption).foregroundStyle(CalmStyle.secondary).padding(.vertical, 20)
                    }
                }
                .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .refreshable { await store.load() }
        }
        .background(CalmStyle.background)
        .foregroundStyle(CalmStyle.ink).tint(CalmStyle.blue)
        .overlay(alignment: .bottom) {
            if let action = undo {
                UndoBar(text: action.text) { perform(undo: action) }
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: undo?.id)
        .onChange(of: store.lastDone?.id) { _, _ in if let post = store.lastDone { offer(.done(post)) } }
        .onChange(of: store.lastTrashed?.id) { _, _ in if let post = store.lastTrashed { offer(.trash(post)) } }
        .onChange(of: store.lastPutOff?.post.id) { _, _ in if let item = store.lastPutOff { offer(.later(item.post, item.until)) } }
        .onChange(of: store.lastPromiseClosed?.id) { _, _ in if let item = store.lastPromiseClosed { offer(.promise(id: item.id, text: item.text)) } }
        .onChange(of: store.lastWaitingDismissed) { _, _ in if let id = store.lastWaitingDismissed { offer(.waitingGone(id: id)) } }
    }

    @ViewBuilder private func rows(_ posts: [Post], compact: Bool, showAge: Bool = false) -> some View {
        ForEach(posts) { post in
            MailRow(post: post, assessment: store.assessment(for: post), compact: compact, showAge: showAge,
                    onNotWaiting: { notWaiting(post, wholeSender: $0) }, onTrash: { trash(post) })
                .listRowInsets(rowInsets)
                .listRowBackground(CalmStyle.background)
                .listRowSeparatorTint(CalmStyle.divider)
        }
    }

    /// A section title that opens that section's full list.
    private func title(_ text: String, _ count: Int, rose: Bool = false, note: String? = nil, opens key: String? = nil) -> some View {
        Group {
            if let key {
                Button { router.open(.mailList(key)) } label: { DigestTitle(text: text, count: count, rose: rose, note: note, chevron: true) }
                    .buttonStyle(.plain).accessibilityHint("Shows all of them")
            } else {
                DigestTitle(text: text, count: count, rose: rose, note: note)
            }
        }
        .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
    }

    /// Home: what needs you, your to-do (unread, oldest first), notes, people, organizations as groups,
    /// then older read mail in one row.
    @ViewBuilder private func digest(_ d: HomeDigest) -> some View {
        if !d.waiting.isEmpty {
            title("Waiting on you", d.waiting.count, rose: true, opens: "waiting")
            rows(d.waiting, compact: false)
        }
        youSaidYouWould()
        todo(d.todo)
        if !d.notes.isEmpty {
            title("Notes to self", d.notes.count, opens: "notes")
            rows(d.notes, compact: true)
        }
        if !d.people.isEmpty {
            title("People", d.people.count, opens: "people")
            rows(d.people, compact: true)
        }
        let watching = store.waitingOnThem
        if !watching.isEmpty {
            WaitingOnThemRow(count: watching.count)
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        let soon = ComingUp.thisWeek(store.comingUp, now: Date())
        if !soon.isEmpty {
            ComingUpRow(count: soon.count)
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        let newSenders = store.actions == nil ? 0 : store.newSenders.count
        if newSenders > 0 {
            ScreenedOutRow(count: newSenders)
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        BriefRow()
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        let kidProfiles = InsightSettings().load().kids
        if !kidProfiles.isEmpty {
            KidsRow(count: kidProfiles.reduce(0) { $0 + store.kidMail(for: $1).count })
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        let energy = EnergyInsights.summary(store.insights.store, household: nil)
        if energy.latest != nil {
            EnergyRow(summary: energy)
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        let money = MoneyInsights.summary(store.insights.store, households: InsightSettings().load().households)
        if !store.insights.store.bills.isEmpty || !money.accounts.isEmpty {
            MoneyRow(summary: money)
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        if !d.organizations.isEmpty {
            title("Organizations", d.organizations.reduce(0) { $0 + $1.posts.count }, opens: "organizations")
            OrganizationChips(groups: d.organizations)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        if !d.earlier.isEmpty {
            Button { router.open(.mailList("earlier")) } label: {
                HStack(spacing: 10) {
                    Text("Earlier · \(d.earlier.count)").font(.subheadline.weight(.medium)).foregroundStyle(CalmStyle.ink)
                    Spacer()
                    Text("Older than 2 weeks").font(.caption).foregroundStyle(CalmStyle.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.secondary)
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
        if store.doneToday > 0, !briefOfferSeen, !briefEnabled {
            BriefOfferCard()
                .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
    }

    /// What you told people you would do, from mail you sent. Up to three; the rest open from the title.
    @ViewBuilder private func youSaidYouWould() -> some View {
        let promises = store.promises
        if !promises.isEmpty {
            Button { router.open(.promises) } label: { DigestTitle(text: "You said you would", count: promises.count, chevron: true) }
                .buttonStyle(.plain).accessibilityHint("Shows all of them")
                .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
            ForEach(promises.prefix(3)) { item in
                PromiseCard(item: item)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
            }
        }
    }

    /// Your unread mail is your to-do. The oldest is "Next up", one decision at a time; a few more follow.
    @ViewBuilder private func todo(_ todo: [Post]) -> some View {
        let done = store.doneToday
        let note = done > 0 ? "\(done) done today" : nil
        if let next = todo.first {
            title("To do", todo.count, note: note, opens: "todo")
            NextUpCard(post: next, onTrash: { trash(next) })
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
            rows(Array(todo.dropFirst().prefix(4)), compact: true, showAge: true)
            if todo.count > 5 {
                Button { router.open(.mailList("todo")) } label: {
                    Text("\(todo.count - 5) more unread").font(.subheadline.weight(.medium)).foregroundStyle(CalmStyle.blue)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
            }
        } else if !store.isLoading, !store.posts.isEmpty {
            title("To do", 0, note: note)
            Text("Nothing unread. All caught up.").font(.subheadline).foregroundStyle(CalmStyle.secondary)
                .padding(.vertical, 6)
                .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(CalmStyle.background)
        }
    }

    private var footerText: String {
        if store.mode == .sample { return "Fictional mail for the demo." }
        var parts: [String] = []
        if let account = store.account { parts.append(account) }
        if let fetched = store.lastFetched { parts.append("updated " + MailTime.label(fetched).lowercased()) }
        parts.append(store.inboxTruncated ? "showing your most recent inbox mail; older mail stays in Gmail" : "that's all of your inbox")
        return parts.joined(separator: " · ")
    }

    private func notWaiting(_ post: Post, wholeSender: Bool) {
        store.markNotWaiting(post, wholeSender: wholeSender)
        offer(.notWaiting(post))
    }

    private func trash(_ post: Post) {
        Task { await store.moveToTrash(post) }
        offer(.trash(post))
    }

    private func offer(_ action: UndoAction) {
        undo = action
        let id = action.id
        Task { try? await Task.sleep(for: .seconds(6)); if undo?.id == id { undo = nil } }
    }

    private func perform(undo action: UndoAction) {
        switch action {
        case .notWaiting(let post): store.undoNotWaiting(post)
        case .trash(let post): Task { await store.restoreFromTrash(post) }
        case .done(let post): Task { await store.undoDone(post) }
        case .later(let post, _): store.bringBack(post.id)
        case .promise(let id, _): store.reopenPromise(id)
        case .waitingGone(let id): store.restoreWaiting(id)
        }
        undo = nil
    }
}

/// The only thing above the feed: the date and the Settings button. No title, no wordmark.
/// It stays in place while the feed scrolls. Loading shows as a thin bar; the account address and
/// "updated" time are at the end of the list.
struct TopBar: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(CalmStyle.secondary)
                    .padding(.leading, 20)
                Spacer()
                Button { router.open(.settings) } label: {
                    CalmAvatar(person: store.me, size: 36)
                        .overlay { RoundedRectangle(cornerRadius: 36 * 0.3).strokeBorder(CalmStyle.divider, lineWidth: 1) }
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .accessibilityLabel("Settings")
            }
            .padding(.top, 4)
            ZStack {
                if ThemeState.neon {
                    Rectangle().fill(CalmStyle.gel).frame(height: 2)
                } else {
                    Rectangle().fill(CalmStyle.divider).frame(height: 1)
                }
                if store.isLoading || store.isSummarizing {
                    ProgressView().progressViewStyle(.linear).tint(CalmStyle.blue)
                        .accessibilityLabel(store.isLoading ? "Checking for new mail" : "Writing summaries on this iPhone")
                }
            }.frame(height: 2).padding(.top, 4)
        }
        .background(CalmStyle.background)
    }
}

/// A Home digest heading: "NEW · 3". Rose only for Waiting on you.
struct DigestTitle: View {
    let text: String
    let count: Int
    var rose = false
    /// A quiet note on the right, such as "3 done today".
    var note: String? = nil
    var chevron = false
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).tracking(0.8)
            Text("\(count)").opacity(0.8)
            if note != nil || chevron { Spacer(minLength: 8) }
            if let note {
                Label(note, systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                    .foregroundStyle(CalmStyle.blue).textCase(nil)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .font(.caption.weight(.semibold))
        .foregroundStyle(rose ? CalmStyle.roseInk : CalmStyle.secondary)
        .padding(.top, 18).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One button per organization ("National Life Group · 3"); tap to see its mail.
struct OrganizationChips: View {
    @Environment(Router.self) private var router
    @Environment(FeedStore.self) private var store
    let groups: [HomeDigest.OrganizationGroup]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    Button { router.open(.organization(group.id)) } label: {
                        HStack(spacing: 8) {
                            CalmAvatar(person: group.posts[0].email.from, size: 22, organization: true, domain: group.domain)
                            Text(chipText(group)).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                            .padding(.leading, 8).padding(.trailing, 12).frame(minHeight: 36)
                            .foregroundStyle(CalmStyle.ink)
                            .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
    }

    /// "Rink · Sun 9 PM" when the group has a date in the next week, else "Rink · 3".
    private func chipText(_ group: HomeDigest.OrganizationGroup) -> String {
        if let when = ComingUp.chipLabel(for: group.posts, in: store.comingUp, now: Date()) { return "\(group.name) · \(when)" }
        return "\(group.name) · \(group.posts.count)"
    }
}

/// Earlier mail, or one organization's mail, as compact rows.
struct DigestListView: View {
    @Environment(FeedStore.self) private var store
    let key: String
    private var content: (title: String, posts: [Post]) {
        let d = store.digest
        switch key {
        case "earlier": return ("Earlier", d.earlier)
        case "waiting": return ("Waiting on you", d.waiting)
        case "notes": return ("Notes to self", d.notes)
        case "todo", "new": return ("To do", d.todo)
        case "people": return ("People", d.people)
        case "organizations": return ("Organizations", d.organizations.flatMap(\.posts).sorted { $0.email.date > $1.email.date })
        default: break
        }
        let id = String(key.dropFirst(4))
        let group = d.organizations.first { $0.id == id }
        return (group?.name ?? "Organization", group?.posts ?? [])
    }
    var body: some View {
        let c = content
        List {
            if c.posts.isEmpty { Text("Nothing here now.").foregroundStyle(CalmStyle.secondary).listRowBackground(CalmStyle.background) }
            ForEach(c.posts) { post in
                MailRow(post: post, assessment: store.assessment(for: post), compact: key != "waiting", showAge: key == "todo",
                        onNotWaiting: { store.markNotWaiting(post, wholeSender: $0) },
                        onTrash: { Task { await store.moveToTrash(post) } })
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(CalmStyle.background).listRowSeparatorTint(CalmStyle.divider)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle(c.title).navigationBarTitleDisplayMode(.inline)
    }
}

struct SectionTitle: View {
    let section: FeedSection
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(section.title.uppercased()).font(.caption.weight(.semibold)).kerning(0.6)
            Text("\(count)").font(.caption).opacity(0.7)
        }
        .foregroundStyle(section == .waiting ? CalmStyle.roseInk : CalmStyle.secondary)
        .padding(.top, 18).padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyFeedNote: View {
    @Environment(FeedStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.posts.isEmpty ? "No mail loaded yet." : "Nothing here right now.")
                .font(.subheadline.weight(.medium))
            if store.mode == .gmail, store.posts.isEmpty, store.lastFetched != nil {
                Text("Gmail connected, but it returned no inbox mail (\(store.sentByMe.count) sent messages found). Pull down to refresh.")
                    .font(.caption).foregroundStyle(CalmStyle.secondary)
            } else if store.filter == .waiting {
                Text("No one is waiting on a reply from you.").font(.caption).foregroundStyle(CalmStyle.secondary)
            } else if store.filter == .notes {
                Text("Mail from your other addresses shows here. Add them in Settings.").font(.caption).foregroundStyle(CalmStyle.secondary)
            }
        }.padding(.vertical, 24)
    }
}

struct UndoBar: View {
    let text: String
    let undo: () -> Void
    var body: some View {
        HStack {
            Text(text).font(.subheadline)
            Spacer(minLength: 12)
            Button("Undo", action: undo).font(.subheadline.weight(.semibold)).foregroundStyle(Color.white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .foregroundStyle(Color.white)
        .background(CalmStyle.toast, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Errors and reconnect prompts above the feed.
struct StatusNotices: View {
    @Environment(FeedStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.needsMailAccess {
                notice("Google didn't give Lovely access to your mail. Tap Reconnect, and on Google's screen tick the Gmail box (or Select all) before Continue.", button: "Reconnect Gmail")
            } else if store.needsReconnect {
                notice("Google signed you out. While Lovely is in testing this happens every 7 days. Your loaded mail is still here.", button: "Reconnect Gmail")
            } else if store.needsTrashPermission {
                notice("Lovely needs your OK to change mail in Gmail (Trash and Done). It can't send mail or delete anything for good. Reconnect and allow it.", button: "Reconnect Gmail")
            } else if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline)
                    if store.refreshFailed {
                        Button("Try again") { Task { await store.load() } }
                            .buttonStyle(CalmActionStyle(prominent: true)).disabled(store.isLoading)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(CalmStyle.warning, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(CalmStyle.warningInk)
            }
            if let error = store.rules.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(CalmStyle.secondary)
            }
            if store.isLoading, store.posts.isEmpty {
                ProgressView("Loading mail…").font(.caption).frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
        .padding(.top, store.needsReconnect || store.needsTrashPermission || store.errorMessage != nil ? 10 : 0)
    }

    private func notice(_ text: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline)
            Button(button) { Task { await store.connectGmail() } }.buttonStyle(CalmActionStyle(prominent: true))
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.warning, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(CalmStyle.warningInk)
    }
}

/// One message in the feed: a full-width row, not a card. No buttons on the row; tap opens it.
/// Swipe right to reply. Swipe left: a short swipe shows Hide (and Not waiting); swiping all the way moves it to Trash.
struct MailRow: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    let post: Post
    let assessment: TriageAssessment
    /// One line of preview, smaller avatar, no headline: for New, People, organizations and Earlier.
    var compact = false
    /// In the to-do, show how long it has waited ("3 weeks") instead of the date.
    var showAge = false
    var onNotWaiting: (Bool) -> Void = { _ in }
    var onTrash: () -> Void = {}

    private var section: FeedSection { assessment.section }
    private var sensitive: Bool { ConversationPresentation.isSensitive(post.email, summary: post.summary) }
    private var fromPerson: Bool { !store.isAutomated(post) && section != .notes }
    private var waiting: Bool { section == .waiting }
    private var preview: String {
        if sensitive { return "Open to read." }
        if waiting, let ask = assessment.ask { return "\u{201C}" + ask + "\u{201D}" }
        return post.summary.blurb
    }

    var body: some View {
        // Opening never marks mail read. Unread is your to-do; Done is the only thing that clears it.
        Button { router.open(.email(post.id)) } label: {
            if compact { compactBody } else { fullBody }
        }
        .buttonStyle(.plain)
        .modifier(MailRowActions(post: post, assessment: assessment, fromPerson: fromPerson, waiting: waiting,
                                 onNotWaiting: onNotWaiting, onTrash: onTrash))
    }

    /// Organizations name their section ("Rink · Coming up") so you know why it's there.
    private var compactName: String {
        guard !fromPerson, section != .notes else { return post.email.from.name }
        return HomeDigest.organizationName(post.email.from) + " · " + section.title
    }

    /// "Later · tomorrow 9 AM" for mail you put off, so Search and lists show why it left Home.
    private var laterText: String? {
        guard let until = store.laterUntil[post.id], LaterSchedule.isPending(until, now: Date()) else { return nil }
        return "Later \u{00B7} " + LaterSchedule.label(until, now: Date())
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 12) {
            CalmAvatar(person: post.email.from, size: 30, waiting: waiting, organization: !fromPerson && section != .notes)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(compactName).font(.subheadline.weight(post.email.isUnread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(showAge ? HomeDigest.age(of: post.email.date, now: Date()) : MailTime.short(post.email.date))
                        .font(.caption).foregroundStyle(CalmStyle.secondary).lineLimit(1).fixedSize()
                    if post.email.isUnread { Circle().fill(CalmStyle.blue).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                }
                Text(sensitive ? "Private message" : (fromPerson ? post.summary.blurb : post.summary.headline))
                    .font(.subheadline).foregroundStyle(CalmStyle.secondary).lineLimit(1)
                if let laterText { Label(laterText, systemImage: "clock").font(.caption).foregroundStyle(CalmStyle.blue).lineLimit(1) }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var fullBody: some View {
            HStack(alignment: .top, spacing: 12) {
                CalmAvatar(person: post.email.from, size: 36, waiting: waiting, organization: !fromPerson && section != .notes)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(post.email.from.name).font(.subheadline.weight(post.email.isUnread ? .bold : .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(MailTime.short(post.email.date)).font(.caption).foregroundStyle(CalmStyle.secondary).lineLimit(1).fixedSize()
                        if post.email.isUnread { Circle().fill(CalmStyle.blue).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                    }
                    Text(sensitive ? "Private message" : post.summary.headline)
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(preview)
                        .font(.subheadline).foregroundStyle(CalmStyle.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let laterText { Label(laterText, systemImage: "clock").font(.caption).foregroundStyle(CalmStyle.blue).lineLimit(1) }
                    if waiting {
                        Text(assessment.reason).font(.caption.weight(.medium)).foregroundStyle(CalmStyle.roseInk).lineLimit(1)
                    } else if !post.summary.dates.isEmpty, !sensitive {
                        Label(post.summary.dates.prefix(2).joined(separator: " · "), systemImage: "calendar")
                            .font(.caption).foregroundStyle(CalmStyle.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
    }
}

/// Swipes and the long-press menu, shared by full and compact rows.
private struct MailRowActions: ViewModifier {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    let post: Post
    let assessment: TriageAssessment
    let fromPerson: Bool
    let waiting: Bool
    let onNotWaiting: (Bool) -> Void
    let onTrash: () -> Void
    private var section: FeedSection { assessment.section }

    func body(content: Content) -> some View {
        content
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if fromPerson {
                Button { router.draftPostID = post.id } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .tint(CalmStyle.blue)
            }
            if post.email.isUnread {
                Button { Task { await store.markDone(post) } } label: { Label("Done", systemImage: "checkmark") }
                    .tint(CalmStyle.green)
            }
        }
        // First button = the full swipe. Short swipe reveals all of them.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onTrash) { Label("Trash", systemImage: "trash") }
            Button { store.hide(post) } label: { Label("Hide", systemImage: "eye.slash") }.tint(CalmStyle.secondary)
            if post.email.isUnread, let tomorrow = LaterSchedule.options(now: Date()).first(where: { $0.title == "Tomorrow" }) {
                Button { store.putOff(post, until: tomorrow.date) } label: { Label("Later", systemImage: "clock") }.tint(CalmStyle.blue)
            }
            if waiting {
                Button { onNotWaiting(false) } label: { Label("Not waiting", systemImage: "checkmark.circle") }.tint(CalmStyle.roseInk)
            }
        }
        .contextMenu {
            Section("Why it's here: " + assessment.reason) {
                if fromPerson {
                    Button { router.draftPostID = post.id } label: { Label("Draft reply", systemImage: "arrowshape.turn.up.left") }
                    Button { router.open(.thread(post.email.from)) } label: { Label("Conversation with \(post.email.from.firstName)", systemImage: "bubble.left") }
                }
            }
            if post.email.isUnread {
                Section {
                    Button { Task { await store.markDone(post) } } label: { Label("Done (mark read in Gmail)", systemImage: "checkmark.circle") }
                }
            }
            Section {
                if waiting {
                    Button { onNotWaiting(false) } label: { Label("Not waiting on me", systemImage: "checkmark.circle") }
                    Button { onNotWaiting(true) } label: { Label("Never put \(post.email.from.firstName) in Waiting", systemImage: "person.crop.circle.badge.checkmark") }
                } else if store.isMarkedNotWaiting(post) {
                    Button { store.undoNotWaiting(post) } label: { Label("Put back in Waiting", systemImage: "arrow.uturn.backward") }
                }
                if section == .notes, store.otherAddresses.contains(post.email.from.email.lowercased()) {
                    Button { store.removeOtherAddress(post.email.from.email) } label: { Label("This isn't my address", systemImage: "person.crop.circle.badge.xmark") }
                } else if fromPerson, section != .notes {
                    Button { store.addOtherAddress(post.email.from.email) } label: { Label("This is another address of mine", systemImage: "person.crop.circle.badge.checkmark") }
                }
            }
            Section {
                Button { store.hide(post) } label: { Label("Hide in Lovely", systemImage: "eye.slash") }
                Button { store.setSenderRule(post.email.from.email, destination: .reading) } label: { Label("Move sender to Reading", systemImage: "newspaper") }
                Button { store.setSenderRule(post.email.from.email, destination: .filtered) } label: { Label("Filter this sender", systemImage: "line.3.horizontal.decrease.circle") }
                Button { store.setSenderRule(post.email.from.email, destination: nil) } label: { Label("Remove sender rule", systemImage: "arrow.uturn.backward") }
            }
            Section {
                Button(role: .destructive, action: onTrash) { Label("Move to Gmail Trash", systemImage: "trash") }
            }
        }
        .accessibilityHint(waiting ? "Waiting on you. Swipe right to reply, swipe left to hide, mark not waiting or move to Trash."
                           : post.email.isUnread ? "On your to-do. Swipe right for Done, swipe left to hide or move to Trash." : "Swipe left to hide or move to Trash.")
    }
}

/// Senders and messages a saved rule keeps out of the feed. Rules only affect this app.
struct FilteredMailReview: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text(store.mode == .sample ? "Fictional mail. Rules change the demo only." : "Saved rules only change what Lovely shows. They never change Gmail.").font(.subheadline)
                    if let error = store.rules.persistenceError { Text(error).font(.subheadline) }
                    if store.filteredPosts.isEmpty { Text("Nothing is filtered.").font(.subheadline).foregroundStyle(CalmStyle.secondary) }
                    ForEach(store.filteredPosts) { post in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(post.email.from.name).font(.headline)
                            Text(ConversationPresentation.isSensitive(post.email, summary: post.summary) ? "Private message" : post.email.subject).font(.subheadline)
                            Text(store.rules.decision(messageID: post.id, sender: post.email.from.email).reason).font(.caption).foregroundStyle(CalmStyle.secondary)
                            HStack {
                                Button("Restore sender") { store.setSenderRule(post.email.from.email, destination: nil) }.buttonStyle(CalmActionStyle())
                                Button("Keep this message") { store.setMessageRule(post.id, destination: .inbox) }.buttonStyle(CalmActionStyle())
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16)).disabled(store.rules.persistenceError != nil)
                    }
                }.padding(20)
            }.background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
                .navigationTitle("Filtered senders").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(CalmStyle.blue)
    }
}

/// The oldest unread message, on its own: one decision at a time.
struct NextUpCard: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    let post: Post
    var onTrash: () -> Void = {}

    private var age: TimeInterval { Date().timeIntervalSince(post.email.date) }
    private var stale: Bool { age >= HomeDigest.staleAfter }
    private var sensitive: Bool { ConversationPresentation.isSensitive(post.email, summary: post.summary) }
    private var organization: Bool { store.isAutomated(post) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { router.open(.email(post.id)) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEXT UP").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(CalmStyle.blue)
                    HStack(alignment: .top, spacing: 12) {
                        CalmAvatar(person: post.email.from, size: 36, organization: organization)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(organization ? HomeDigest.organizationName(post.email.from) : post.email.from.name)
                                .font(.subheadline.weight(.bold)).lineLimit(1)
                            Text(sensitive ? "Private message" : post.summary.headline)
                                .font(.subheadline.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if !sensitive {
                                Text(post.summary.blurb).font(.subheadline).foregroundStyle(CalmStyle.secondary).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    Text((store.isBackFromLater(post) ? "Back from Later. " : "")
                         + (stale ? "Still need this? Unread \(HomeDigest.age(of: post.email.date, now: Date()))."
                                  : "Unread \(HomeDigest.age(of: post.email.date, now: Date())).")
                    )
                        .font(.caption.weight(.medium)).foregroundStyle(CalmStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the message")
            HStack(spacing: 8) {
                Button { Task { await store.markDone(post) } } label: { Label("Done", systemImage: "checkmark").labelStyle(.titleAndIcon) }
                    .buttonStyle(CalmActionStyle(prominent: true)).lineLimit(1)
                    .accessibilityHint("Marks it read in Gmail")
                LaterMenu(post: post) {
                    Image(systemName: "clock").font(.body.weight(.medium)).foregroundStyle(CalmStyle.blue)
                        .frame(minWidth: 44, minHeight: 40)
                }
                if !organization {
                    Button { router.draftPostID = post.id } label: { Label("Reply", systemImage: "arrowshape.turn.up.left").labelStyle(.titleAndIcon) }
                        .buttonStyle(CalmActionStyle()).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onTrash) {
                    Text("Trash").font(.subheadline).foregroundStyle(CalmStyle.roseInk).frame(minWidth: 44, minHeight: 40)
                }.buttonStyle(.plain).accessibilityLabel("Move to Gmail Trash")
            }
        }
        .padding(14)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
