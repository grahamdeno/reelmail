import XCTest
@testable import Reelmail

@MainActor
final class GmailActionsTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "actions-\(UUID().uuidString)")! }

    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var reply: String = "{}"
        var status = 200
    }

    private func make(_ d: UserDefaults, recorder: Recorder) -> GmailActions {
        GmailActions(token: { "tok" },
                     transport: { request in
                         recorder.requests.append(request)
                         let response = HTTPURLResponse(url: request.url!, statusCode: recorder.status, httpVersion: nil, headerFields: nil)!
                         return (Data(recorder.reply.utf8), response)
                     },
                     allowlist: ForwardAllowlist(defaults: d), filters: FilterRegistry(defaults: d),
                     labels: LovelyLabels(defaults: d), activity: ActivityLog(defaults: d))
    }

    private func confirmed(_ kind: ActionPreview.Kind, to: [String] = []) -> ConfirmedAction {
        ConfirmedAction(preview: ActionPreview(kind: kind, title: "t", lines: [], recipients: to))
    }

    func testForwardRefusedWhenAddressNotAllowlisted() async {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        do {
            try await a.forward(from: "x@example.com", subject: "s", date: Date(), text: "t", to: "evil@example.com", confirmed: confirmed(.forward, to: ["evil@example.com"]))
            XCTFail("should refuse")
        } catch { XCTAssertEqual(error as? ActionError, .recipientNotAllowed("evil@example.com")) }
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testForwardRefusedWhenAddressNotOnApprovedPreview() async {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        a.allowlist.add("box@example.com")
        do {
            try await a.forward(from: "x@example.com", subject: "s", date: Date(), text: "t", to: "box@example.com", confirmed: confirmed(.forward, to: ["other@example.com"]))
            XCTFail("should refuse")
        } catch { XCTAssertEqual(error as? ActionError, .recipientNotConfirmed("box@example.com")) }
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testApprovalForOneKindCannotRunAnother() async {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        do {
            try await a.sendReply(to: "a@example.com", subject: "s", body: "b", threadID: nil, inReplyTo: nil, confirmed: confirmed(.forward, to: ["a@example.com"]))
            XCTFail("should refuse")
        } catch { XCTAssertEqual(error as? ActionError, .wrongPreview) }
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testAllowedForwardSendsOneMessageAndLogsIt() async throws {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        a.allowlist.add("box@example.com")
        try await a.forward(from: "Sender <x@example.com>", subject: "Hello", date: Date(), text: "Body", to: "box@example.com", confirmed: confirmed(.forward, to: ["box@example.com"]))
        XCTAssertEqual(rec.requests.count, 1)
        XCTAssertEqual(rec.requests[0].url?.path, "/gmail/v1/users/me/messages/send")
        XCTAssertEqual(rec.requests[0].httpMethod, "POST")
        XCTAssertEqual(a.activity.entries.count, 1)
    }

    func testLabelsMustLiveUnderLovelyPrefix() async {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        do { _ = try await a.ensureLabel("Work", confirmed: confirmed(.label)); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? ActionError, .notALovelyLabel("Work")) }
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testFilingUsesOnlyLovelyLabelIDsAndInbox() async throws {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        do { try await a.file(messageID: "m1", labelID: "STARRED", removeFromInbox: false, confirmed: confirmed(.label)); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? ActionError, .notALovelyLabel("STARRED")) }
        a.labels.record(name: "Lovely/Screened Out", id: "Label_9")
        try await a.file(messageID: "m1", labelID: "Label_9", removeFromInbox: true, confirmed: confirmed(.label))
        let body = String(data: rec.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("Label_9"))
        XCTAssertTrue(body.contains("INBOX"))
        XCTAssertFalse(body.contains("TRASH"))
    }

    func testOnlyLovelyFiltersCanBeDeleted() async throws {
        let d = defaults(); let rec = Recorder(); let a = make(d, recorder: rec)
        do { try await a.deleteFilter(id: "someoneElses", confirmed: confirmed(.deleteFilter)); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? ActionError, .notALovelyFilter("someoneElses")) }
        a.filters.add(RecordedFilter(gmailID: "f1", sender: "x@example.com", forwardTo: nil, label: nil, created: Date()))
        try await a.deleteFilter(id: "f1", confirmed: confirmed(.deleteFilter))
        XCTAssertEqual(rec.requests.last?.httpMethod, "DELETE")
        XCTAssertTrue(a.filters.filters.isEmpty)
    }

    func testMissingScopeSaysReconnect() async {
        let d = defaults(); let rec = Recorder(); rec.status = 403
        rec.reply = #"{"error":{"code":403,"message":"Insufficient Permission","errors":[{"reason":"insufficientPermissions"}]}}"#
        let a = make(d, recorder: rec)
        a.allowlist.add("box@example.com")
        do { _ = try await a.createFilter(sender: "news@example.com", forwardTo: "box@example.com", labelID: nil, confirmed: confirmed(.filter, to: ["box@example.com"])); XCTFail("should throw") }
        catch {
            guard case GmailService.GmailError.needsActionPermission = error else { return XCTFail("expected needsActionPermission, got \(error)") }
            XCTAssertTrue((error as? GmailService.GmailError)?.needsReconnect ?? false)
        }
    }

    func testForwardingStatusIsReadOnlyGet() async throws {
        let d = defaults(); let rec = Recorder()
        rec.reply = #"{"forwardingAddresses":[{"forwardingEmail":"Box@Example.com","verificationStatus":"accepted"},{"forwardingEmail":"wait@example.org","verificationStatus":"pending"}]}"#
        let a = make(d, recorder: rec)
        let entries = try await a.forwardingStatus()
        XCTAssertEqual(rec.requests.count, 1)
        XCTAssertEqual(rec.requests[0].httpMethod, "GET")
        XCTAssertNil(rec.requests[0].httpBody)
        XCTAssertTrue(rec.requests[0].url!.absoluteString.hasSuffix("/settings/forwardingAddresses"))
        XCTAssertEqual(ForwardingStatus.of("box@example.com", in: entries), .verified)
        XCTAssertEqual(ForwardingStatus.of("wait@example.org", in: entries), .pending)
        XCTAssertEqual(ForwardingStatus.of("other@example.net", in: entries), .missing)
        XCTAssertTrue(ForwardingStatus.missing.label.contains("Forwarding and POP/IMAP"))
    }

    func testForwardingStatusHandlesEmptyList() async throws {
        let d = defaults(); let rec = Recorder(); rec.reply = "{}"
        let entries = try await make(d, recorder: rec).forwardingStatus()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(ForwardingStatus.of("box@example.com", in: entries), .missing)
    }

    func testMimeNeverAllowsHeaderInjection() {
        let mime = MimeBuilder.message(to: "a@example.com\r\nBcc: spy@example.com", subject: "Hi\r\nBcc: spy@example.com", body: "x")
        XCTAssertFalse(mime.contains("\r\nBcc:"))
        XCTAssertTrue(MimeBuilder.encodedSubject("Café").hasPrefix("=?UTF-8?B?"))
        XCTAssertFalse(MimeBuilder.base64URL("????>>>>").contains("+"))
    }

    func testAllowlistValidation() {
        let d = defaults()
        let list = ForwardAllowlist(defaults: d)
        XCTAssertFalse(list.add("not an address"))
        XCTAssertFalse(list.add("a@b"))
        XCTAssertTrue(list.add("Box@Example.com"))
        XCTAssertTrue(list.contains("box@example.com"))
    }

    func testUndoQueueCancelsBeforeSending() async {
        let q = UndoQueue(); q.delay = 0.2
        var ran = false
        let id = q.enqueue(title: "t") { ran = true }
        XCTAssertTrue(q.cancel(id))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(ran)
        let id2 = q.enqueue(title: "t2") { ran = true }
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(ran)
        XCTAssertFalse(q.cancel(id2), "already went")
    }
}
