import Foundation
import Observation

// Everything that guards Gmail changes beyond reading, Trash and Done (approved 2026-11-04, Sprint 6).
// Every send, forward and filter action needs a ConfirmedAction, which only the preview sheet makes.

/// What the owner is asked to approve. Plain words, no mail bodies.
struct ActionPreview: Identifiable, Equatable {
    enum Kind: String, Codable, Hashable {
        case send, forward, filter, deleteFilter, label, trashScreened, shoebox, unsubscribe
    }
    let id: String
    let kind: Kind
    let title: String
    /// What will happen, one short line each.
    let lines: [String]
    /// Everyone who will receive anything. Empty for labels, filters that only label, and Trash.
    let recipients: [String]

    init(id: String = UUID().uuidString, kind: Kind, title: String, lines: [String], recipients: [String] = []) {
        self.id = id; self.kind = kind; self.title = title; self.lines = lines; self.recipients = recipients.map { $0.lowercased() }
    }
}

/// Proof that the owner tapped Confirm on a preview. Made only by ActionPreviewSheet (CI checks this).
struct ConfirmedAction: Equatable {
    let preview: ActionPreview
    let confirmedAt: Date

    init(preview: ActionPreview, confirmedAt: Date = Date()) {
        self.preview = preview; self.confirmedAt = confirmedAt
    }

    /// An approval covers what its preview said, for a short time. The Shoebox backfill is the longest use (one filter, up to 50 forwards).
    static let lifetime: TimeInterval = 15 * 60

    /// Throws unless this approval is for one of `kinds` and is still fresh.
    func require(_ kinds: Set<ActionPreview.Kind>, now: Date = Date()) throws {
        guard kinds.contains(preview.kind) else { throw ActionError.wrongPreview }
        guard now.timeIntervalSince(confirmedAt) <= Self.lifetime, now >= confirmedAt.addingTimeInterval(-60) else { throw ActionError.expired }
    }

    /// Throws unless `address` is one plain address and was shown on the preview.
    func requireRecipient(_ address: String) throws {
        guard ForwardAllowlist.isAddress(address) else { throw ActionError.badAddress(address) }
        guard preview.recipients.contains(address.lowercased()) else { throw ActionError.recipientNotConfirmed(address) }
    }
}

enum ActionError: LocalizedError, Equatable {
    case wrongPreview
    case recipientNotConfirmed(String)
    case recipientNotAllowed(String)
    case notALovelyLabel(String)
    case notALovelyFilter(String)
    case badAddress(String)
    case expired

    var errorDescription: String? {
        switch self {
        case .wrongPreview: return "That approval was for a different action."
        case .recipientNotConfirmed: return "That address was not on the approved preview."
        case .recipientNotAllowed: return "That address is not in Settings, Forwarding addresses."
        case .notALovelyLabel: return "Lovely changes only labels it created, under Lovely/."
        case .notALovelyFilter: return "Lovely deletes only filters it created."
        case .badAddress: return "That does not look like an email address."
        case .expired: return "That approval has expired. Start again and confirm."
        }
    }
}

/// Where mail may be forwarded. Starts empty; the owner adds each address in Settings.
struct ForwardAllowlist {
    static let key = "lovely.forward.allowlist"
    var defaults: UserDefaults = .standard

    var addresses: [String] { (defaults.stringArray(forKey: Self.key) ?? []).sorted() }
    func contains(_ address: String) -> Bool { addresses.contains(address.lowercased()) }

    static func isAddress(_ s: String) -> Bool {
        s.range(of: #"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$"#, options: .regularExpression) != nil
    }

    @discardableResult
    func add(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.isAddress(a) else { return false }
        defaults.set(Array(Set(addresses + [a])), forKey: Self.key)
        SettingsSync.localChanged(defaults)
        return true
    }

    func remove(_ address: String) {
        defaults.set(addresses.filter { $0 != address.lowercased() }, forKey: Self.key)
        SettingsSync.localChanged(defaults)
    }
}

/// How Gmail lists an allowlisted address. Filters can forward only to addresses Gmail shows as verified.
enum ForwardingStatus: Equatable {
    case verified, pending, missing

    struct Entry: Equatable { let email: String; let verification: String }

    static func of(_ address: String, in entries: [Entry]) -> ForwardingStatus {
        guard let e = entries.first(where: { $0.email.lowercased() == address.lowercased() }) else { return .missing }
        return e.verification.lowercased() == "accepted" ? .verified : .pending
    }

    var label: String {
        switch self {
        case .verified: "Verified in Gmail"
        case .pending: "Pending in Gmail"
        case .missing: "Not in Gmail yet: add it in Gmail Settings > Forwarding and POP/IMAP"
        }
    }
}

/// A filter Lovely created in Gmail. Lovely deletes only these.
struct RecordedFilter: Codable, Equatable, Identifiable {
    var id: String { gmailID }
    var gmailID: String
    var sender: String
    var forwardTo: String?
    var label: String?
    var created: Date
}

struct FilterRegistry {
    static let key = "lovely.gmail.filters"
    var defaults: UserDefaults = .standard

