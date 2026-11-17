import Foundation

// Standalone checks, deliberately not executed in the static-only delivery.
// Production QuotaStore uses this isolated in-memory persistence double here.
@MainActor enum SecureStorage {
    static var values: [String: Data] = [:]
    static var failWrites = false
    static func read(_ key: String) throws -> Data? { values[key] }
    static func write(_ data: Data, key: String) throws {
        if failWrites { throw GlamoError.storage }
        values[key] = data
    }
}
@main enum QuotaContractChecks {
    @MainActor static func main() throws {
        let policy = CommerceConfiguration(products: [], rewardedAdType: 5,
            unlimitedAfterCompletedAds: 4, dailyWatchLimit: 5, watchRewards: [3, 4, 6])
        func store(_ user: String = "test", remote: QuotaConfiguration? = nil) -> QuotaStore {
            let value = QuotaStore()
            value.configure(userID: user, policy: policy, remote: remote)
            return value
        }
        let quota = store()
        precondition(!quota.canRequestReward(for: .watch, premium: false))
        precondition(tryValue { try quota.rewardNoFill(UUID(), owner: "test", kind: .watch) } == nil)
        for n in 0..<5 { precondition(quota.recordWatch("watch-\(n)", premium: false)) }
        precondition(quota.watchesLeft == 0)
        precondition(quota.recordWatch("watch-0", premium: false))
        precondition(!quota.mayWatch("new", premium: false))
        precondition(quota.canRequestReward(for: .watch, premium: false))
        precondition(quota.claimWatchLimitPrompt(premium: false))
        precondition(!quota.claimWatchLimitPrompt(premium: false))
        precondition(!quota.claimWatchLimitPrompt(premium: true))
        // No-fill gifts stay in the same phase; a second exhausted request has no cooldown.
        for round in 0..<2 {
            let id = UUID()
            precondition(tryValue { try quota.rewardNoFill(id, owner: "test", kind: .watch) } != nil)
            precondition(quota.watchesLeft == 3 && quota.completedAds(.watch) == 0)
            precondition(!quota.claimWatchLimitPrompt(premium: false))
            for n in 0..<3 { precondition(quota.recordWatch("gift-\(round)-\(n)", premium: false)) }
            precondition(quota.claimWatchLimitPrompt(premium: false))
            precondition(!quota.claimWatchLimitPrompt(premium: false))
            precondition(tryValue { try quota.rewardNoFill(id, owner: "test", kind: .watch) } == nil)
        }
        do { _ = try quota.rewardNoFill(UUID(), owner: "other", kind: .watch); fatalError("Gift owner bypassed") } catch { }
        SecureStorage.failWrites = true
        do { _ = try quota.rewardNoFill(UUID(), owner: "test", kind: .watch); fatalError("Unsaved gift accepted") } catch { }
        precondition(quota.watchesLeft == 0 && quota.completedAds(.watch) == 0)
        SecureStorage.failWrites = false
        do { try quota.reward(UUID(), owner: "other", kind: .watch); fatalError("Owner bypassed") } catch { }
        for n in 0..<3 {
            try quota.reward(UUID(), owner: "test", kind: .watch)
            let reward = [3, 4, 6][n]
            for i in 0..<reward { precondition(quota.recordWatch("ad-\(n)-\(i)", premium: false)) }
        }
        _ = try quota.rewardNoFill(UUID(), owner: "test", kind: .watch)
        precondition(quota.watchesLeft == 6 && !quota.unlimited && quota.completedAds(.watch) == 3)
        let fourth = UUID()
        try quota.reward(fourth, owner: "test", kind: .watch)
        try quota.reward(fourth, owner: "test", kind: .watch)
        precondition(quota.unlimited && quota.completedAds(.watch) == 4 && store().unlimited)
        // UTC day rollover resets the allowance and completed-ad count.
        var saved = quota.usage!
        saved.day = Date().addingTimeInterval(-2 * 86_400)
        try SecureStorage.write(JSONEncoder().encode(saved), key: "quota.test")
        let reset = store()
        precondition(!reset.unlimited && reset.watchesLeft == 5)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        precondition(utc.component(.hour, from: reset.usage!.day) == 5)
        // Watching during membership must still be remembered when membership expires.
        precondition(reset.recordWatch("premium-view", premium: true))
        precondition(reset.recordWatch("premium-view", premium: false) && reset.watchesLeft == 5)
        // Failure to save never publishes a charge or reward.
        SecureStorage.failWrites = true
        precondition(!reset.recordWatch("write-fail", premium: false))
        precondition(reset.watchesLeft == 5 && reset.usage?.watched.contains("write-fail") == false)
        SecureStorage.failWrites = false
        // A live configuration changes ad rewards now, but cannot refill a spent base.
        let oldAllowance = try JSONDecoder().decode(QuotaConfiguration.self, from:
            Data(#"{"dailyWatchLimit":5,"unlimitedAfterAdCount":5,"firstAdRewardWatchCount":3,"favoriteBaseLimit":2}"#.utf8))
        let newAllowance = try JSONDecoder().decode(QuotaConfiguration.self, from:
            Data(#"{"dailyWatchLimit":20,"unlimitedAfterAdCount":10,"firstAdRewardWatchCount":7,"favoriteBaseLimit":4}"#.utf8))
        let daily = store("daily", remote: oldAllowance)
        precondition(daily.recordWatch("daily-view", premium: false))
        daily.configure(userID: "daily", policy: policy, remote: newAllowance)
        precondition(daily.watchesLeft == 4)
        // Both the freeze and pending values survive process recreation / a missing refresh.
        let reloaded = store("daily")
        precondition(reloaded.watchesLeft == 4)
        reloaded.configure(userID: "daily", policy: policy, remote: newAllowance)
        try reloaded.reward(UUID(), owner: "daily", kind: .watch)
        precondition(reloaded.watchesLeft == 11)
        var priorDay = reloaded.usage!
        priorDay.day = Date().addingTimeInterval(-2 * 86_400)
        try SecureStorage.write(JSONEncoder().encode(priorDay), key: "quota.daily")
        let nextDay = store("daily")
        precondition(nextDay.watchesLeft == 20 && nextDay.completedAds(.watch) == 0)
        // An explicit zero reward still applies while the day's spent base stays locked.
        let separate = store("separate", remote: oldAllowance)
        precondition(separate.recordWatch("used-watch", premium: false))
        separate.configure(userID: "separate", policy: policy, remote: newAllowance)
        precondition(separate.watchesLeft == 4)
        let noBase = try JSONDecoder().decode(QuotaConfiguration.self, from:
            Data(#"{"dailyWatchLimit":0,"unlimitedAfterAdCount":0,"firstAdRewardWatchCount":0,"favoriteBaseLimit":0}"#.utf8))
        separate.configure(userID: "separate", policy: policy, remote: noBase)
        precondition(separate.watchesLeft == 4)
        try separate.reward(UUID(), owner: "separate", kind: .watch)
        precondition(separate.watchesLeft == 4) // Explicit zero reward is not replaced by a fallback.
        // The legacy keys are ignored while existing viewing spend and rewards survive migration.
        let legacy = Data(#"{"day":0,"watched":["already-watched"],"favoritesUsed":4,"completedRewardIDs":[],"extraWatches":2,"extraFavorites":10}"#.utf8)
        try SecureStorage.write(legacy, key: "quota.legacy")
        let migrated = store("legacy")
        precondition(migrated.watchesLeft == 6)
        print("PASS: repeat deduplication, UTC rollover, no-fill, ownership, persistence and migration")
    }
    static func tryValue<T>(_ operation: () throws -> T) -> T { try! operation() }
}
