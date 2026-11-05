import SwiftUI
import UserNotifications

/// Opens the right page when a Lovely notification is tapped. The route waits here until the app is on screen.
final class NotificationOpener: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationOpener()
    nonisolated(unsafe) static var pending: Route?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        if id.hasPrefix("lovely.morning") { Self.pending = .brief }
        else if id == MorningBriefScheduler.nudgeID { Self.pending = .brief }
        else if id.hasPrefix("lovely.alarm.") { Self.pending = .money }
    }
}

/// The morning brief as a full page: what needs you today, in order.
struct BriefView: View {
    @Environment(FeedStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let digest = store.digest
        let now = Date()
        let money = MoneyInsights.summary(store.insights.store, households: InsightSettings().load().households)
        let today = store.comingUp.filter { Calendar.current.isDate($0.date.start, inSameDayAs: now) }
        let appointments = BriefContent.upcomingAppointments(store.insights.store, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(now.formatted(.dateTime.weekday(.wide).month().day())).font(.subheadline).foregroundStyle(CalmStyle.secondary)
                ForEach(money.alarms) { b in
                    Button { router.open(.money) } label: {
                        Text("\(b.payee) reports a payment problem.").font(.subheadline.weight(.semibold))
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(CalmStyle.warning, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(CalmStyle.warningInk)
                    }.buttonStyle(.plain)
                }
                if !today.isEmpty || !appointments.isEmpty {
                    header("Today and ahead")
                    ForEach(today, id: \.post.id) { e in
                        line(FallbackSummarizer.cleanSubject(e.post.email.subject, fallbackBody: e.post.email.body),
                             sub: ComingUp.label(e.date, now: now)) { router.open(.email(e.post.id)) }
                    }
                    ForEach(appointments) { a in
                        line("Appointment", sub: BriefContent.appointmentText(a)) { }
                    }
                }
                if !digest.waiting.isEmpty {
                    header("Waiting on you")
                    ForEach(digest.waiting.prefix(5)) { p in
                        line(p.email.from.name, sub: p.summary.headline) { router.open(.email(p.id)) }
                    }
                }
                if store.promises.count > 0 {
                    line("You said you would", sub: "\(store.promises.count) open") { router.open(.promises) }
                }
                if digest.todo.count > 0 { line("To do", sub: "\(digest.todo.count) in Home") { router.tab = .home; router.path = [] } }
                let kids = InsightSettings().load().kids
                if !kids.isEmpty { line("Kids", sub: "\(kids.reduce(0) { $0 + store.kidMail(for: $1).count }) in mail") { router.open(.kids) } }
                let energy = EnergyInsights.summary(store.insights.store, household: nil)
                if energy.latest != nil { line("Energy", sub: energy.headline) { router.open(.energy) } }
                if !money.actionNeeded.isEmpty {
                    line("Accounts asking for action", sub: money.actionNeeded.map(\.institution).joined(separator: ", ")) { router.open(.money) }
                }
                Button { router.open(.walkthrough) } label: { Label("Walk through today's mail", systemImage: "rectangle.stack").frame(maxWidth: .infinity) }
                    .buttonStyle(CalmActionStyle(prominent: true))
            }.padding(20)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle("Brief").navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(CalmStyle.secondary).padding(.top, 6)
    }

    private func line(_ title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(CalmStyle.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading)
            .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

/// Pure helpers for the brief page.
enum BriefContent {
    /// Appointments from today through the next 7 days.
    static func upcomingAppointments(_ store: InsightStore, now: Date) -> [Appointment] {
        let start = now.addingTimeInterval(-3_600)
        let end = now.addingTimeInterval(7 * 86_400)
        return store.appointments.filter { $0.start >= start && $0.start <= end }.sorted { $0.start < $1.start }
    }

    /// Dates are stored as UTC days, so they are shown as UTC days.
    static func appointmentText(_ a: Appointment) -> String {
        var style = Date.FormatStyle(timeZone: InsightDates.utc).weekday(.abbreviated).month(.abbreviated).day()
        if a.hasTime { style = style.hour().minute() }
        return a.start.formatted(style)
    }
}


/// One quiet row on Home that opens the brief page.
struct BriefRow: View {
    @Environment(Router.self) private var router
    var body: some View {
        Button { router.open(.brief) } label: {
            HStack(spacing: 10) {
                Text("Today's brief").font(.subheadline.weight(.medium)).foregroundStyle(CalmStyle.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CalmStyle.secondary)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}