    var filters: [RecordedFilter] {
        guard let d = defaults.data(forKey: Self.key), let f = try? JSONDecoder().decode([RecordedFilter].self, from: d) else { return [] }
        return f
    }
    func contains(_ id: String) -> Bool { filters.contains { $0.gmailID == id } }
    func add(_ f: RecordedFilter) { save(filters.filter { $0.gmailID != f.gmailID } + [f]) }
    func remove(_ id: String) { save(filters.filter { $0.gmailID != id }) }
    private func save(_ f: [RecordedFilter]) { if let d = try? JSONEncoder().encode(f) { defaults.set(d, forKey: Self.key) } }
}

/// Labels Lovely created, by Gmail id. Lovely changes only these.
struct LovelyLabels {
    static let key = "lovely.gmail.labels"
    static let prefix = "Lovely/"
    var defaults: UserDefaults = .standard

    var ids: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }
    func id(for name: String) -> String? { ids[name] }
    func isLovely(id: String) -> Bool { ids.values.contains(id) }
    func record(name: String, id: String) { var d = ids; d[name] = id; defaults.set(d, forKey: Self.key) }
}

/// What Lovely did in Gmail, newest last. Short summaries only; no mail bodies.
struct ActivityEntry: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var date: Date
    var kind: String
    var summary: String
}

struct ActivityLog {
    static let key = "lovely.gmail.activity"
    static let keep = 200
    var defaults: UserDefaults = .standard

    var entries: [ActivityEntry] {
        guard let d = defaults.data(forKey: Self.key), let e = try? JSONDecoder().decode([ActivityEntry].self, from: d) else { return [] }
        return e
    }

    func record(kind: String, summary: String, at date: Date = Date()) {
        let next = Array((entries + [ActivityEntry(date: date, kind: kind, summary: String(summary.prefix(160)))]).suffix(Self.keep))
        if let d = try? JSONEncoder().encode(next) { defaults.set(d, forKey: Self.key) }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// Holds a send or forward for a few seconds so it can be cancelled before the API call is made.
@MainActor
@Observable
final class UndoQueue {
    struct Pending: Identifiable, Equatable {
        let id: String
        let title: String
        let sendsAt: Date
    }

    private(set) var pending: [Pending] = []
    var delay: TimeInterval = 10
    var sleeper: @Sendable (TimeInterval) async -> Void = { delay in _ = try? await Task.sleep(for: .seconds(delay)) }
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Starts the countdown. `work` runs after the delay unless cancelled; `finished` gets the outcome.
    @discardableResult
    func enqueue(title: String, work: @escaping @MainActor () async throws -> Void, finished: @escaping @MainActor (Error?) -> Void = { _ in }) -> String {
        let id = UUID().uuidString
        pending.append(Pending(id: id, title: title, sendsAt: Date().addingTimeInterval(delay)))
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.sleeper(self.delay)
            guard !Task.isCancelled, self.pending.contains(where: { $0.id == id }) else { return }
            self.pending.removeAll { $0.id == id }
            self.tasks[id] = nil
            do { try await work(); finished(nil) } catch { finished(error) }
        }
        return id
    }

    /// Stops a held action. Returns false when it already went.
    @discardableResult
    func cancel(_ id: String) -> Bool {
        guard pending.contains(where: { $0.id == id }) else { return false }
        tasks[id]?.cancel(); tasks[id] = nil
        pending.removeAll { $0.id == id }
        return true
    }
}

/// Builds the plain-text message Gmail sends. Pure, so it is tested without a network.
enum MimeBuilder {
    /// Header values never carry line breaks, so mail content cannot add headers.
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func encodedSubject(_ subject: String) -> String {
        let s = clean(subject)
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }

    static func message(to: String, subject: String, body: String, inReplyTo: String? = nil) -> String {
        var lines = ["To: " + clean(to), "Subject: " + encodedSubject(subject), "MIME-Version: 1.0",
                     "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        if let inReplyTo, !clean(inReplyTo).isEmpty {
            lines.append("In-Reply-To: " + clean(inReplyTo)); lines.append("References: " + clean(inReplyTo))
        }
        let encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + encoded
    }

    static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// A forward: a short note, then the original as plain text. Attachments are not included.
    static func forwardBody(from: String, subject: String, date: Date, text: String) -> String {
        "---------- Forwarded by Lovely ----------\nFrom: \(clean(from))\nDate: \(date.formatted(date: .abbreviated, time: .shortened))\nSubject: \(clean(subject))\n\n\(text)"
    }
}
