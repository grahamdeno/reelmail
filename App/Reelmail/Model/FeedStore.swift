import Foundation
import Observation

@MainActor
@Observable
final class FeedStore {
    private(set) var posts: [Post] = []
    private(set) var sentByMe: [Email] = []
    private(set) var mode: DataMode = .sample
    private(set) var isLoading = false
    private(set) var isSummarizing = false
    /// Set when Gmail needs a fresh sign-in. Loaded mail stays on screen.
    private(set) var needsReconnect = false
    /// Set when a Trash request was refused because this sign-in predates the Trash permission.
    private(set) var needsTrashPermission = false
    /// Set when Google's consent left out Gmail access (the Gmail box unticked), so nothing can be read.
    private(set) var needsMailAccess = false
    private(set) var account: String?
    private(set) var lastFetched: Date?
    private(set) var inboxTruncated = false
    var errorMessage: String?
    /// True when the last refresh failed, so Home can offer Try again.
    private(set) var refreshFailed = false
    var filter: FeedFilter = .all
    private(set) var hidden: Set<String> = []
    private(set) var seen: Set<String> = []
    let gmail: any GmailInboxClient
    /// Facts read from the last 12 months of mail (bills, energy, appointments). On this phone only.
    let insights: InsightEngine
    /// Sends and forwards wait here for ten seconds so they can be undone.
    let undo = UndoQueue()
    /// Rules for fictional demo mail. Never applied to a real account.
    let demoRules: LocalTriageRules
    /// Rules for the signed-in account. Created when the account is known.
    private(set) var accountRules: LocalTriageRules?
    /// Your right/wrong verdicts on sorting, for the demo and for the signed-in account.
    let demoReview: SortingReview
    private(set) var accountReview: SortingReview?
    private let summarizeOnDevice: Bool
    private let triageDefaults: UserDefaults
    private let cacheStore: MailCacheStore?
    private var summaries: [String: EmailSummary] = [:]
    private var revision = 0
    /// The on-device second opinion for You said you would / Waiting on them. Nil: the rules alone decide.
    private let veto: (any CommitmentVeto)?

    init(gmail: (any GmailInboxClient)? = nil, summarizeOnDevice: Bool = true,
         triageDefaults: UserDefaults = .standard, cacheStore: MailCacheStore? = .standard,
         veto: (any CommitmentVeto)? = nil, insights: InsightEngine? = nil) {
        self.gmail = gmail ?? GmailService()
        self.insights = insights ?? InsightEngine()
        self.summarizeOnDevice = summarizeOnDevice
        let onDevice: (any CommitmentVeto)? = summarizeOnDevice ? AppleIntelligenceVeto() : nil
        self.veto = veto ?? onDevice
        self.triageDefaults = triageDefaults
        self.cacheStore = cacheStore
        demoRules = LocalTriageRules(accountID: "demo-home-v1", defaults: triageDefaults)
        demoReview = SortingReview(accountID: "demo-home-v1", defaults: triageDefaults)
    }

    /// Review verdicts for what is on screen now. Nil in live mode until the account is known.
    var review: SortingReview? { mode == .gmail ? accountReview : demoReview }

    var gmailConfigured: Bool { gmail.config.isConfigured }

    /// Rules that apply to what is on screen now.
    var rules: LocalTriageRules { mode == .gmail ? (accountRules ?? demoRulesPlaceholder) : demoRules }
    /// Until the account is known, live mode has no rules; this empty, unsaved set keeps views simple.
    private let demoRulesPlaceholder = LocalTriageRules(accountID: "unknown-account", defaults: UserDefaults(suiteName: "reelmail.transient") ?? .standard)

    var me: Person {
        if let account {
            // Your display name as it appears on mail you sent, so the avatar shows your initials.
            let name = sentByMe.first(where: { $0.isFromMe && !$0.from.name.isEmpty && !$0.from.name.contains("@") })?.from.name ?? "You"
            return Person(id: account, name: name, email: account, hue: 0.62)
        }
        return SampleData.me
    }

    // MARK: Loading

    /// Loads mail. The work runs in its own task, so leaving the screen or letting go of pull-to-refresh
    /// does not cancel a load that is waiting out Gmail's rate limit (build 1009 showed CancellationError).
    func load() async {
        await Task { await self.performLoad() }.value
    }

    private func performLoad() async {
        revision += 1
        let current = revision
        isLoading = true; isSummarizing = false; errorMessage = nil; refreshFailed = false
        defer { if revision == current { isLoading = false } }
        if gmail.isSignedIn || mode == .gmail {
            await loadGmail(revision: current)
        } else {
            loadSample()
            await upgradeSummaries(revision: current)
        }
    }

    private func loadSample() {
        bump()
        mode = .sample; account = nil; accountRules = nil; needsReconnect = false
        loadDoneCount(); loadLater(); loadMailLists()
        sentByMe = SampleData.sentByMe
        let fallback = FallbackSummarizer()
        posts = SampleData.emails.map { Post(email: $0, summary: fallback.summarizeSync(SummaryInput(email: $0))) }
    }

