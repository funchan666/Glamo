import Foundation
import Combine
import GoogleMobileAds
import UserMessagingPlatform
import UIKit
import OSLog

@MainActor
final class RewardedAds: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var busy = false
    @Published private(set) var isPresenting = false
    @Published private(set) var privacyOptionsRequired = false
    @Published private var isPresentingPrivacyForm = false
    @Published private var consentTask: Task<Void, Never>?
    @Published var error: String?
    @Published var message: String?
    @Published var luckyReward: LuckyRewardNotice?
    @Published private(set) var startupFinished = false
    private var startupStarted = false
    @Published private(set) var isPreparingAppOpen = false
    private var appOpenTask: Task<Void, Never>?
    private var appOpenPreloadTask: Task<Void, Error>?
    private var preloadUnitID: String?
    private var preloadRequestID: UUID?
    private var preparedAppOpen: AppOpenAd?
    private var preparedAppOpenDate: Date?
    private var preparedUnitID: String?
    private var presentedPlacement: GoogleAdPlacement?
    private let appOpenLog = Logger(subsystem: "com.glamo.video", category: "AppOpen")
    private var appOpenStage = "idle"
    private var appOpenDeadline: Task<Void, Never>?
    private var appOpenAttempt: UUID?
    private var appOpenHistoryKey: String?
    private var returnedFromBackground = false
    private var consentInfoUpdated = false
    private var consentSetupFinished = false
    private var appOpenAd: AppOpenAd?
    private var rewarded: RewardedAd?
    private var preparedInterstitial: (ad: InterstitialAd, owner: String, expires: ContinuousClock.Instant)?
    private var interstitialPreload: Task<Void, Never>?
    private var presentingInterstitial: InterstitialAd?
    private var refillInterstitial: (() -> Void)?
    private let interstitialHistoryKey = "glamo.interstitial.last-presentation.demo"
    private var unavailableReward: (() -> Void)?
    private var rewardGranted = false
    private var rewardAttempt: UUID?
    @Published private(set) var completedReward: UUID?
    private var started = false

    var canOpenPrivacyOptions: Bool {
        privacyOptionsRequired && consentTask == nil && !isPresentingPrivacyForm
            && !busy && !isPreparingAppOpen && !isPresenting
    }

    private var packagedAppID: String? {
        Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String
    }

    func watch(commerce: CommerceStore, quota: QuotaStore, kind: AllowanceKind) async {
        guard !Task.isCancelled, !busy, !isPresenting, !isPreparingAppOpen, !isPresentingPrivacyForm else { return }
        quota.resetIfNeeded()
        guard quota.canRequestReward(for: kind, premium: commerce.premium) else { return }
        guard commerce.rightsVerified, let policy = commerce.policy, let owner = commerce.api.session?.userId.value else {
            error = "Rewarded ads are not available right now. No views have been deducted."; return
        }
        let attemptID = UUID()
        rewardAttempt = attemptID
        busy = true
        defer {
            if rewardAttempt == attemptID { busy = false; rewardAttempt = nil }
        }
        error = nil
        message = nil
        luckyReward = nil
        rewardGranted = false
        unavailableReward = nil
        guard let placement = GoogleAdPlacement.resolve(for: policy.rewardedAdType, packagedAppID: packagedAppID,
                                                         release: commerce.release) else {
            appOpenLog.error("Rewarded ad configuration missing, invalid or inconsistent with the packaged App ID")
            grantUnavailableReward(attemptID, owner: owner, commerce: commerce, quota: quota, kind: kind)
            return
        }
        var timeout: Task<Void, Never>?
        func armDeadline() {
            timeout?.cancel()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, self.rewardAttempt == attemptID,
                      !self.isPresenting, !self.isPresentingPrivacyForm else { return }
                self.rewardAttempt = nil
                self.busy = false
                self.grantUnavailableReward(attemptID, owner: owner, commerce: commerce, quota: quota, kind: kind)
            }
        }
        armDeadline()
        defer { timeout?.cancel() }
        do {
            beginConsentIfNeeded { [weak self] in
                self?.rewardAttempt == attemptID && !commerce.busy && !commerce.preparingPurchase
            }
            await consentTask?.value
            try Task.checkCancellation()
            guard rewardAttempt == attemptID else { return }
            try prepareSDK()
            // Give ad loading its own budget after the user leaves the consent form.
            armDeadline()
            let ad = try await RewardedAd.load(with: placement.unitID, request: Request())
            try Task.checkCancellation()
            guard rewardAttempt == attemptID, UIApplication.shared.applicationState == .active else { return }
            guard canRequestAds else { throw GlamoError.service("Ads are unavailable with your current privacy choices.") }
            try ad.canPresent(from: nil)
            guard commerce.api.session?.userId.value == owner, !commerce.premium else { throw GlamoError.unauthorized }
            rewarded = ad
            unavailableReward = { [weak self] in
                self?.grantUnavailableReward(attemptID, owner: owner, commerce: commerce, quota: quota, kind: kind)
            }
            ad.fullScreenContentDelegate = self
            let rewardID = UUID()
            isPresenting = true
            ad.present(from: nil) { [weak self, weak ad] in
                guard let self, let ad, self.rewarded === ad, !self.rewardGranted else { return }
                do {
                    try quota.reward(rewardID, owner: owner, kind: kind)
                    self.rewardGranted = true
                    self.message = kind == .watch ? "Your viewing allowance has been updated." : "Your saving allowance has been updated."
                } catch { self.error = "The ad finished, but its reward could not be saved. \(error.localizedDescription)" }
            }
        } catch {
            guard rewardAttempt == attemptID else { return }
            isPresenting = false
            let failure = error as NSError
            // Preparation, consent configuration and load failures all mean no ad.
            // Explicit cancellation never earns a gift or bypasses consent.
            if Task.isCancelled || error is CancellationError ||
                (failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) { return }
            appOpenLog.error("Rewarded ad unavailable; domain=\(failure.domain, privacy: .public), code=\(failure.code)")
            grantUnavailableReward(attemptID, owner: owner, commerce: commerce, quota: quota, kind: kind)
        }
    }

    func preloadInterstitial(commerce: CommerceStore) {
        guard let placement = GoogleDemoAds.placement(unitID: GoogleDemoAds.interstitialUnit, packagedAppID: packagedAppID),
              let owner = commerce.api.session?.userId.value, commerce.hasVerifiedRightsForCurrentAccount,
              !commerce.premium, canRequestAds, !isPresenting, interstitialPreload == nil else { return }
        if let preparedInterstitial, preparedInterstitial.owner == owner,
           preparedInterstitial.expires > .now { return }
        preparedInterstitial = nil
        startSDKIfNeeded()
        interstitialPreload = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.interstitialPreload = nil } }
            let expires = ContinuousClock.now.advanced(by: .seconds(60 * 60))
            guard let ad = try? await InterstitialAd.load(with: placement.unitID, request: Request()),
                  !Task.isCancelled, self.canRequestAds, commerce.api.session?.userId.value == owner,
                  commerce.hasVerifiedRightsForCurrentAccount, !commerce.premium else { return }
            self.preparedInterstitial = (ad, owner, expires)
        }
    }

    func presentInterstitialIfReady(commerce: CommerceStore) {
        guard let owner = commerce.api.session?.userId.value, commerce.hasVerifiedRightsForCurrentAccount,
              !commerce.premium, !commerce.busy, !commerce.preparingPurchase,
              UIApplication.shared.applicationState == .active,
              canRequestAds, !busy, !isPreparingAppOpen, !isPresenting,
              AppOpenTiming.isDue(intervalMinutes: 2,
                                  lastShown: UserDefaults.standard.object(forKey: interstitialHistoryKey) as? Date) else { return }
        guard let inventory = preparedInterstitial, inventory.owner == owner, inventory.expires > .now else {
            preloadInterstitial(commerce: commerce)
            return
        }
        preparedInterstitial = nil
        do { try inventory.ad.canPresent(from: nil) }
        catch { preloadInterstitial(commerce: commerce); return }
        presentingInterstitial = inventory.ad
        refillInterstitial = { [weak self] in self?.preloadInterstitial(commerce: commerce) }
        inventory.ad.fullScreenContentDelegate = self
        isPresenting = true
        inventory.ad.present(from: nil)
    }

    private func discardInterstitialInventory() {
        interstitialPreload?.cancel()
        interstitialPreload = nil
        preparedInterstitial = nil
    }

    private func finishInterstitial() {
        presentingInterstitial = nil
        isPresenting = false
        let refill = refillInterstitial
        refillInterstitial = nil
        refill?()
    }

    func cancelRewardLoading() {
        guard !isPresenting else { return }
        rewardAttempt = nil
        busy = false
    }

    private func grantUnavailableReward(_ attempt: UUID, owner: String, commerce: CommerceStore,
                                        quota: QuotaStore, kind: AllowanceKind) {
        do {
            guard commerce.api.session?.userId.value == owner else { throw GlamoError.unauthorized }
            guard !commerce.premium else { return }
            if let gift = try quota.rewardNoFill(attempt, owner: owner, kind: kind) {
                error = nil
                message = nil
                luckyReward = LuckyRewardNotice(message: gift)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func beginConsentIfNeeded(mayPresent: @escaping () -> Bool) {
        guard let appID = packagedAppID,
              appID.range(of: #"^ca-app-pub-[0-9]{16}~[0-9]{10}$"#, options: .regularExpression) != nil,
              !consentSetupFinished, consentTask == nil, !isPresentingPrivacyForm, !isPresenting else { return }
        discardAppOpenInventory()
        discardInterstitialInventory()
        consentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
                self.consentTask = nil
            }
            do {
                if !self.consentInfoUpdated {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                    self.consentInfoUpdated = true
                }
                guard UIApplication.shared.applicationState == .active, mayPresent() else { return }
                self.isPresentingPrivacyForm = true
                self.returnedFromBackground = false
                defer { self.isPresentingPrivacyForm = false }
                try await ConsentForm.loadAndPresentIfRequired(from: nil)
                self.consentSetupFinished = true
            } catch {
                let failure = error as NSError
                self.appOpenLog.info("UMP consent setup failed; domain=\(failure.domain, privacy: .public), code=\(failure.code)")
            }
        }
    }

    private var canRequestAds: Bool {
        guard !isPresentingPrivacyForm, consentTask == nil else { return false }
        // UMP owns the consent state, including a prior session after an update error.
        return ConsentInformation.shared.canRequestAds
    }

    private func prepareSDK() throws {
        guard canRequestAds else { throw GlamoError.service("Ads are unavailable with your current privacy choices.") }
        startSDKIfNeeded()
    }

    private func startSDKIfNeeded() {
        guard canRequestAds, !started else { return }
        started = true
        // Google-only integration: start once, then request ads immediately, as
        // in Google's quick start. Adapter completion must not block the app.
        MobileAds.shared.start { [weak self] _ in
            self?.appOpenLog.info("Google Mobile Ads initialization callback received")
        }
    }

    private func discardAppOpenInventory() {
        appOpenPreloadTask?.cancel()
        appOpenPreloadTask = nil
        preloadUnitID = nil
        preloadRequestID = nil
        preparedAppOpen = nil
        preparedAppOpenDate = nil
        preparedUnitID = nil
    }

    private func preloadAppOpen(for placement: GoogleAdPlacement) async throws {
        guard canRequestAds else { throw CancellationError() }
        let unitID = placement.unitID
        if preparedUnitID == unitID, preparedAppOpen != nil, let date = preparedAppOpenDate,
           Date().timeIntervalSince(date) >= 0, Date().timeIntervalSince(date) < 4 * 60 * 60 {
            appOpenLog.info("Using preloaded app-open ad")
            return
        }
        if let task = appOpenPreloadTask, preloadUnitID == unitID {
            try await task.value
            return
        }
        discardAppOpenInventory()
        preloadUnitID = unitID
        let requestID = UUID()
        preloadRequestID = requestID
        // The shared task signals completion. The ad stays in the main-actor cache.
        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else { throw CancellationError() }
            let began = ContinuousClock.now
            do {
                try Task.checkCancellation()
                guard self.preloadRequestID == requestID, self.canRequestAds else { throw CancellationError() }
                let ad = try await AppOpenAd.load(with: unitID, request: Request())
                try Task.checkCancellation()
                guard self.preloadRequestID == requestID, self.canRequestAds else { throw CancellationError() }
                self.preparedAppOpen = ad
                self.preparedAppOpenDate = Date()
                self.preparedUnitID = unitID
                self.appOpenPreloadTask = nil
                self.preloadUnitID = nil
                self.preloadRequestID = nil
                self.appOpenLog.info("App-open inventory ready after \(began.duration(to: .now).description, privacy: .public)")
            } catch {
                if self.preloadRequestID == requestID {
                    self.appOpenPreloadTask = nil
                    self.preloadUnitID = nil
                    self.preloadRequestID = nil
                    let failure = error as NSError
                    self.appOpenLog.error("App-open inventory failed; domain=\(failure.domain, privacy: .public), code=\(failure.code), message=\(failure.localizedDescription, privacy: .public)")
                }
                throw error
            }
        }
        appOpenPreloadTask = task
        try await task.value
    }

    // Cold start includes pre-login guest preparation. Foreground returns use the same gate.
    func beginStartup(commerce: CommerceStore, accountAccess: AccountAccessFlow) {
        beginConsentIfNeeded { !commerce.busy && !commerce.preparingPurchase && !accountAccess.isBusy }
        guard !startupStarted else { return }
        startupStarted = true
        requestAppOpen(commerce: commerce, accountAccess: accountAccess, coldStart: true)
    }

    func didEnterBackground() {
        // An ad or SDK consent browser returning to the app must not recursively trigger an ad.
        returnedFromBackground = !isPresenting && !busy && !isPresentingPrivacyForm
        if isPreparingAppOpen { finishAppOpen(reason: "background", preservePreparation: true) }
    }

    func didBecomeActive(commerce: CommerceStore, accountAccess: AccountAccessFlow) {
        if !busy {
            beginConsentIfNeeded { !commerce.busy && !commerce.preparingPurchase && !accountAccess.isBusy }
        }
        guard returnedFromBackground else { return }
        returnedFromBackground = false
        requestAppOpen(commerce: commerce, accountAccess: accountAccess, coldStart: false)
    }

    private func requestAppOpen(commerce: CommerceStore, accountAccess: AccountAccessFlow, coldStart: Bool) {
        guard appOpenAttempt == nil, !busy, !isPresenting, !isPresentingPrivacyForm,
              !commerce.busy, !commerce.preparingPurchase, !accountAccess.isBusy else {
            if coldStart { startupFinished = true }
            return
        }
        let attempt = UUID()
        appOpenAttempt = attempt
        isPreparingAppOpen = true
        // Bound only this presentation opportunity. A slow network must not keep
        // the home screen locked or discard inventory for the next foreground.
        let waitingBudget = coldStart ? 2.0 : 1.0
        appOpenStage = "authentication"
        appOpenLog.info("App-open opportunity started; coldStart=\(coldStart), budget=\(waitingBudget)")
        scheduleAppOpenDeadline(attempt: attempt, seconds: waitingBudget)
        appOpenTask = Task { [weak self] in
            guard let self else { return }
            let packagedAppID = self.packagedAppID
            do {
                try await commerce.api.prepareVisitor()
                try Task.checkCancellation()
                guard let owner = commerce.api.session?.userId.value else {
                    self.finishAppOpen(attempt: attempt); return
                }
                if self.appOpenAttempt == attempt { self.appOpenStage = "rights-and-configuration" }
                self.appOpenLog.info("App-open guest authentication ready")
                await commerce.refresh()
                try Task.checkCancellation()
                guard commerce.api.session?.userId.value == owner,
                      commerce.rightsVerified, !commerce.premium else {
                    self.finishAppOpen(attempt: attempt, reason: commerce.premium ? "membership" : "rights-unavailable"); return
                }
                guard let placement = GoogleAdPlacement.resolve(for: 1, packagedAppID: packagedAppID,
                                                                 release: commerce.release) else {
                    self.appOpenLog.error("App-open configuration missing, invalid or inconsistent with the packaged App ID")
                    self.finishAppOpen(attempt: attempt, reason: "ad-configuration-unavailable"); return
                }
                let interval = commerce.release?.appOpenInterval ?? (GoogleDemoAds.isRequested ? 0 : nil)
                let key = "glamo.app-open.last-impression.\(commerce.api.configuration.servicePackageName).\(commerce.api.configuration.apiBaseURL?.host ?? "none").\(placement.isOfficialDemo ? "demo" : "production")"
                self.appOpenLog.info("App-open rights/configuration ready; intervalMinutes=\(interval ?? -1)")
                if self.appOpenAttempt == attempt { self.appOpenStage = "ad-preparation" }
                // Consent can finish independently of this app-open presentation opportunity.
                await self.consentTask?.value
                try Task.checkCancellation()
                try self.prepareSDK()
                guard AppOpenTiming.isDue(intervalMinutes: interval,
                    lastShown: UserDefaults.standard.object(forKey: key) as? Date) else {
                    Task { _ = try? await self.preloadAppOpen(for: placement) }
                    self.finishAppOpen(attempt: attempt, reason: "interval-not-due")
                    return
                }
                try await self.preloadAppOpen(for: placement)
                try Task.checkCancellation()
                guard self.appOpenAttempt == attempt,
                      self.preparedUnitID == placement.unitID, let ad = self.preparedAppOpen,
                      commerce.api.session?.userId.value == owner,
                      !commerce.premium, UIApplication.shared.applicationState == .active,
                      !self.busy, !self.isPresenting, !commerce.busy, !commerce.preparingPurchase,
                      !accountAccess.isBusy, self.canRequestAds,
                      AppOpenTiming.isDue(intervalMinutes: interval,
                        lastShown: UserDefaults.standard.object(forKey: key) as? Date) else {
                    self.finishAppOpen(attempt: attempt); return
                }
                do { try ad.canPresent(from: nil) }
                catch { self.discardAppOpenInventory(); throw error }
                self.discardAppOpenInventory()
                self.presentedPlacement = placement
                self.appOpenStage = "presenting"
                self.appOpenLog.info("App-open ad ready; presenting")
                self.appOpenAd = ad
                self.appOpenHistoryKey = key
                ad.fullScreenContentDelegate = self
                self.appOpenDeadline?.cancel()
                self.isPreparingAppOpen = false
                self.isPresenting = true
                ad.present(from: nil)
            } catch {
                if self.appOpenAttempt == attempt {
                    let failure = error as NSError
                    self.appOpenLog.info("App-open preparation failed; domain=\(failure.domain, privacy: .public), code=\(failure.code)")
                }
                self.finishAppOpen(attempt: attempt, reason: "preparation-failed")
            }
        }
    }

    private func scheduleAppOpenDeadline(attempt: UUID, seconds: Double) {
        appOpenDeadline?.cancel()
        appOpenDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.appOpenAttempt == attempt, !self.isPresenting else { return }
            self.finishAppOpen(attempt: attempt, reason: "deadline", preservePreparation: true)
        }
    }

    private func finishAppOpen(attempt: UUID? = nil, reason: String = "finished", preservePreparation: Bool = false) {
        if let attempt, attempt != appOpenAttempt { return }
        appOpenLog.info("App-open ended; reason=\(reason, privacy: .public), stage=\(self.appOpenStage, privacy: .public)")
        appOpenStage = "idle"
        appOpenAttempt = nil
        appOpenDeadline?.cancel()
        appOpenDeadline = nil
        if !preservePreparation { appOpenTask?.cancel() }
        appOpenTask = nil
        appOpenAd = nil
        presentedPlacement = nil
        appOpenHistoryKey = nil
        isPreparingAppOpen = false
        isPresenting = false
        startupFinished = true
    }

    func adDidRecordImpression(_ ad: FullScreenPresentingAd) {
        guard let current = appOpenAd, ad === current, let key = appOpenHistoryKey else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        appOpenLog.info("App-open impression recorded")
    }

    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        guard let current = presentingInterstitial, ad === current else { return }
        UserDefaults.standard.set(Date(), forKey: interstitialHistoryKey)
    }

    func privacyOptions() async {
        guard canOpenPrivacyOptions, UIApplication.shared.applicationState == .active else { return }
        error = nil
        isPresentingPrivacyForm = true
        returnedFromBackground = false
        discardAppOpenInventory()
        discardInterstitialInventory()
        defer {
            privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
            isPresentingPrivacyForm = false
        }
        do { try await ConsentForm.presentPrivacyOptionsForm(from: nil) }
        catch { self.error = error.localizedDescription }
    }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        if let current = appOpenAd, ad === current {
            let placement = presentedPlacement
            finishAppOpen()
            if let placement { Task { _ = try? await self.preloadAppOpen(for: placement) } }
            return
        }
        if let current = presentingInterstitial, ad === current { finishInterstitial(); return }
        guard let current = rewarded, ad === current else { return }
        rewarded = nil
        unavailableReward = nil
        isPresenting = false
        if rewardGranted { completedReward = UUID() }
        else if error == nil { message = "No reward was received. Finish the ad to receive your reward." }
    }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        if let current = appOpenAd, ad === current { finishAppOpen(); return }
        if let current = presentingInterstitial, ad === current { finishInterstitial(); return }
        guard let current = rewarded, ad === current else { return }
        rewarded = nil
        isPresenting = false
        let fallback = unavailableReward
        unavailableReward = nil
        if !rewardGranted { fallback?() }
    }
}

struct LuckyRewardNotice: Identifiable {
    let id = UUID()
    let message: String
}
