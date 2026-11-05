import XCTest
@testable import Reelmail

/// Fictional data only.
final class SettingsSyncTests: XCTestCase {
    private final class FakeCloud: CloudKeyValues {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func synchronize() -> Bool { true }
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "sync-\(UUID().uuidString)")! }

    private func kidsData() -> InsightSettingsData {
        InsightSettingsData(households: [Household(id: "h1", name: "Example House")],
                            kids: [KidProfile(id: "k1", name: "Sam", school: "Example Middle School")])
    }

    func testReinstallRestoresFromICloud() {
        let cloud = FakeCloud()
        let oldPhone = defaults()
        InsightSettings(defaults: oldPhone).save(kidsData())
        ForwardAllowlist(defaults: oldPhone).add("box@example.com")
        ShoeboxRule.setAddress("box@example.com", defaults: oldPhone)
        SettingsSync(local: oldPhone, cloud: cloud).push(now: Date(timeIntervalSince1970: 100))

        let newPhone = defaults()
        SettingsSync(local: newPhone, cloud: cloud).start()
        XCTAssertEqual(InsightSettings(defaults: newPhone).load(), kidsData())
        XCTAssertEqual(ForwardAllowlist(defaults: newPhone).addresses, ["box@example.com"])
        XCTAssertEqual(ShoeboxRule.address(defaults: newPhone), "box@example.com")
    }

    func testFirstLaunchWithSettingsUploadsThem() {
        let cloud = FakeCloud(); let phone = defaults()
        InsightSettings(defaults: phone).save(kidsData())
        SettingsSync(local: phone, cloud: cloud).start()
        XCTAssertNotNil(cloud.values[InsightSettings.key])
        XCTAssertNotNil(cloud.values[SettingsSync.stampKey])
    }

    func testOlderCloudNeverOverwritesNewerPhone() {
        let cloud = FakeCloud(); let phone = defaults()
        InsightSettings(defaults: phone).save(kidsData())
        let sync = SettingsSync(local: phone, cloud: cloud)
        sync.push(now: Date(timeIntervalSince1970: 200))
        cloud.values[InsightSettings.key] = try! JSONEncoder().encode(InsightSettingsData())
        cloud.values[SettingsSync.stampKey] = 150.0
        XCTAssertFalse(sync.pull())
        XCTAssertEqual(InsightSettings(defaults: phone).load(), kidsData())
    }

    func testTurnedOffNeverSyncs() {
        let cloud = FakeCloud(); let phone = defaults()
        phone.set(false, forKey: SettingsSync.enabledKey)
        InsightSettings(defaults: phone).save(kidsData())
        SettingsSync(local: phone, cloud: cloud).start()
        SettingsSync(local: phone, cloud: cloud).push()
        XCTAssertTrue(cloud.values.isEmpty)
    }

    func testOnlyTypedSettingsAreSynced() {
        XCTAssertEqual(Set(SettingsSync.keys), [InsightSettings.key, ForwardAllowlist.key, ShoeboxRule.key])
    }
}

final class SendToShoeboxTests: XCTestCase {
    private func allowlist(_ addresses: [String]) -> ForwardAllowlist {
        let d = UserDefaults(suiteName: "shoebox-\(UUID().uuidString)")!
        let a = ForwardAllowlist(defaults: d); addresses.forEach { _ = a.add($0) }; return a
    }

    func testOfferedOnlyWithAllowedShoeboxAndConnectedGmail() {
        let allowed = allowlist(["box@example.com"])
        XCTAssertTrue(ShoeboxRule.offersSend(shoebox: "box@example.com", allowlist: allowed, connected: true,
                                             fromAddress: "billing@examplepower.com", fromName: "Example Power", subject: "Your bill is ready"))
        XCTAssertFalse(ShoeboxRule.offersSend(shoebox: nil, allowlist: allowed, connected: true,
                                              fromAddress: "billing@examplepower.com", fromName: "Example Power", subject: "Your bill"))
        XCTAssertFalse(ShoeboxRule.offersSend(shoebox: "box@example.com", allowlist: allowlist([]), connected: true,
                                              fromAddress: "billing@examplepower.com", fromName: "Example Power", subject: "Your bill"))
        XCTAssertFalse(ShoeboxRule.offersSend(shoebox: "box@example.com", allowlist: allowed, connected: false,
                                              fromAddress: "billing@examplepower.com", fromName: "Example Power", subject: "Your bill"))
    }

    func testNeverOfferedForHealthMail() {
        XCTAssertFalse(ShoeboxRule.offersSend(shoebox: "box@example.com", allowlist: allowlist(["box@example.com"]), connected: true,
                                              fromAddress: "no-reply@exampleclinic.org", fromName: "Example Clinic", subject: "Your appointment"))
    }

    func testPreviewNamesOnlyTheShoeboxAddress() {
        let p = ShoeboxRule.sendPreview(messageID: "m1", fromName: "Example Power", subject: "Your bill", shoebox: "Box@Example.com")
        XCTAssertEqual(p.kind, .forward)
        XCTAssertEqual(p.recipients, ["box@example.com"])
        XCTAssertTrue(p.lines.contains("Subject: Your bill"))
    }
}
