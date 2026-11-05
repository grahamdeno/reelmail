import Foundation

/// The cloud side of settings sync. NSUbiquitousKeyValueStore in the app; a dictionary in tests.
protocol CloudKeyValues: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValues {}

/// Backs up what you typed (households, kids, forwarding addresses, the Shoebox address) to your iCloud account,
/// so a reinstall or a new phone gets them back. Mail, insights and Gmail tokens are never synced.
/// The newer side wins, by a timestamp saved with each change.
struct SettingsSync {
    static let keys = [InsightSettings.key, ForwardAllowlist.key, ShoeboxRule.key]
    static let stampKey = "lovely.sync.updatedAt"
    /// On by default. Kept on this phone only.
    static let enabledKey = "lovely.sync.enabled"

    let local: UserDefaults
    let cloud: CloudKeyValues

    static var standard: SettingsSync { SettingsSync(local: .standard, cloud: NSUbiquitousKeyValueStore.default) }

    var isEnabled: Bool { local.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Copies this phone's settings to iCloud, stamped now.
    func push(now: Date = Date()) {
        guard isEnabled else { return }
        for key in Self.keys {
            if let value = local.object(forKey: key) { cloud.set(value, forKey: key) } else { cloud.removeObject(forKey: key) }
        }
        let stamp = now.timeIntervalSince1970
        cloud.set(stamp, forKey: Self.stampKey)
        local.set(stamp, forKey: Self.stampKey)
        cloud.synchronize()
    }

    /// Takes iCloud's settings when they are newer than this phone's. Returns true when anything changed here.
    @discardableResult
    func pull() -> Bool {
        guard isEnabled else { return false }
        cloud.synchronize()
        guard let cloudStamp = cloud.object(forKey: Self.stampKey) as? Double else { return false }
        let localStamp = local.object(forKey: Self.stampKey) as? Double
        guard localStamp.map({ cloudStamp > $0 }) ?? true else { return false }
        for key in Self.keys {
            if let value = cloud.object(forKey: key) { local.set(value, forKey: key) } else { local.removeObject(forKey: key) }
        }
        local.set(cloudStamp, forKey: Self.stampKey)
        return true
    }

    /// At launch: restore from iCloud if it is newer, otherwise make sure iCloud has this phone's settings.
    func start() {
        guard isEnabled, !pull(), Self.keys.contains(where: { local.object(forKey: $0) != nil }) else { return }
        let cloudStamp = cloud.object(forKey: Self.stampKey) as? Double
        let localStamp = local.object(forKey: Self.stampKey) as? Double
        if cloudStamp == nil || localStamp == nil || (localStamp ?? 0) > (cloudStamp ?? 0) { push() }
    }

    /// Called after a typed setting is saved on the real defaults (tests use their own suites and never sync).
    static func localChanged(_ defaults: UserDefaults) {
        guard defaults === UserDefaults.standard else { return }
        SettingsSync.standard.push()
    }
}
