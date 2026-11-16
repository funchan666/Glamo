import Foundation

// Standalone contract regression checks; compile alongside Glamo/Core/LessonContracts.swift.
// Fixtures contain no account, token or real media URL.
@main
enum ModelContractChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        for raw in ["file:///private/token", "javascript:alert(1)", "relative/path", ""] {
            precondition(WebAddress.media(raw) == nil)
        }
        let seconds = try decoder.decode(UserRights.self, from: Data(#"{"rightExpireTime":1710000000}"#.utf8))
        let millis = try decoder.decode(UserRights.self, from: Data(#"{"rightExpireTime":"1710000000000"}"#.utf8))
        let iso = try decoder.decode(UserRights.self, from: Data(#"{"rightExpireTime":"2024-03-09T16:00:00Z"}"#.utf8))
        precondition(seconds.expiration == millis.expiration && seconds.expiration == iso.expiration)
        let ad = try decoder.decode(AdConfiguration.self, from: Data(#"{"adType":1,"advertiser":"google","config":{"appId":"demo","adUnitId":"demo"},"displayInterval":5,"adOrder":"15","showIntervalRows":null,"maxHourlyImps":"0"}"#.utf8))
        precondition(ad.displayInterval == 5)
        let stringInterval = try decoder.decode(AdConfiguration.self, from: Data(#"{"adType":1,"config":{},"displayInterval":"2.5"}"#.utf8))
        precondition(stringInterval.displayInterval == 2.5)
        let missingInterval = try decoder.decode(AdConfiguration.self, from: Data(#"{"adType":1,"config":{}}"#.utf8))
        let now = Date(timeIntervalSince1970: 1000)
        precondition(!AppOpenTiming.isDue(intervalMinutes: missingInterval.displayInterval, lastShown: nil, now: now))
        precondition(AppOpenTiming.isDue(intervalMinutes: 5, lastShown: nil, now: now))
        precondition(!AppOpenTiming.isDue(intervalMinutes: 5, lastShown: now.addingTimeInterval(-299), now: now))
        precondition(AppOpenTiming.isDue(intervalMinutes: 5, lastShown: now.addingTimeInterval(-300), now: now))
        precondition(AppOpenTiming.isDue(intervalMinutes: 0, lastShown: now, now: now))
        precondition(!AppOpenTiming.isDue(intervalMinutes: -1, lastShown: nil, now: now))
        precondition(!AppOpenTiming.isDue(intervalMinutes: .infinity, lastShown: nil, now: now))
        precondition(!AppOpenTiming.isDue(intervalMinutes: 1, lastShown: now.addingTimeInterval(60), now: now))
        // Optional billing configuration must not send an empty verification key.
        for json in [#"{}"#, #"{"iosVerifyShareKey":null}"#, #"{"iosVerifyShareKey":"  "}"#] {
            let billing = try decoder.decode(IOSBillingConfiguration.self, from: Data(json.utf8))
            let payload = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: billing.verificationFields)) as! [String: Any]
            precondition(payload["iosVerifyShareKey"] == nil && payload["sandBoxTest"] as? Bool == false)
        }
        let noBilling = try decoder.decode(ReleaseConfiguration.self, from: Data(#"{"ios":null}"#.utf8))
        let fallback = noBilling.ios ?? .empty
        precondition(fallback.verificationFields["iosVerifyShareKey"] == nil)
        // Keep historical order snapshots decodable and preserve supplied sandbox settings.
        let originalBilling = try decoder.decode(IOSBillingConfiguration.self,
            from: Data(#"{"iosVerifyShareKey":"test-verification-key","sandBoxTest":true}"#.utf8))
        let restoredBilling = try decoder.decode(IOSBillingConfiguration.self, from: JSONEncoder().encode(originalBilling))
        precondition(restoredBilling.verificationFields["iosVerifyShareKey"] as? String == "test-verification-key")
        precondition(restoredBilling.verificationFields["sandBoxTest"] as? Bool == true)
        print("PASS: URL schemes, entitlement timestamps, app-open interval boundaries and optional billing configuration")
    }
}
