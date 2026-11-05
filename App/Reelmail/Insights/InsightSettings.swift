import Foundation

/// A place bills belong to. Names come from the owner, never from the repository.
struct Household: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Ends on this day, then shows as Ended. Nil: no end.
    var endsOn: Date?
    /// Sender domains whose bills belong here (for example a utility billing service).
    var payeeDomains: [String] = []

    func isEnded(on day: Date = Date()) -> Bool { endsOn.map { $0 < day } ?? false }
}

struct KidProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var school: String
    var teacherNames: [String] = []
    var activities: [String] = []
}

struct InsightSettingsData: Codable, Equatable {
    var households: [Household] = []
    var kids: [KidProfile] = []
}

/// Households and kids, saved on this phone and backed up to your iCloud (SettingsSync) unless you turn that off.
struct InsightSettings {
    static let key = "lovely.insights.settings"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> InsightSettingsData {
        guard let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(InsightSettingsData.self, from: data) else { return InsightSettingsData() }
        return s
    }

    func save(_ s: InsightSettingsData) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
        SettingsSync.localChanged(defaults)
    }

    func clear() { defaults.removeObject(forKey: Self.key); SettingsSync.localChanged(defaults) }

    /// The household a bill belongs to: a household naming its sender domain, else the first one without domains.
    static func household(for bill: Bill, in all: [Household]) -> Household? {
        if let h = all.first(where: { $0.payeeDomains.contains(bill.domain) }) { return h }
        return all.first(where: { $0.payeeDomains.isEmpty })
    }
}
