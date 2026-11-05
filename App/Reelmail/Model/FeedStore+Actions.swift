import Foundation

/// The flows behind the preview sheets. Each one is called only with a ConfirmedAction (or, for Trash, after a preview tap).
extension FeedStore {
    /// One request to the sender's own unsubscribe address (RFC 8058). Sends no email.
    func unsubscribe(url: URL, sender: String) async {
        do {
            let (_, response) = try await URLSession.shared.data(for: OneClickUnsubscribe.request(url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                ActivityLog().record(kind: "unsubscribe", summary: "Unsubscribed from \(sender) at \(url.host ?? "its own address")")
                errorMessage = "Unsubscribe sent to \(sender)."
            } else { errorMessage = "\(sender) did not accept the unsubscribe (HTTP \(code))." }
        } catch { errorMessage = "The unsubscribe could not be sent. \(error.localizedDescription)" }
    }

    /// The messages the Shoebox backfill would forward for a sender. The preview shows this count and the run forwards exactly these.
    func shoeboxBackfillIDs(sender: String) async -> [String] {
        (try? await gmail.listMessageIDs(query: ShoeboxRule.backfillQuery(sender: sender), limit: ShoeboxRule.maxBackfill).ids) ?? []
    }

    /// A standing filter that forwards one sender to Shoebox, then a forward of the messages shown on the preview. Held 10 seconds for Undo.
    /// The Shoebox address comes from Settings only; the sender is a filter criterion, never a recipient. Health mail is never forwarded.
    func sendSenderToShoebox(sender: String, shoebox: String, ids: [String], confirmed: ConfirmedAction) {
        guard let actions else { errorMessage = "Connect Gmail first."; return }
        guard shoebox == ShoeboxRule.address() else { errorMessage = "The Shoebox address changed. Start again."; return }
        undo.enqueue(title: "Shoebox rule for \(sender)", work: { [self] in
            _ = try await actions.createFilter(sender: sender, forwardTo: shoebox, labelID: nil, confirmed: confirmed)
            for id in ids.prefix(ShoeboxRule.maxBackfill) {
                let e = try await gmail.getMessage(id: id, account: account)
                guard e.from.email.lowercased() == sender.lowercased(),
                      !HealthMail.isHealth(address: e.from.email, name: e.from.name, subject: e.subject) else { continue }
                try await actions.forward(from: e.from.name + " <" + e.from.email + ">", subject: e.subject, date: e.date, text: e.body, to: shoebox, confirmed: confirmed)
            }
        }, finished: { [self] error in
            errorMessage = error.map { "The Shoebox rule was not completed. \($0.localizedDescription)" } ?? "Shoebox rule added for \(sender)."
        })
    }

    /// Forwards one message the owner picked to Shoebox. Held 10 seconds for Undo.
    /// The address comes from Settings only, and health mail is never forwarded.
    func sendToShoebox(messageID: String, shoebox: String, confirmed: ConfirmedAction) {
        guard let actions else { errorMessage = "Connect Gmail first."; return }
        guard shoebox == ShoeboxRule.address() else { errorMessage = "The Shoebox address changed. Start again."; return }
        undo.enqueue(title: "Sending to Shoebox", work: { [self] in
            let e = try await gmail.getMessage(id: messageID, account: account)
            guard !HealthMail.isHealth(address: e.from.email, name: e.from.name, subject: e.subject) else { throw ActionError.wrongPreview }
            try await actions.forward(from: e.from.name + " <" + e.from.email + ">", subject: e.subject, date: e.date, text: e.body, to: shoebox, confirmed: confirmed)
        }, finished: { [self] error in
            errorMessage = error.map { "Not sent to Shoebox. \($0.localizedDescription)" } ?? "Sent to Shoebox."
        })
    }

    /// Screened Out: files a first-time sender's messages under Lovely/Screened Out and out of the inbox. Nothing is deleted.
    func decline(_ candidate: ScreenedOut.Candidate, confirmed: ConfirmedAction) async {
        guard let actions else { errorMessage = "Connect Gmail first."; return }
        do {
            let label = try await actions.ensureLabel(ScreenedOut.label, confirmed: confirmed)
            for id in candidate.messageIDs { try await actions.file(messageID: id, labelID: label, removeFromInbox: true, confirmed: confirmed) }
            await load()
        } catch { errorMessage = "That could not be declined. \(error.localizedDescription)" }
    }

    func accept(_ candidate: ScreenedOut.Candidate) { ScreenedOut.approve(candidate.address); bumpForScreening() }

    /// New senders confirmed by Gmail (no older mail from them, nothing sent to them).
    var newSenders: [ScreenedOut.Candidate] {
        guard mode == .gmail else { return [] }
        return cached("newSenders", [screeningVersion, otherAddresses]) {
            ScreenedOut.candidates(inbox: posts.map(\.email), sent: sentByMe, approved: ScreenedOut.approved(),
                                   mine: Set([account ?? ""] + otherAddresses), now: Date(), checked: ScreenedOut.checked())
        }
    }

    /// Kid mail for Home's count and the Kids page, rebuilt only when mail or the profile changes.
    func kidMail(for kid: KidProfile) -> [KidMail] {
        cached("kid." + kid.id, [kid]) { KidInsights.mail(for: kid, in: posts) }
    }

    /// Looks up up to 20 unchecked senders. Read-only search; nothing changes in Gmail.
    func verifyNewSenders() async {
        guard mode == .gmail else { return }
        let known = ScreenedOut.checked()
        let pending = ScreenedOut.candidates(inbox: posts.map(\.email), sent: sentByMe, approved: ScreenedOut.approved(),
                                             mine: Set([account ?? ""] + otherAddresses), now: Date())
            .filter { known[$0.address] == nil }.prefix(20)
        for c in pending {
            guard let found = try? await gmail.listMessageIDs(query: ScreenedOut.historyQuery(c.address), limit: 1) else { continue }
            ScreenedOut.record(c.address, isNew: found.ids.isEmpty)
        }
        bumpForScreening()
    }

    /// Screened-out mail older than 30 days.
    func oldScreenedOutIDs() async -> [String] {
        (try? await gmail.listMessageIDs(query: ScreenedOut.trashQuery, limit: 200).ids) ?? []
    }

    /// Moves old screened-out mail to Gmail's Trash (recoverable for 30 days) after a preview tap.
    func trashScreenedOut(_ ids: [String]) async {
        var moved = 0
        for id in ids { if (try? await gmail.trash(messageID: id)) != nil { moved += 1 } }
        ActivityLog().record(kind: "trash", summary: "Moved \(moved) old screened-out messages to Trash")
        errorMessage = "Moved \(moved) old screened-out message\(moved == 1 ? "" : "s") to Trash."
    }
}
