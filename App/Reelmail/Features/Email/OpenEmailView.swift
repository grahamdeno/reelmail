import SwiftUI

/// One email: who it's from, what it is, why it's here, then the email itself with tappable links.
/// Actions sit in a bar at the bottom; rarer ones are in the "…" menu.
struct OpenEmailView: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    let postID: String
    @State private var unsubscribePreview: ActionPreview?
    @State private var unsubscribeURL: URL?
    @State private var handoffPost: Post?
    @State private var shoeboxPreview: ActionPreview?

    var body: some View {
        if let post = store.posts.first(where: { $0.id == postID }) {
            let email = post.email
            let assessment = store.assessment(for: post)
            let organization = store.isAutomated(post)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EmailHeader(post: post, organization: organization)
                    EmailContext(post: post, assessment: assessment)
                    EmailDateRow(post: post)
                    if EmailPresentation.showsSummary(email), !ConversationPresentation.isSensitive(email, summary: post.summary) {
                        (Text("In short: ").fontWeight(.semibold) + Text(post.summary.blurb))
                            .font(.subheadline).foregroundStyle(CalmStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(CalmStyle.divider)
                    if email.body.isEmpty {
                        Text("No readable text was imported. Open it in Gmail to see it.")
                            .font(.body).foregroundStyle(CalmStyle.secondary)
                    } else {
                        Text(EmailPresentation.linked(email.body))
                            .font(.body).tint(CalmStyle.blue)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
            .safeAreaInset(edge: .bottom) {
                actionBar(post, assessment: assessment, organization: organization)
            }
            .navigationTitle(organization ? HomeDigest.organizationName(email.from) : email.from.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $handoffPost) { HandoffSheet(post: $0) }
            .sheet(item: $shoeboxPreview) { p in
                ActionPreviewSheet(preview: p, confirmTitle: "Send") { confirmed in
                    if let shoebox = p.recipients.first { store.sendToShoebox(messageID: post.id, shoebox: shoebox, confirmed: confirmed) }
                }
            }
            .sheet(item: $unsubscribePreview) { p in
                ActionPreviewSheet(preview: p, confirmTitle: "Unsubscribe") { _ in if let url = unsubscribeURL { Task { await store.unsubscribe(url: url, sender: email.from.name) } } }
            }
        } else {
            ContentUnavailableView("Email not found", systemImage: "envelope").background(CalmStyle.background)
        }
    }

    /// Reply, Done and Trash where your thumb is. Everything else in "…".
    private func actionBar(_ post: Post, assessment: TriageAssessment, organization: Bool) -> some View {
        HStack(spacing: 8) {
            if !organization {
                Button { router.draftPostID = post.id } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .buttonStyle(CalmActionStyle(prominent: true)).lineLimit(1)
            }
            if post.email.isUnread {
                Button { Task { await store.markDone(post) }; leave() } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(CalmActionStyle(prominent: organization)).lineLimit(1)
                    .accessibilityHint("Takes it off your to-do and marks it read in Gmail")
            }
            if organization, !post.email.isUnread {
                Button { openInGmail(post.email) } label: { Label("Open in Gmail", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(CalmActionStyle()).lineLimit(1)
            }
            if post.email.isUnread {
                LaterMenu(post: post, onPut: { leave() }) {
                    Image(systemName: "clock").font(.body.weight(.medium)).foregroundStyle(CalmStyle.blue).frame(width: 44, height: 44)
                }
            }
            Spacer(minLength: 0)
            Button { Task { await store.moveToTrash(post) }; leave() } label: {
                Image(systemName: "trash").font(.body.weight(.medium)).foregroundStyle(CalmStyle.roseInk)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Move to Gmail Trash")
            Menu {
                Button { openInGmail(post.email) } label: { Label("Open in Gmail", systemImage: "arrow.up.forward.app") }
                if let shoebox = ShoeboxRule.address(),
                   ShoeboxRule.offersSend(shoebox: shoebox, allowlist: ForwardAllowlist(), connected: store.actions != nil && store.mode == .gmail,
                                          fromAddress: post.email.from.email, fromName: post.email.from.name, subject: post.email.subject) {
                    Button { shoeboxPreview = ShoeboxRule.sendPreview(messageID: post.id, fromName: post.email.from.name, subject: post.email.subject, shoebox: shoebox) } label: {
                        Label("Send to Shoebox", systemImage: "tray.and.arrow.down")
                    }
                }
                if HandoffPrompt.isAllowed(address: post.email.from.email, name: post.email.from.name, subject: post.email.subject, sensitive: post.summary.sensitive) {
                    Button { handoffPost = post } label: { Label("Hand off to an agent", systemImage: "square.and.arrow.up.on.square") }
                }
                if post.email.bulk, store.mode == .gmail {
                    Button { Task { await prepareUnsubscribe(post) } } label: { Label("Unsubscribe", systemImage: "hand.raised") }
                }
                if ReplyRecipients.offersReplyAll(post.email, mine: Set([store.account ?? ""] + store.otherAddresses).subtracting([""]), organization: organization) {
                    Button { router.draftReplyAll = true; router.draftPostID = post.id } label: {
                        Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                    }
                }
                if !organization {
                    Button { router.open(.thread(post.email.from)) } label: {
                        Label("Conversation with \(post.email.from.firstName)", systemImage: "bubble.left")
                    }
                }
                Section {
                    if assessment.section == .waiting {
                        Button { store.markNotWaiting(post, wholeSender: true) } label: {
                            Label("Never put \(post.email.from.firstName) in Waiting", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    } else if store.isMarkedNotWaiting(post) {
                        Button { store.undoNotWaiting(post) } label: { Label("Put back in Waiting", systemImage: "arrow.uturn.backward") }
                    }
                    Button { store.setSenderRule(post.email.from.email, destination: .reading) } label: { Label("Move sender to Reading", systemImage: "newspaper") }
                    Button { store.setSenderRule(post.email.from.email, destination: .filtered) } label: { Label("Filter this sender", systemImage: "line.3.horizontal.decrease.circle") }
                }
                Section {
                    Button { store.hide(post); leave() } label: { Label("Hide in Lovely", systemImage: "eye.slash") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(CalmStyle.blue)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(CalmStyle.background)
        .overlay(alignment: .top) { Rectangle().fill(CalmStyle.divider).frame(height: 1) }
    }

    private func leave() { if !router.path.isEmpty { router.path.removeLast() } }

    private func openInGmail(_ email: Email) {
        // Reply context only; nothing is sent. The user presses Send in Gmail.
        let subject = GmailCompose.replySubject(email.subject)
        guard let app = GmailCompose.appURL(to: email.from.email, subject: subject, body: "") else { return }
        openURL(app) { ok in
            if !ok, let web = GmailCompose.webURL(to: email.from.email, subject: subject, body: "") { openURL(web) }
        }
    }

    /// Reads the sender's own unsubscribe header. Offers it only when the sender supports one-click and it is safe to.
    private func prepareUnsubscribe(_ post: Post) async {
        guard let stub = try? await store.gmail.getMetadata(id: post.id),
              let url = OneClickUnsubscribe.target(listUnsubscribe: stub.listUnsubscribe, post: stub.listUnsubscribePost,
                                                   senderAddress: stub.fromAddress, subject: stub.subject) else {
            store.errorMessage = "This sender does not offer a one-click unsubscribe Lovely can use safely. Open it in Gmail instead."
            return
        }
        unsubscribeURL = url
        unsubscribePreview = OneClickUnsubscribe.preview(host: url.host ?? "the sender", sender: post.email.from.name)
    }
}

/// Sender (tap for the conversation), subject, date, and recipients when anyone besides you is on it.
struct EmailHeader: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router
    let post: Post
    let organization: Bool
    private var email: Email { post.email }
    private var mine: Set<String> { Set([store.account ?? ""] + store.otherAddresses).subtracting([""]) }

    private var senderRow: some View {
        HStack(spacing: 12) {
            CalmAvatar(person: email.from, size: 40, organization: organization)
            VStack(alignment: .leading, spacing: 1) {
                Text(organization ? HomeDigest.organizationName(email.from) : email.from.name)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(email.from.email).font(.caption).foregroundStyle(CalmStyle.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if !organization {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if organization {
                senderRow
            } else {
                Button { router.open(.thread(email.from)) } label: { senderRow }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows your conversation")
            }

            Text(email.subject.isEmpty ? "(no subject)" : email.subject)
                .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(EmailPresentation.dateLine(email.date, now: Date()))
                .font(.caption).foregroundStyle(CalmStyle.secondary)
            if EmailPresentation.showsRecipients(email, mine: mine) {
                VStack(alignment: .leading, spacing: 4) {
                    HeaderLine(key: "To", value: email.to.joined(separator: ", "))
                    if !email.cc.isEmpty { HeaderLine(key: "Cc", value: email.cc.joined(separator: ", ")) }
                }
            }
        }
    }
}

/// Why it's here, in one line, with the one correction that matters.
struct EmailContext: View {
    @Environment(FeedStore.self) private var store
    let post: Post
    let assessment: TriageAssessment
    /// A display name is never proof of identity, so a match only prompts a question; you decide.
    private var looksLikeYou: Bool {
        let mine = store.me.name.lowercased()
        return mine.count > 3 && mine != "you" && post.email.from.name.lowercased() == mine
            && post.email.from.email.lowercased() != store.account?.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assessment.section == .waiting {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(CalmStyle.rose).frame(width: 8, height: 8).accessibilityHidden(true)
                    Group {
                        if let ask = assessment.ask {
                            Text("Waiting on you: ").fontWeight(.semibold) + Text(ask)
                        } else {
                            Text("Waiting on you. ").fontWeight(.semibold) + Text(assessment.reason)
                        }
                    }
                    .font(.subheadline).foregroundStyle(CalmStyle.roseInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Not waiting") { store.markNotWaiting(post, wholeSender: false) }
                        .font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.blue)
                        .frame(minHeight: 44).fixedSize()
                }
                .padding(.horizontal, 12)
                .background(CalmStyle.rose.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 8) {
                    Text(assessment.section.title + " · " + assessment.reason)
                        .font(.caption).foregroundStyle(CalmStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.isMarkedNotWaiting(post) {
                        Spacer(minLength: 4)
                        Button("Put back in Waiting") { store.undoNotWaiting(post) }
                            .font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.blue).frame(minHeight: 44).fixedSize()
                    }
                }
            }
            if assessment.section == .notes, store.otherAddresses.contains(post.email.from.email.lowercased()) {
                Button("This isn't my address") { store.removeOtherAddress(post.email.from.email) }
                    .font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.blue).frame(minHeight: 44)
            } else if looksLikeYou {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This name matches yours. Is it another address of yours?").font(.caption).foregroundStyle(CalmStyle.secondary)
                    Button("Yes, \(post.email.from.email) is mine") { store.addOtherAddress(post.email.from.email) }
                        .buttonStyle(CalmActionStyle()).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HeaderLine: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(.caption).foregroundStyle(CalmStyle.secondary).frame(width: 36, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}