    private func loadGmail(revision current: Int) async {
        if mode != .gmail { posts = []; hidden.removeAll(); seen.removeAll(); summaries = [:] }
        mode = .gmail
        if posts.isEmpty, let cached = cacheStore?.loadCurrent() { apply(cached) }
        guard gmailConfigured, gmail.isSignedIn else {
            needsReconnect = true
            errorMessage = "Gmail needs reconnecting. No demo mail has been substituted."
            return
        }
        let known = MailboxSnapshot(account: account ?? "", inbox: posts.map(\.email), sent: sentByMe, fetchedAt: lastFetched ?? .distantPast)
        let snapshot: MailboxSnapshot
        do { snapshot = try await gmail.fetchMailbox(known: known, limits: .standard) }
        catch {
            guard current == revision else { return }
            // A cancelled load (app closed mid-load) is not an error worth showing; the next open retries.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if let e = error as? GmailService.GmailError, e.needsReconnect { needsReconnect = true }
            if case GmailService.GmailError.mailAccessNotGranted = error { needsMailAccess = true }
            errorMessage = RefreshProblem.message(for: error)
            refreshFailed = true
            return
        }
        guard current == revision else { return }
        needsReconnect = false; needsMailAccess = false
        setAccount(snapshot.account)
        sentByMe = snapshot.sent
        lastFetched = snapshot.fetchedAt
        inboxTruncated = snapshot.inboxTruncated
        let fallback = FallbackSummarizer()
        posts = snapshot.inbox.map { email in
            Post(email: email, summary: summaries[email.id] ?? fallback.summarizeSync(SummaryInput(email: email)))
        }
        let live = Set(posts.map(\.id))
        summaries = summaries.filter { live.contains($0.key) }
        pruneLater()
        persist()
        await upgradeSummaries(revision: current)
        // Runs after the refresh finishes, so the progress bar does not wait on it.
        sentCheck = Task { await self.checkSentMail(revision: current) }
        insightCheck = Task { await self.insights.refresh(client: self.gmail, account: self.account); await self.verifyNewSenders() }
    }

    /// The background read of older mail for insights. Tests await it.
    private(set) var insightCheck: Task<Void, Never>?

    /// Gmail writes beyond Trash and Done. Nil for demo mail and test doubles. Every call needs a ConfirmedAction.
    var actions: GmailActions? {
        guard mode == .gmail, let service = gmail as? GmailService else { return nil }
        return GmailActions(token: { try await service.accessToken() })
    }

    /// The follow-up work after a refresh (thread lookups and the on-device opinion). Tests await it.
    private(set) var sentCheck: Task<Void, Never>?

    private func apply(_ cache: MailCache) {
        bump()
        setAccount(cache.snapshot.account)
        summaries = cache.summaries
        hidden = cache.hidden
        seen = cache.seen
        verdicts = cache.verdicts ?? [:]
        sentByMe = cache.snapshot.sent
        lastFetched = cache.snapshot.fetchedAt
        inboxTruncated = cache.snapshot.inboxTruncated
        let fallback = FallbackSummarizer()
        posts = cache.snapshot.inbox.map { email in
            // Unread comes from Gmail only. (Older versions marked mail read in Lovely when you opened it; that is ignored.)
            Post(email: email, summary: cache.summaries[email.id] ?? fallback.summarizeSync(SummaryInput(email: email)))
        }
    }

    private func setAccount(_ address: String) {
        guard !address.isEmpty else { return }
        if account != address {
            account = address
            accountRules = LocalTriageRules(accountID: "gmail-" + MailCache.accountKey(address), defaults: triageDefaults)
            for pending in pendingOtherAddresses { accountRules?.setOtherAddress(pending, true) }
            pendingOtherAddresses = []
            accountReview = SortingReview(accountID: "gmail-" + MailCache.accountKey(address), defaults: triageDefaults)
            loadDoneCount(); loadLater(); loadMailLists()
        }
    }

    private func persist() {
        bump()
        guard mode == .gmail, let account, let cacheStore else { return }
        let snapshot = MailboxSnapshot(account: account, inbox: posts.map(\.email), sent: sentByMe,
                                       fetchedAt: lastFetched ?? Date(), inboxTruncated: inboxTruncated)
        let cache = MailCache(snapshot: snapshot, summaries: summaries, hidden: hidden, seen: seen, verdicts: verdicts)
        do { try cacheStore.save(cache) } catch { errorMessage = "Loaded mail could not be saved on this phone. It will reload next time." }
    }

    func connectGmail() async {
        do { try await gmail.signIn(); needsReconnect = false; needsTrashPermission = false; needsMailAccess = false; await load() }
        catch {
            if case GmailService.GmailError.mailAccessNotGranted = error { needsMailAccess = true; needsReconnect = true }
            errorMessage = error.localizedDescription
        }
    }

    func disconnectGmail() async {
        bump(); revision += 1; gmail.signOut(); cacheStore?.removeAll(); insights.reset()  // Households, kids, forwarding addresses and Shoebox are typed by you, not read from mail: they stay.
        posts = []; sentByMe = []; hidden.removeAll(); seen.removeAll(); summaries = [:]
        filter = .all; mode = .sample; account = nil; accountRules = nil; needsReconnect = false
        lastFetched = nil; inboxTruncated = false
        await load()
    }

