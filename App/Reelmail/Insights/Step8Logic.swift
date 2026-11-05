import Foundation

// Step 8 rules. Pure, so they are tested without a phone or a network.

/// Kids to Shoebox: a standing Gmail filter for one sender plus a forward of its last 10 days of mail.
enum ShoeboxRule {
    static let backfillDays = 10
    static let maxBackfill = 50
    static let key = "lovely.shoebox.address"

    static func address(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key).flatMap { ForwardAllowlist.isAddress($0) ? $0 : nil }
    }

    static func setAddress(_ value: String?, defaults: UserDefaults = .standard) {
        if let value, ForwardAllowlist.isAddress(value) { defaults.set(value.lowercased(), forKey: key) } else { defaults.removeObject(forKey: key) }
        SettingsSync.localChanged(defaults)
    }

    /// The Gmail search for the last 10 days of one sender's mail. The sender is quoted so it cannot add search terms.
    /// "Send to Shoebox" shows on an email when a Shoebox address is set and allowed, Gmail is connected, and it isn't health mail.
    static func offersSend(shoebox: String?, allowlist: ForwardAllowlist, connected: Bool, fromAddress: String, fromName: String, subject: String) -> Bool {
        guard connected, let shoebox, allowlist.contains(shoebox) else { return false }
        return !HealthMail.isHealth(address: fromAddress, name: fromName, subject: subject)
    }

    /// The preview for forwarding one message to Shoebox.
    static func sendPreview(messageID: String, fromName: String, subject: String, shoebox: String) -> ActionPreview {
        ActionPreview(id: "shoebox-" + messageID, kind: .forward, title: "Send to Shoebox",
                      lines: ["Forwards this one email as plain text.", "From: \(fromName)", "Subject: \(subject)", "You have 10 seconds to undo."],
                      recipients: [shoebox])
    }

    static func backfillQuery(sender: String) -> String {
        let safe = sender.filter { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" }
        return "from:\(safe) newer_than:\(backfillDays)d"
    }

    static func preview(sender: String, shoebox: String, count: Int) -> ActionPreview {
        ActionPreview(kind: .shoebox, title: "Send this sender to Shoebox",
                      lines: ["Creates a Gmail filter: mail from \(sender) is forwarded to Shoebox from now on.",
                              count == 0 ? "No mail from this sender in the last \(backfillDays) days." : "Forwards the \(count) message\(count == 1 ? "" : "s") from the last \(backfillDays) days now.",
                              "You can delete the filter in Settings, Gmail filters."],
                      recipients: [shoebox])
    }
}

/// First-time senders. A sender is "known" once you wrote to them, accepted them, or they were already in your mail history.
enum ScreenedOut {
    static let approvedKey = "lovely.screened.approved"
    static let label = "Lovely/Screened Out"
    static let trashAfterDays = 30

    struct Candidate: Equatable, Identifiable {
        var id: String { address }
        var address: String
        var name: String
        var messageIDs: [String]
        var subject: String
    }

    static let checkedKey = "lovely.screened.checked"

    static func approved(defaults: UserDefaults = .standard) -> Set<String> { Set(defaults.stringArray(forKey: approvedKey) ?? []) }

    /// Senders already looked up in Gmail: true when they have no older mail and you never wrote to them.
    /// Only the 120 newest inbox messages are loaded, so a sender can look new on the phone without being new.
    static func checked(defaults: UserDefaults = .standard) -> [String: Bool] { defaults.dictionary(forKey: checkedKey) as? [String: Bool] ?? [:] }
    static func record(_ address: String, isNew: Bool, defaults: UserDefaults = .standard) {
        var d = checked(defaults: defaults); d[address.lowercased()] = isNew; defaults.set(d, forKey: checkedKey)
    }

