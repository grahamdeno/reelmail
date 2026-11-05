import Foundation
import os

/// The only place Lovely writes to Gmail beyond Trash and Done: send, forward, filters and Lovely/ labels. Forwarding addresses are read, never changed.
/// Every change needs a ConfirmedAction from the preview sheet. scripts/privacy_guard.py enforces that these endpoints
/// appear in this file only, and that each changing function takes a ConfirmedAction.
struct GmailActions {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let api = "https://gmail.googleapis.com/gmail/v1/users/me"

    var token: () async throws -> String
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var allowlist = ForwardAllowlist()
    var filters = FilterRegistry()
    var labels = LovelyLabels()
    var activity = ActivityLog()
    private let log = Logger(subsystem: "com.grahamdeno.reelmail", category: "actions")

    init(token: @escaping () async throws -> String, transport: Transport? = nil, allowlist: ForwardAllowlist = ForwardAllowlist(),
         filters: FilterRegistry = FilterRegistry(), labels: LovelyLabels = LovelyLabels(), activity: ActivityLog = ActivityLog()) {
        self.token = token
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
        self.allowlist = allowlist; self.filters = filters; self.labels = labels; self.activity = activity
    }

    // MARK: Labels (Lovely/ only)

    /// The id of a Lovely/ label, creating the label the first time.
    func ensureLabel(_ name: String, confirmed: ConfirmedAction) async throws -> String {
        guard name.hasPrefix(LovelyLabels.prefix), name.count > LovelyLabels.prefix.count else { throw ActionError.notALovelyLabel(name) }
        try confirmed.require([.label, .filter, .shoebox])
        if let known = labels.id(for: name) { return known }
        let list: LabelList = try await call("GET", "/labels")
        if let found = list.labels?.first(where: { $0.name == name }) { labels.record(name: name, id: found.id); return found.id }
        let created: LabelItem = try await call("POST", "/labels", json: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
        labels.record(name: name, id: created.id)
        activity.record(kind: "label", summary: "Created label \(name)")
        return created.id
    }

    /// Files one message under a Lovely/ label, and optionally takes it out of the inbox.
    func file(messageID: String, labelID: String, removeFromInbox: Bool, confirmed: ConfirmedAction) async throws {
        try confirmed.require([.label])
        guard labels.isLovely(id: labelID) else { throw ActionError.notALovelyLabel(labelID) }
        var body: [String: Any] = ["addLabelIds": [labelID]]
        if removeFromInbox { body["removeLabelIds"] = ["INBOX"] }
        let _: Empty = try await call("POST", "/messages/\(encode(messageID))/modify", json: body)
        activity.record(kind: "label", summary: "Filed a message under a Lovely label" + (removeFromInbox ? " and out of the inbox" : ""))
    }

    // MARK: Filters (Lovely-created only)

    /// A filter for one sender that labels and/or forwards. Forwarding goes only to an address in the allowlist.
    func createFilter(sender: String, forwardTo: String?, labelID: String?, confirmed: ConfirmedAction) async throws -> RecordedFilter {
        try confirmed.require([.filter, .shoebox])
        guard ForwardAllowlist.isAddress(sender) else { throw ActionError.badAddress(sender) }
        var action: [String: Any] = [:]
        if let forwardTo {
            try confirmed.requireRecipient(forwardTo)
            guard allowlist.contains(forwardTo) else { throw ActionError.recipientNotAllowed(forwardTo) }
            action["forward"] = forwardTo.lowercased()
        }
        if let labelID {
            guard labels.isLovely(id: labelID) else { throw ActionError.notALovelyLabel(labelID) }
            action["addLabelIds"] = [labelID]
        }
        guard !action.isEmpty else { throw ActionError.wrongPreview }
        let from = sender.lowercased()
        let made: FilterItem = try await call("POST", "/settings/filters", json: ["criteria": ["from": from], "action": action])
        let record = RecordedFilter(gmailID: made.id, sender: from, forwardTo: forwardTo?.lowercased(), label: labelID, created: Date())
        filters.add(record)
        activity.record(kind: "filter", summary: "Created a filter for \(from)" + (forwardTo != nil ? " that forwards to \(forwardTo!.lowercased())" : ""))
        return record
    }

    /// Deletes a filter, only if Lovely made it.
    func deleteFilter(id: String, confirmed: ConfirmedAction) async throws {
        try confirmed.require([.deleteFilter])
        guard filters.contains(id) else { throw ActionError.notALovelyFilter(id) }
        let _: Empty = try await call("DELETE", "/settings/filters/\(encode(id))")
        filters.remove(id)
        activity.record(kind: "filter", summary: "Deleted a filter Lovely made")
    }

    // MARK: Forwarding addresses (read-only)

    /// What Gmail says about each forwarding address. Read-only: personal Gmail accounts can add forwarding addresses
    /// only in Gmail's own Settings (the API's create call is limited to Workspace service accounts), so Lovely never tries.
    func forwardingStatus() async throws -> [ForwardingStatus.Entry] {
        let list: ForwardingList = try await call("GET", "/settings/forwardingAddresses")
        return (list.forwardingAddresses ?? []).map { ForwardingStatus.Entry(email: $0.forwardingEmail, verification: $0.verificationStatus ?? "") }
    }

    // MARK: Sending

    /// Sends a reply the owner wrote and approved.
    func sendReply(to: String, subject: String, body: String, threadID: String?, inReplyTo: String?, confirmed: ConfirmedAction) async throws {
        try confirmed.require([.send])
        try confirmed.requireRecipient(to)
        try await deliver(MimeBuilder.message(to: to, subject: subject, body: body, inReplyTo: inReplyTo), threadID: threadID)
        activity.record(kind: "send", summary: "Sent a reply to \(to.lowercased())")
    }

    /// Forwards one message as plain text, only to an allowlisted address that was on the approved preview.
    func forward(from: String, subject: String, date: Date, text: String, to: String, confirmed: ConfirmedAction) async throws {
        try confirmed.require([.forward, .shoebox])
        try confirmed.requireRecipient(to)
        guard allowlist.contains(to) else { throw ActionError.recipientNotAllowed(to) }
        let body = MimeBuilder.forwardBody(from: from, subject: subject, date: date, text: text)
        try await deliver(MimeBuilder.message(to: to, subject: "Fwd: " + subject, body: body), threadID: nil)
        activity.record(kind: "forward", summary: "Forwarded a message from \(InsightText.domain(of: from)) to \(to.lowercased())")
    }

    private func deliver(_ mime: String, threadID: String?) async throws {
        var body: [String: Any] = ["raw": MimeBuilder.base64URL(mime)]
        if let threadID { body["threadId"] = threadID }
        let _: Empty = try await call("POST", "/messages/send", json: body)
    }

    // MARK: Transport

    private struct Empty: Decodable { init(from decoder: Decoder) throws {} }
    private struct LabelItem: Decodable { let id: String; let name: String? }
    private struct LabelList: Decodable { let labels: [LabelItem]? }
    private struct FilterItem: Decodable { let id: String }
    private struct ForwardingItem: Decodable { let forwardingEmail: String; let verificationStatus: String? }
    private struct ForwardingList: Decodable { let forwardingAddresses: [ForwardingItem]? }

    private func encode(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id }

    func request(_ method: String, _ path: String, json: [String: Any]? = nil, bearer: String) throws -> URLRequest {
        guard let url = URL(string: Self.api + path) else { throw GmailService.GmailError.badCallback }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func call<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> T {
        let r = try request(method, path, json: json, bearer: try await token())
        let (data, response) = try await transport(r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = GmailAPIError.parse(data)
            log.error("Gmail action failed with HTTP \(code, privacy: .public) \(detail?.reason ?? "", privacy: .public)")
            if code == 401 { throw GmailService.GmailError.sessionExpired }
            if code == 403, detail?.isMissingScope ?? true { throw GmailService.GmailError.needsActionPermission }
            if let detail { throw GmailService.GmailError.refused(code, detail) }
            throw GmailService.GmailError.http(code)
        }
        if data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