    /// Apple Intelligence pass over posts that still carry the fallback summary. Results are saved.
    private func upgradeSummaries(revision current: Int) async {
        guard summarizeOnDevice, ModelStatus.current.isAvailable, current == revision else { return }
        let todo = posts.filter { $0.summary.engine != .appleIntelligence }
        guard !todo.isEmpty else { return }
        isSummarizing = true
        defer { if current == revision { isSummarizing = false } }
        AppleIntelligenceSummarizer.prewarm()
        let ai = AppleIntelligenceSummarizer()
        var changed = false
        for post in todo {
            guard current == revision else { return }
            let summary = try? await ai.summarize(SummaryInput(email: post.email))
            guard current == revision else { return }
            if let summary, let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index].summary = summary
                summaries[post.id] = summary
                changed = true
                bump()
            }
        }
        if changed { persist() }
    }

    // MARK: Reading the feed

    /// Everything the screens need, worked out once per change instead of once per screen draw.
    /// (Sorting 120 messages with text rules on every draw is what made switching tabs lag.)
    private struct Derived {
        var context: TriageContext
        var assessments: [String: TriageAssessment] = [:]
        var automated: Set<String> = []
        var postsByID: [String: Post] = [:]
        var active: [Post] = []
        var people: [Person] = []
        /// Senders of automated mail: companies, schools' systems, apps.
        var organizations: [Person] = []
        /// Post ids from organizations: automated mail and blind-copy lists.
        var organizationPosts: Set<String> = []
        /// One person with several addresses (same full name): canonical id → every Person it stands for.
        var aliases: [String: [Person]] = [:]
        var waitingPeople: Set<String> = []
        var unreadPeople: Set<String> = []
        var duplicateNames: Set<String> = []
        var theirs: [String: [Email]] = [:]
        var sentTo: [String: [Email]] = [:]
        var lastContact: [String: Date] = [:]
        var noteCount = 0
    }
    @ObservationIgnored private var derivedCache: Derived?
    @ObservationIgnored private var derivedKey = ""
    @ObservationIgnored private var dataVersion = 0
    private func bump() { dataVersion &+= 1 }
    /// Observed by views, so New senders refreshes after a lookup or an Accept (the lists live in UserDefaults).
    private(set) var screeningVersion = 0
    func bumpForScreening() { screeningVersion &+= 1 }

    private var derived: Derived {
        // Reading these registers the dependencies, so views refresh when any of them change.
        let rules = self.rules
        let key = "\(dataVersion)|\(ObjectIdentifier(rules).hashValue)|\(rules.revision)|\(posts.count)|\(sentByMe.count)|\(hidden.count)|\(mode.rawValue)|\(account ?? "")|\(lastFetched?.timeIntervalSince1970 ?? 0)"
        if let cache = derivedCache, key == derivedKey { return cache }
        let built = buildDerived(rules: rules)
        derivedCache = built
        derivedKey = key
        return built
    }

    /// Home reads several lists on every redraw. Each is rebuilt only when its inputs change (or the minute turns),
    /// so scrolling and switching tabs don't re-scan every message.
    @ObservationIgnored private var memo: [String: (key: Int, value: Any)] = [:]
    private func memoized<T>(_ name: String, _ inputs: [AnyHashable], build: () -> T) -> T {
        _ = derived // registers the mail dependencies and refreshes derivedKey
        var h = Hasher()
        h.combine(derivedKey)
        h.combine(Int(Date().timeIntervalSince1970 / 60))
        for i in inputs { h.combine(i) }
        let key = h.finalize()
        if let m = memo[name], m.key == key, let v = m.value as? T { return v }
        let v = build()
        memo[name] = (key, v)
        return v
    }

    /// For extensions in other files.
    func cached<T>(_ name: String, _ inputs: [AnyHashable], build: () -> T) -> T { memoized(name, inputs, build: build) }

    private func buildDerived(rules: LocalTriageRules) -> Derived {
        let context = TriageContext(account: mode == .gmail ? account : SampleData.me.email, sent: sentByMe,
                                    otherAddresses: rules.otherAddresses,
                                    now: mode == .gmail ? (lastFetched ?? Date()) : Date())
        var d = Derived(context: context)
        for post in posts {
            let decision = rules.decision(messageID: post.id, sender: post.email.from.email)
            let a = FeedTriage.assess(post, route: decision.destination, routeReason: decision.reason,
                                      notWaiting: rules.isNotWaiting(messageID: post.id, sender: post.email.from.email),
                                      context: context)
            d.assessments[post.id] = a
            d.postsByID[post.id] = post
            if FeedTriage.automatedReason(post.email) != nil { d.automated.insert(post.id) }
            d.theirs[post.email.from.id, default: []].append(post.email)
            guard !hidden.contains(post.id), decision.destination != .filtered else { continue }
            d.active.append(post)
            if a.section == .notes { d.noteCount += 1 }
            if post.email.isUnread { d.unreadPeople.insert(post.email.from.id) }
            if a.section == .waiting { d.waitingPeople.insert(post.email.from.id) }
        }
        for mail in sentByMe { for address in Set(mail.recipients.map { $0.lowercased() }) { d.sentTo[address, default: []].append(mail) } }

        var seenIDs = Set<String>()
        var waiting: [Person] = []; var rest: [Person] = []
        let wrote = Set(d.sentTo.keys.map(TriageContext.canonical))
        // Organizations: automated mail, lists sent as a blind copy, and senders who don't read as a person
        // (you've never written to them and the name is a company's: "National Life Group", an address alone).
        func isOrganization(_ post: Post) -> Bool {
            if d.automated.contains(post.id) || context.addressing(of: post.email) == .blindCopy { return true }
            let from = post.email.from
            return !PersonSignals.looksLikePerson(name: from.name, email: from.email,
                                                  youWrote: wrote.contains(TriageContext.canonical(from.email)))
        }
        var byName: [String: String] = [:]
        let separate = rules.separatePeople
        for post in d.active where !isOrganization(post) && d.assessments[post.id]?.section != .notes && !context.isMine(post.email) {
            let p = post.email.from
            guard seenIDs.insert(p.id).inserted else { continue }
            // Same full name from another address: the same person (unless you said otherwise).
            if !separate.contains(p.email.lowercased()), let key = PersonSignals.mergeKey(for: p.name) {
                if let canonical = byName[key] { d.aliases[canonical, default: []].append(p); continue }
                byName[key] = p.id
            }
            d.aliases[p.id] = [p]
            if d.waitingPeople.contains(p.id) { waiting.append(p) } else { rest.append(p) }
        }
        // A merged person is waiting or unread when any of their addresses is.
        for (canonical, persons) in d.aliases where persons.count > 1 {
            if persons.contains(where: { d.waitingPeople.contains($0.id) }) { d.waitingPeople.insert(canonical) }
            if persons.contains(where: { d.unreadPeople.contains($0.id) }) { d.unreadPeople.insert(canonical) }
        }
        let waitingIDs = d.waitingPeople
        d.people = (waiting + rest).sorted { waitingIDs.contains($0.id) && !waitingIDs.contains($1.id) }
        for post in d.active where isOrganization(post) { d.organizationPosts.insert(post.id) }
        for post in d.active where isOrganization(post) && d.assessments[post.id]?.section != .notes && !context.isMine(post.email) {
            let p = post.email.from
            guard seenIDs.insert(p.id).inserted else { continue }
            d.organizations.append(p)
        }
        var names: [String: Int] = [:]
        for p in d.people { names[p.name, default: 0] += 1; d.lastContact[p.id] = Self.thread(for: p, in: d).last?.date }
        for p in d.organizations { d.lastContact[p.id] = Self.thread(for: p, in: d).last?.date }
        d.duplicateNames = Set(names.filter { $0.value > 1 }.keys)
        return d
    }

    private static func thread(for person: Person, in d: Derived) -> [Email] {
        let persons = d.aliases[person.id] ?? [person]
        var seen = Set<String>()
        return persons.flatMap { (d.theirs[$0.id] ?? []) + (d.sentTo[$0.email.lowercased()] ?? []) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date < $1.date }
    }

    /// Every address a person writes from, when several were merged by name.
    func addresses(of person: Person) -> [String] { (derived.aliases[person.id] ?? [person]).map(\.email) }

    /// "Not the same person": stop merging this address into someone with the same name.
    func separate(address: String) { rules.setSeparatePerson(address, true); bump() }

    /// Who you are and what you replied to, measured against the last refresh (or now, before one).
    var triageContext: TriageContext { derived.context }

    func assessment(for post: Post) -> TriageAssessment {
        let d = derived
        if let known = d.assessments[post.id] { return known }
        let decision = rules.decision(messageID: post.id, sender: post.email.from.email)
        return FeedTriage.assess(post, route: decision.destination, routeReason: decision.reason,
                                 notWaiting: rules.isNotWaiting(messageID: post.id, sender: post.email.from.email), context: d.context)
    }

    func section(for post: Post) -> FeedSection { assessment(for: post).section }
    /// True when a system, list or notice sent it (not a person).
    func isAutomated(_ post: Post) -> Bool { derived.automated.contains(post.id) }

    /// Everything not hidden and not filtered by a rule.
    var activePosts: [Post] { derived.active }

    /// The feed in priority order: sections top to bottom, newest first within each.
    var sections: [(section: FeedSection, posts: [Post])] {
        memoized("sections", [filter]) {
        let d = derived
        var grouped: [FeedSection: [Post]] = [:]
        for post in d.active {
            let section = d.assessments[post.id]?.section ?? .people
            if filter.includes(section) { grouped[section, default: []].append(post) }
        }
        return FeedSection.allCases.compactMap { s in
            guard let items = grouped[s], !items.isEmpty else { return nil }
            return (s, items.sorted { $0.email.date > $1.email.date })
        }
        }
    }

    /// Sense reports live on the Energy page once one has been read. Local only; Gmail is not changed.
    private func isEnergyReport(_ post: Post) -> Bool {
        guard mode == .gmail else { return false }
        return EnergyInsights.shouldHideFromHome(domain: InsightText.registrable(InsightText.domain(of: post.email.from.email)), fromName: post.email.from.name, store: insights.store)
    }

    /// The Home "All" view.
    var digest: HomeDigest {
        memoized("digest", [laterUntil, insights.store.energy.isEmpty]) {
        let d = derived
        let overrides = rules.organizationOverrides
        let clock = Date()
        // Mail put off with Later is off Home until its time; mail that has come back goes first in To do.
        var digest = HomeDigest.make(active: d.active.filter { !LaterSchedule.isPending(laterUntil[$0.id] ?? .distantPast, now: clock) && !isEnergyReport($0) },
                                     section: { d.assessments[$0.id]?.section ?? .people },
                                     isOrganization: { d.organizationPosts.contains($0.id) },
                                     groupKey: { OrganizationKey.key(for: $0.email.from, overrides: overrides) },
                                     now: mode == .gmail ? (lastFetched ?? Date()) : Date())
        let back = Set(laterUntil.filter { !LaterSchedule.isPending($0.value, now: clock) }.keys)
        if !back.isEmpty { digest.todo = digest.todo.filter { back.contains($0.id) } + digest.todo.filter { !back.contains($0.id) } }
        return digest
        }
    }

    /// Mail with a date still ahead, earliest first (Later-pending mail excluded).
    var comingUp: [ComingUp.Entry] {
        memoized("comingUp", [laterUntil]) {
        let d = derived
        let clock = Date()
        let live = d.active.filter { !LaterSchedule.isPending(laterUntil[$0.id] ?? .distantPast, now: clock) }
        return ComingUp.entries(posts: live, section: { d.assessments[$0.id]?.section ?? .people }, now: clock)
        }
    }

    /// The brief for the morning at `fire`, from the mail loaded now. Later items that come due before then count as back.
    func morningBrief(at fire: Date, showNames: Bool) -> MorningBrief? {
        let d = digest
        let now = Date()
        let activeIDs = Set(derived.active.map(\.id))
        let due = laterUntil.filter { activeIDs.contains($0.key) && LaterSchedule.isPending($0.value, now: now) && $0.value <= fire }.count
        let back = laterUntil.filter { activeIDs.contains($0.key) && !LaterSchedule.isPending($0.value, now: now) }.count + due
        let today = comingUp.filter { Calendar.current.isDate($0.date.start, inSameDayAs: fire) }
        return MorningBrief.make(waiting: d.waiting, todo: d.todo.count + due, promises: promises.count, today: today,
                                 backFromLater: back, showNames: showNames)
    }

    var waitingCount: Int { derived.active.filter { derived.assessments[$0.id]?.section == .waiting }.count }
    var noteCount: Int { derived.noteCount }
    var topics: [MailTopic] { MailTopic.make(posts: activePosts, sent: sentByMe) }

    /// Messages a saved rule keeps out of the feed, for review and undo.
    var filteredPosts: [Post] {
        posts.filter { rules.decision(messageID: $0.id, sender: $0.email.from.email).destination == .filtered }
    }
    var filteredDemoPosts: [Post] { mode == .sample ? filteredPosts : [] }
    var hiddenPosts: [Post] { posts.filter { hidden.contains($0.id) } }
    var unreadCount: Int { activePosts.filter(\.email.isUnread).count }
    var needsReplyPosts: [Post] { activePosts.filter { derived.assessments[$0.id]?.section == .waiting } }

    var people: [Person] { derived.people }
    /// Senders of automated mail, for the People tab's Organizations view.
    var organizations: [Person] { derived.organizations }

    /// Every organization in loaded mail (not only recent), grouped by company.
    var organizationGroups: [HomeDigest.OrganizationGroup] {
        let d = derived
        let overrides = rules.organizationOverrides
        return HomeDigest.OrganizationGroup.group(d.active.filter { d.organizationPosts.contains($0.id) && d.assessments[$0.id]?.section != .notes },
                                                  key: { OrganizationKey.key(for: $0.email.from, overrides: overrides) })
    }

    func organizationGroup(_ key: String) -> HomeDigest.OrganizationGroup? { organizationGroups.first { $0.id == key } }

    /// "Merge with…": every sender of `group` joins `target`.
    func merge(_ group: HomeDigest.OrganizationGroup, into target: HomeDigest.OrganizationGroup) {
        for sender in group.senders { rules.setOrganization(sender: sender.address, groupKey: target.id) }
        bump()
    }

    /// "Split this sender out" into its own group, or back to automatic grouping with `nil`.
    func splitOut(sender: String, _ split: Bool = true) {
        rules.setOrganization(sender: sender, groupKey: split ? OrganizationKey.splitKey(for: sender) : nil)
        bump()
    }

    /// The summary at the top of an organization's page.
    func profile(for group: HomeDigest.OrganizationGroup) -> PersonProfile {
        let d = derived
        let theirs = group.posts.map(\.email)
        var asks: [String: String] = [:]
        for email in theirs {
            if let a = d.assessments[email.id], a.section == .waiting { asks[email.id] = a.ask ?? FallbackSummarizer.firstSentence(of: email.body) }
        }
        let addresses = Set(group.senders.map(\.address))
        let mine = sentByMe.filter { mail in mail.recipients.contains { addresses.contains($0.lowercased()) } }
        let lead = Person(id: group.id, name: group.name, email: group.senders.first?.address ?? "", hue: 0.5)
        return PersonProfile.make(person: lead, theirs: theirs, mine: mine, waitingAsk: asks, isOrganization: true,
                                  now: mode == .gmail ? (lastFetched ?? Date()) : Date())
    }

    enum ContactKind: String, CaseIterable, Identifiable {
        case people = "People", organizations = "Organizations", all = "All"
        var id: String { rawValue }
    }

    func contacts(_ kind: ContactKind) -> [Person] {
        switch kind {
        case .people: return derived.people
        case .organizations: return derived.organizations
        case .all: return derived.people + derived.organizations
        }
    }
    func needsReply(_ person: Person) -> Bool { derived.waitingPeople.contains(person.id) }
    func hasUnread(_ person: Person) -> Bool { derived.unreadPeople.contains(person.id) }
    func sharesName(_ person: Person) -> Bool { derived.duplicateNames.contains(person.name) }
    func lastContact(_ person: Person) -> Date { derived.lastContact[person.id] ?? .distantPast }
    func posts(from person: Person) -> [Post] { posts.filter { $0.email.from.id == person.id } }
    func conversation(with person: Person) -> [Email] { Self.thread(for: person, in: derived) }

    /// The summary at the top of a person's page.
    func profile(for person: Person) -> PersonProfile {
        let d = derived
        let persons = d.aliases[person.id] ?? [person]
        let theirs = persons.flatMap { d.theirs[$0.id] ?? [] }
        var asks: [String: String] = [:]
        for email in theirs {
            if let a = d.assessments[email.id], a.section == .waiting { asks[email.id] = a.ask ?? FallbackSummarizer.firstSentence(of: email.body) }
        }
        var seenMine = Set<String>()
        let mine = persons.flatMap { d.sentTo[$0.email.lowercased()] ?? [] }.filter { seenMine.insert($0.id).inserted }
        return PersonProfile.make(person: person, theirs: theirs, mine: mine, waitingAsk: asks,
                                  isOrganization: d.organizations.contains(where: { $0.id == person.id }),
                                  now: mode == .gmail ? (lastFetched ?? Date()) : Date())
    }
    func post(for email: Email) -> Post? { derived.postsByID[email.id] }
    func search(_ query: String) -> [Post] {
        let tokens = MailSearch.tokens(query)
        guard !tokens.isEmpty else { return [] }
        return activePosts.filter { MailSearch.matches($0, tokens: tokens) }.sorted { $0.email.date > $1.email.date }
    }

    /// People whose name or address matches, most recent contact first.
    func searchPeople(_ query: String) -> [Person] {
        let tokens = MailSearch.tokens(query)
        guard !tokens.isEmpty else { return [] }
        return derived.people.filter { MailSearch.matches($0, tokens: tokens) }
            .sorted { lastContact($0) > lastContact($1) }
    }

    /// Organizations whose name, domain or any sending address matches, A to Z.
    func searchOrganizations(_ query: String) -> [HomeDigest.OrganizationGroup] {
        let tokens = MailSearch.tokens(query)
        guard !tokens.isEmpty else { return [] }
        return organizationGroups.filter { MailSearch.matches($0, tokens: tokens) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Trash (the only change Lovely makes to Gmail, and only when you ask)

    /// Moves a message to Gmail's Trash (recoverable for 30 days). It leaves Lovely at once; if Gmail refuses,
    /// it comes back and the reason is shown. In demo mode this only hides the fictional message.
    /// The last message moved to Trash, so a screen can offer Undo.
    private(set) var lastTrashed: Post?

    func moveToTrash(_ post: Post) async {
        hidden.insert(post.id); lastTrashed = post; persist()
        guard mode == .gmail else { return }
        do { try await gmail.trash(messageID: post.id) }
        catch { trashFailed(post, error) }
    }

    /// Undo for `moveToTrash`.
    func restoreFromTrash(_ post: Post) async {
        if mode == .gmail {
            do { try await gmail.untrash(messageID: post.id) }
            catch { errorMessage = "Gmail could not take that message out of Trash. Open Trash in Gmail to restore it. \(error.localizedDescription)"; return }
        }
        hidden.remove(post.id); persist()
    }

    private func trashFailed(_ post: Post, _ error: Error) {
        hidden.remove(post.id); persist()
        if lastTrashed?.id == post.id { lastTrashed = nil }
        if let e = error as? GmailService.GmailError {
            switch e {
            case .needsTrashPermission: needsTrashPermission = true
            case .sessionExpired, .notSignedIn: needsReconnect = true
            default: break
            }
        }
        errorMessage = "That message was not moved to Trash. \(error.localizedDescription)"
    }

    // MARK: Done (mark read in Gmail; approved 2026-11-02)

    /// The last message marked Done, so a screen can offer Undo.
    private(set) var lastDone: Post?

    /// Your to-do is your unread mail. Done marks the message read in Gmail, so the list matches Gmail
    /// everywhere. It leaves the to-do at once; if Gmail refuses, it comes back and the reason is shown.
    /// Opening a message never marks it read. In demo mode this only changes the fictional message.
    func markDone(_ post: Post) async {
        guard setUnread(post.id, false) else { return }
        InteractionLog().recordDone()
        countDone(+1)
        lastDone = post
        persist()
        guard mode == .gmail else { return }
        do { try await gmail.markRead(messageID: post.id) }
        catch {
            setUnread(post.id, true); countDone(-1); persist()
            if lastDone?.id == post.id { lastDone = nil }
            changeFailed(error)
            errorMessage = "That message is still unread in Gmail. \(error.localizedDescription)"
        }
    }

    /// Undo for `markDone`: unread again in Gmail, back on the to-do.
    func undoDone(_ post: Post) async {
        if mode == .gmail {
            do { try await gmail.markUnread(messageID: post.id) }
            catch { errorMessage = "Gmail could not mark that message unread again. Mark it unread in Gmail to put it back. \(error.localizedDescription)"; return }
        }
        if setUnread(post.id, true) { countDone(-1) }
        if lastDone?.id == post.id { lastDone = nil }
        persist()
    }

    func isTodo(_ post: Post) -> Bool { posts.first { $0.id == post.id }?.email.isUnread ?? false }

    @discardableResult
    private func setUnread(_ id: String, _ unread: Bool) -> Bool {
        guard let i = posts.firstIndex(where: { $0.id == id }), posts[i].email.isUnread != unread else { return false }
        bump()
        posts[i].email.isUnread = unread
        return true
    }

    /// How many to-dos you've marked Done today, on this phone. Resets each day.
    var doneToday: Int { doneDay == Self.dayKey(Date()) ? doneCount : 0 }
    private var doneDay = ""
    private var doneCount = 0
    private var doneKey: String { "lovely.doneToday." + (mode == .gmail ? MailCache.accountKey(account ?? "") : "demo") }
    private func loadDoneCount() {
        let saved = triageDefaults.dictionary(forKey: doneKey)
        doneDay = saved?["day"] as? String ?? ""
        doneCount = saved?["count"] as? Int ?? 0
    }
    private func countDone(_ delta: Int) {
        doneCount = max(0, doneToday + delta)
        doneDay = Self.dayKey(Date())
        triageDefaults.set(["day": doneDay, "count": doneCount], forKey: doneKey)
    }
    // MARK: You said you would / Waiting on them (local; reads only)

    /// On-device verdicts, by "commit-<id>" or "ask-<id>". A missing verdict means no opinion; `false` removes the item.
    private(set) var verdicts: [String: Bool] = [:]
    /// Thread lookups from this session, by thread id. Read-only; cleared on each full refresh.
    private(set) var threadChecks: [String: [ThreadSender]] = [:]
    private var promisesClosed: Set<String> = []
    private var waitingDismissed: Set<String> = []
    /// The last item removed, so Home can offer Undo.
    private(set) var lastPromiseClosed: (id: String, text: String)?
    private(set) var lastWaitingDismissed: String?

    private var accountKeyForLists: String { mode == .gmail ? MailCache.accountKey(account ?? "") : "demo" }
    private func loadMailLists() {
        promisesClosed = Set(triageDefaults.stringArray(forKey: "lovely.promises.closed." + accountKeyForLists) ?? [])
        waitingDismissed = Set(triageDefaults.stringArray(forKey: "lovely.waitingOnThem.dismissed." + accountKeyForLists) ?? [])
    }
    private func clock() -> Date { derived.context.now }

    /// Commitments you made in mail you sent that nobody has closed. Up to 14 days old.
    var promises: [PromiseRules.Item] {
        memoized("promises", [promisesClosed, verdicts]) {
        PromiseRules.open(sent: sentByMe, inbox: posts.map(\.email), context: derived.context, closed: promisesClosed,
                          veto: { [verdicts = self.verdicts] email, _ in verdicts[VerdictCache.commitKey(email.id)] ?? true }, now: clock())
        }
    }

    /// Asks you sent that nobody has answered, 3 to 21 days old.
    var waitingOnThem: [WaitingOnThem.Item] {
        memoized("waitingOnThem", [waitingDismissed, verdicts, threadChecks.count]) {
        let context = derived.context
        let candidates = WaitingOnThem.candidates(sent: sentByMe, context: context, dismissed: waitingDismissed, now: clock())
        return WaitingOnThem.open(candidates: candidates, inbox: posts.map(\.email), context: context, lookups: threadChecks)
            .filter { verdicts[VerdictCache.askKey($0.id)] ?? true }
        }
    }

    func closePromise(_ item: PromiseRules.Item, notAPromise: Bool = false) {
        promisesClosed.insert(item.id); lastPromiseClosed = (item.id, notAPromise ? "Not a promise" : "Marked done")
        triageDefaults.set(Array(promisesClosed), forKey: "lovely.promises.closed." + accountKeyForLists)
    }
    func reopenPromise(_ id: String) {
        promisesClosed.remove(id)
        triageDefaults.set(Array(promisesClosed), forKey: "lovely.promises.closed." + accountKeyForLists)
    }
    func dismissWaiting(_ item: WaitingOnThem.Item) {
        waitingDismissed.insert(item.id); lastWaitingDismissed = item.id
        triageDefaults.set(Array(waitingDismissed), forKey: "lovely.waitingOnThem.dismissed." + accountKeyForLists)
    }
    func restoreWaiting(_ id: String) {
        waitingDismissed.remove(id)
        triageDefaults.set(Array(waitingDismissed), forKey: "lovely.waitingOnThem.dismissed." + accountKeyForLists)
    }

    /// After a refresh: confirm unanswered asks with read-only thread lookups (at most 20), then ask the on-device
    /// model for its opinion on what is left. Both only ever remove items.
    private func checkSentMail(revision current: Int) async {
        guard mode == .gmail else { return }
        let context = derived.context
        let candidates = WaitingOnThem.candidates(sent: sentByMe, context: context, dismissed: waitingDismissed, now: clock())
        let inbox = posts.map(\.email)
        // Fresh answers each refresh, swapped in at the end so items do not flicker while the lookups run.
        var fresh: [String: [ThreadSender]] = [:]
        for item in WaitingOnThem.lookupTargets(candidates: candidates, inbox: inbox, already: []) {
            guard current == revision else { return }
            if let senders = try? await gmail.threadSenders(threadID: item.email.threadId) {
                fresh[item.email.threadId] = senders
            }
        }
        threadChecks = fresh
        guard let veto, current == revision else { return }
        for item in promises where verdicts[VerdictCache.commitKey(item.id)] == nil {
            if let verdict = await veto.isCommitment(item.text) { verdicts[VerdictCache.commitKey(item.id)] = verdict }
        }
        for item in waitingOnThem where verdicts[VerdictCache.askKey(item.id)] == nil {
            if let verdict = await veto.asksRecipient(item.email.body) { verdicts[VerdictCache.askKey(item.id)] = verdict }
        }
        persist()
    }

    // MARK: Later (local only; Gmail is not changed)

    /// Message id → when it comes back. A time in the past means it has come back and is waiting at the top of To do.
    private(set) var laterUntil: [String: Date] = [:]
    private var laterKey: String { "lovely.later." + (mode == .gmail ? MailCache.accountKey(account ?? "") : "demo") }
    private func loadLater() {
        let saved = triageDefaults.dictionary(forKey: laterKey) as? [String: Double] ?? [:]
        laterUntil = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }
    private func saveLater() {
        triageDefaults.set(laterUntil.mapValues(\.timeIntervalSince1970), forKey: laterKey)
    }
    /// Drops entries for messages that are gone or no longer unread (read in Gmail, done, trashed).
    private func pruneLater() {
        let unread = Set(posts.filter(\.email.isUnread).map(\.id))
        let kept = LaterSchedule.pruned(laterUntil, keeping: unread)
        if kept.count != laterUntil.count { laterUntil = kept; saveLater() }
    }
    /// The last message put off, so a screen can offer Undo.
    private(set) var lastPutOff: (post: Post, until: Date)?
    func putOff(_ post: Post, until date: Date) {
        laterUntil[post.id] = date
        lastPutOff = (post, date)
        saveLater()
    }
    func bringBack(_ id: String) {
        guard laterUntil.removeValue(forKey: id) != nil else { return }
        saveLater()
    }
    func isPutOff(_ post: Post, now: Date = Date()) -> Bool {
        laterUntil[post.id].map { LaterSchedule.isPending($0, now: now) } ?? false
    }
    func isBackFromLater(_ post: Post, now: Date = Date()) -> Bool {
        laterUntil[post.id].map { !LaterSchedule.isPending($0, now: now) } ?? false
    }
    /// Messages put off and not back yet, soonest first.
    var laterPosts: [(post: Post, until: Date)] {
        let now = Date()
        return posts.compactMap { post in
            guard let until = laterUntil[post.id], LaterSchedule.isPending(until, now: now) else { return nil }
            return (post, until)
        }.sorted { $0.until < $1.until }
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func changeFailed(_ error: Error) {
        guard let e = error as? GmailService.GmailError else { return }
        switch e {
        case .needsTrashPermission: needsTrashPermission = true
        case .sessionExpired, .notSignedIn: needsReconnect = true
        default: break
        }
    }

    // MARK: Your other addresses

    /// Addresses you said are yours. Mail from them is "Notes to self". Saved on this phone, per account.
    var otherAddresses: [String] { rules.otherAddresses }
    enum AddAddressResult: Equatable { case added, pending, invalid, notSaved(String) }

    /// Adds another address of yours. Before the Gmail account is known (first load still running or failed),
    /// the address waits and is saved to that account's rules as soon as the account is known.
    @discardableResult
    func addOtherAddress(_ address: String) -> AddAddressResult {
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard LocalTriageRules.looksLikeAddress(key) else { return .invalid }
        guard mode == .sample || accountRules != nil else {
            pendingOtherAddresses.insert(key)
            return .pending
        }
        if let error = rules.persistenceError { return .notSaved(error) }
        return rules.setOtherAddress(key, true) ? .added : .notSaved("Lovely could not save that address on this phone.")
    }
    /// Addresses added before the account was known.
    private(set) var pendingOtherAddresses: Set<String> = []
    func removeOtherAddress(_ address: String) {
        guard mode == .sample || accountRules != nil else { return }
        rules.setOtherAddress(address, false)
    }

    // MARK: Local actions

    func hide(_ post: Post) { hidden.insert(post.id); persist() }
    func unhide(_ post: Post) { hidden.remove(post.id); persist() }
    func restoreAll() { hidden.removeAll(); persist() }
    /// Your correction: this message (or everything from this sender) is not waiting on you. Local only.
    func markNotWaiting(_ post: Post, wholeSender: Bool) {
        guard mode == .sample || accountRules != nil else { return }
        if wholeSender { rules.setNotWaiting(sender: post.email.from.email, true) }
        else { rules.setNotWaiting(messageID: post.id, true) }
    }
    func undoNotWaiting(_ post: Post) {
        guard mode == .sample || accountRules != nil else { return }
        rules.setNotWaiting(messageID: post.id, false)
        rules.setNotWaiting(sender: post.email.from.email, false)
    }
    func isMarkedNotWaiting(_ post: Post) -> Bool { rules.isNotWaiting(messageID: post.id, sender: post.email.from.email) }

    func setSenderRule(_ address: String, destination: LocalMailDestination?) {
        guard mode == .sample || accountRules != nil else { return }
        rules.setSender(address, destination: destination)
    }
    func setMessageRule(_ id: String, destination: LocalMailDestination?) {
        guard mode == .sample || accountRules != nil else { return }
        rules.setMessage(id, destination: destination)
    }

    /// Applies a rule made in chat or on a card. Recorded so it can be removed.
    @discardableResult
    func applyLearned(_ rule: LearnedRule, store: LearnedRuleStore = LearnedRuleStore()) -> Bool {
        guard mode == .sample || accountRules != nil, !rule.matches.isEmpty else { return false }
        for address in rule.matches { rules.setSender(address, destination: rule.action) }
        store.add(rule)
        return true
    }

    /// Takes back every rule made in chat. Senders return to the inbox.
    func removeChatRules(store: LearnedRuleStore = LearnedRuleStore()) {
        let made = store.chatRules
        for rule in made { for address in rule.matches { rules.setSender(address, destination: nil) } }
        store.remove(Set(made.map(\.id)))
    }
}
