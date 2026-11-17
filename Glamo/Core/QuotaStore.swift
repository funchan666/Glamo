import Foundation
import Combine

enum AllowanceKind: String, Codable, CaseIterable, Identifiable {
    case watch
    var id: String { rawValue }
}

struct DailyUsage: Codable {
    var day: Date
    var watched: Set<String> = []
    var completedRewardIDs: Set<UUID> = []
    var extraWatches = 0
    var luckyRewardIDs: Set<UUID>?
    var lastLuckyReward: Date?
    var schemaVersion: Int?
    var watchSpend: Int?
    // Today's admitted base is independent of live per-ad reward configuration.
    var watchBaseForDay: Int?
    var nextWatchBase: Int?
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var usage: DailyUsage?
    @Published var error: String?
    private var userID: String?
    private var policy: CommerceConfiguration?
    private var remote: QuotaConfiguration?
    private var storageOK = true
    // Shared by all player pages, so lazy-page recycling and swiping cannot
    // reopen a dismissed prompt during the same exhausted-allowance period.
    private var watchLimitPromptClaimed = false
    var unlimited: Bool { isUnlimited(.watch) }
    var watchesLeft: Int { max(0, (usage?.watchBaseForDay ?? 0) + (usage?.extraWatches ?? 0) - (usage?.watchSpend ?? usage?.watched.count ?? 0)) }
    func isUnlimited(_ kind: AllowanceKind) -> Bool { completedAds(kind) >= 4 }
    func completedAds(_: AllowanceKind) -> Int { usage?.completedRewardIDs.count ?? 0 }
    func rewardSummary(for kind: AllowanceKind) -> String {
        if completedAds(kind) >= 3 {
            return "Finish this ad for unlimited views today."
        }
        return "Watch a full ad for more views."
    }
    private var nextWatchReward: Int {
        let index = min(completedAds(.watch), 2)
        let values = [remote?.firstAdRewardWatchCount, remote?.secondAdRewardWatchCount, remote?.thirdAdRewardWatchCount]
        return max(0, values[index] ?? policy?.watchRewards[safe: index] ?? 0)
    }
    func configure(userID: String?, policy: CommerceConfiguration?, remote: QuotaConfiguration?) {
        objectWillChange.send()
        self.policy = policy
        self.remote = remote
        guard self.userID != userID || usage == nil else {
            resetIfNeeded()
            updateDailyBases()
            return
        }
        self.userID = userID
        usage = nil
        watchLimitPromptClaimed = false
        storageOK = true
        error = nil
        guard userID != nil else { return }
        do {
            if let data = try SecureStorage.read(key) {
                var saved = try JSONDecoder().decode(DailyUsage.self, from: data)
                if saved.schemaVersion != 2 {
                    // Preserve existing viewing spend/rewards during the one-time UTC migration.
                    saved.day = boundary()
                    saved.schemaVersion = 2
                    saved.watchSpend = saved.watched.count
                    try commit(saved)
                } else { usage = saved }
            } else { try commit(freshDay()) }
            resetIfNeeded()
            updateDailyBases()
        } catch { storageOK = false; self.error = "Daily allowance could not be read. Please try again later." }
    }
    private func updateDailyBases() {
        guard storageOK, var next = usage else { return }
        // A startup refresh may temporarily have no remote configuration. Keep the
        // last persisted next-day value until a real configuration arrives.
        let watchBase = max(0, remote?.dailyWatchLimit ?? (remote == nil ? next.nextWatchBase : nil) ?? policy?.dailyWatchLimit ?? 0)
        next.nextWatchBase = watchBase
        if next.watchBaseForDay == nil || (next.watchSpend ?? next.watched.count) == 0 { next.watchBaseForDay = watchBase }
        do { try commit(next) }
        catch { storageOK = false; self.error = "Daily allowance could not be read. Please try again later." }
    }
    func resetIfNeeded() {
        guard storageOK, userID != nil, let usage else { return }
        if boundary() > usage.day {
            do { try commit(freshDay()) }
            catch { storageOK = false; self.error = error.localizedDescription }
        }
    }
    func mayWatch(_ id: String, premium: Bool) -> Bool {
        resetIfNeeded()
        return premium || (storageOK && userID != nil && (unlimited || usage?.watched.contains(id) == true || watchesLeft > 0))
    }
    func recordWatch(_ id: String, premium: Bool) -> Bool {
        guard mayWatch(id, premium: premium) else { return false }
        guard var next = usage else { return false }
        guard !next.watched.contains(id) else { return true }
        let previousSpend = next.watchSpend ?? next.watched.count
        next.watched.insert(id)
        next.watchSpend = previousSpend + (premium || unlimited ? 0 : 1)
        do { try commit(next); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func canRequestReward(for kind: AllowanceKind, premium: Bool) -> Bool {
        return !premium && storageOK && userID != nil && policy != nil && !isUnlimited(kind) && watchesLeft == 0
    }
    func claimWatchLimitPrompt(premium: Bool) -> Bool {
        resetIfNeeded()
        guard canRequestReward(for: .watch, premium: premium), !watchLimitPromptClaimed else { return false }
        watchLimitPromptClaimed = true
        return true
    }
    func reward(_ id: UUID, owner: String, kind _: AllowanceKind) throws {
        guard owner == userID, storageOK else { throw GlamoError.storage }
        resetIfNeeded()
        guard var next = usage, policy != nil else { throw GlamoError.configuration }
        guard !next.completedRewardIDs.contains(id) else { return }
        next.extraWatches += nextWatchReward
        next.completedRewardIDs.insert(id)
        try commit(next)
    }
    func rewardNoFill(_ id: UUID, owner: String, kind: AllowanceKind) throws -> String? {
        guard owner == userID, storageOK else { throw GlamoError.storage }
        resetIfNeeded()
        guard var next = usage, policy != nil else { throw GlamoError.configuration }
        guard !isUnlimited(kind), watchesLeft == 0, next.luckyRewardIDs?.contains(id) != true else { return nil }
        let gift = nextWatchReward
        guard gift > 0 else { return nil }
        // No-fill gifts leave the completed-ad counter unchanged.
        // At stage four nextWatchReward remains the third-stage amount.
        next.extraWatches += gift
        next.luckyRewardIDs = (next.luckyRewardIDs ?? []).union([id])
        try commit(next)
        return "More views added. Your ad progress stays the same."
    }
    private var key: String { "quota.\(userID ?? "none")" }
    private func freshDay() -> DailyUsage {
        var value = DailyUsage(day: boundary())
        value.schemaVersion = 2
        value.watchSpend = 0
        value.watchBaseForDay = max(0, remote?.dailyWatchLimit ?? usage?.nextWatchBase ?? policy?.dailyWatchLimit ?? 0)
        value.nextWatchBase = value.watchBaseForDay
        return value
    }
    static func nextReset(after now: Date = Date()) -> Date {
        boundary(at: now).addingTimeInterval(86_400)
    }
    private func boundary() -> Date { Self.boundary(at: Date()) }
    private static func boundary(at now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let five = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now)!
        return now >= five ? five : calendar.date(byAdding: .day, value: -1, to: five)!
    }
    private func commit(_ value: DailyUsage) throws {
        try SecureStorage.write(JSONEncoder().encode(value), key: key)
        usage = value
        if watchesLeft > 0 || unlimited { watchLimitPromptClaimed = false }
    }
}
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