    /// Older mail from them, or any mail to them. The address is stripped so it cannot add search terms.
    static func historyQuery(_ address: String) -> String {
        let safe = address.filter { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" && $0 != "{" && $0 != "}" }
        return "(from:\(safe) older_than:\(windowDays)d) OR to:\(safe)"
    }
    static let windowDays = 14
    static func approve(_ address: String, defaults: UserDefaults = .standard) {
        defaults.set(Array(approved(defaults: defaults).union([address.lowercased()])), forKey: approvedKey)
    }

    /// Senders in the loaded inbox that you have never written to, have not accepted, and that are not already part of an
    /// older thread (their first message in this mailbox is within `windowDays`). Newest first.
    /// With `checked`, only senders Gmail confirmed as new are returned; unchecked senders wait for the lookup.
    static func candidates(inbox: [Email], sent: [Email], approved: Set<String>, mine: Set<String>, now: Date, windowDays: Int = 14,
                           checked: [String: Bool]? = nil) -> [Candidate] {
        let written = Set(sent.flatMap { $0.to.map { EmailPresentation.address(in: $0).lowercased() } })
        var bySender: [String: [Email]] = [:]
        for e in inbox where !e.isFromMe { bySender[e.from.email.lowercased(), default: []].append(e) }
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return bySender.compactMap { address, mail -> Candidate? in
            guard !address.isEmpty, !mine.contains(address), !written.contains(address), !approved.contains(address) else { return nil }
            if let checked, checked[address] != true { return nil }
            guard let oldest = mail.map(\.date).min(), oldest >= cutoff else { return nil }
            let newest = mail.max { $0.date < $1.date }!
            return Candidate(address: address, name: newest.from.name, messageIDs: mail.map(\.id), subject: newest.subject)
        }.sorted { $0.address < $1.address }
    }

    static func declinePreview(_ c: Candidate) -> ActionPreview {
        ActionPreview(kind: .label, title: "Decline \(c.name)",
                      lines: ["Moves \(c.messageIDs.count) message\(c.messageIDs.count == 1 ? "" : "s") from \(c.address) out of your inbox into the Gmail label \(label).",
                              "Nothing is deleted. After \(trashAfterDays) days Lovely offers to move them to Trash."])
    }

    static let trashQuery = "label:lovely-screened-out older_than:\(trashAfterDays)d"
}

/// RFC 8058 one-click unsubscribe. A plain HTTPS POST to the address in the mail's own header; no Gmail scope.
enum OneClickUnsubscribe {
    /// Senders whose mail is about your accounts, security or health are never offered an unsubscribe.
    static func isProtected(domain: String, subject: String) -> Bool {
        let d = InsightText.registrable(domain)
        if InsightParsers.financialDomains.keys.contains(where: { d.hasSuffix($0) }) { return true }
        if HealthMail.isHealth(domain: domain, subject: subject) { return true }
        return Rx.test("security|password|verification|sign-in|login|receipt|invoice|statement|order|payment|account", in: subject)
    }

    /// The HTTPS address to POST to, only when the sender advertises one-click and the address belongs to the sender's own company.
    static func target(listUnsubscribe: String?, post: String?, senderAddress: String, subject: String) -> URL? {
        guard let listUnsubscribe, let post, post.lowercased().contains("list-unsubscribe=one-click") else { return nil }
        let domain = InsightText.domain(of: senderAddress)
        guard !isProtected(domain: domain, subject: subject) else { return nil }
        for g in Rx.all(#"<(https://[^>\s]+)>"#, in: listUnsubscribe) {
            guard let url = URL(string: g[1]), url.scheme == "https", let host = url.host?.lowercased() else { continue }
            // Mail cannot point an unsubscribe at another company; sending platforms are checked by the owner in the preview.
            if InsightText.registrable(host) == InsightText.registrable(domain) { return url }
        }
        return nil
    }

    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        r.timeoutInterval = 20
        return r
    }

    static func preview(host: String, sender: String) -> ActionPreview {
        ActionPreview(kind: .unsubscribe, title: "Unsubscribe from \(sender)",
                      lines: ["Lovely sends one request to \(host), the way your mail app's Unsubscribe button does.",
                              "It sends no email and shares nothing about you."])
    }
}
