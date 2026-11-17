import SwiftUI
import StoreKit

struct MembershipView: View {
    enum RequiredBenefit: Equatable {
        case mediaExport
        case unlimitedViewing
    }

    var requiredBenefit: RequiredBenefit? = nil
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var attemptedPurchaseAction = false
    @State private var managingSubscriptions = false
    @State private var purchaseTask: Task<Void, Never>?

    private var plans: [SKProduct] {
        (commerce.policy?.products ?? []).compactMap { entry in
            commerce.products.first { $0.productIdentifier == entry.id }
        }
    }
    private var selectedPlan: SKProduct? {
        plans.first(where: { $0.productIdentifier == selectedID }) ?? plans.first
    }
    private var purchasing: Bool { commerce.preparingPurchase || commerce.busy || purchaseTask != nil }
    private var interactionLocked: Bool { purchasing || commerce.loadingPlans || ads.busy || ads.isPresenting }
    private var canSubscribe: Bool { api.session != nil && selectedPlan != nil && !interactionLocked }

    var body: some View {
        GeometryReader { container in
            let paneMargins = drivePaneMargins(in: container, includesHorizontalFold: true)
            let paneWidth = container.size.width - paneMargins.leading - paneMargins.trailing
            let paneHeight = container.size.height - paneMargins.top - paneMargins.bottom
            let wide = paneWidth >= 740 && !typeSize.isAccessibilitySize && !driveHasReservedRegion(container)
            let compact = verticalSizeClass == .compact || paneHeight < 620
            let pageWidth: CGFloat = wide ? 880 : 560
            let benefitsFirst = !commerce.premium && requiredBenefit != .unlimitedViewing
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: compact ? 12 : 16))
            let feedback = attemptedPurchaseAction ? (commerce.error ?? commerce.message) : nil
            VStack(spacing: 0) {
                closeButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pageHorizontalMargins().padding(.bottom, compact ? 2 : 6)
                    .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    .background(GlamoStyle.background, ignoresSafeAreaEdges: .top)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                            membershipHeader(wide: wide, paneWidth: paneWidth, compact: compact)
                            layout {
                                if benefitsFirst {
                                    benefits.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                                }
                                offerContent
                                if !benefitsFirst {
                                    benefits.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                                }
                            }
                            purchaseFeedback
                                .id("membership.purchaseFeedback")
                            supportLinks
                        }
                        .pageHorizontalMargins().padding(.bottom, 12)
                        .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomBar(pageWidth: pageWidth,
                                  showsPrice: paneHeight >= 460 && !typeSize.isAccessibilitySize)
                    }
                    .onChange(of: feedback) { _, value in
                        if value != nil { scroll.scrollTo("membership.purchaseFeedback", anchor: .bottom) }
                    }
                }
            }.padding(paneMargins)
        }
        .glamoScreenBackground()
        .task { await commerce.loadPlans() }
        .task(id: api.session?.userId.value) {
            if api.session != nil { await commerce.refresh() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in quota.resetIfNeeded() }
        .onDisappear {
            purchaseTask?.cancel(); purchaseTask = nil
        }
        .manageSubscriptionsSheet(isPresented: $managingSubscriptions)
        .onChange(of: managingSubscriptions) { _, isPresented in
            if !isPresented { Task { await commerce.refresh() } }
        }
        .interactiveDismissDisabled(purchasing || ads.isPresenting)
    }

    private var closeButton: some View {
        IconButton(symbol: .close, label: "Close", glass: true) { dismiss() }
            .disabled(purchasing || ads.isPresenting)
    }

    private func membershipHeader(wide: Bool, paneWidth: CGFloat, compact: Bool) -> some View {
        HStack(spacing: 10) {
            heroCopy
            if paneWidth >= 350, typeSize <= .xxLarge {
                plusArtwork
                    .frame(width: wide ? 166 : (compact ? 80 : 106), height: compact ? 54 : 76)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 24), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "Glamo Plus")
                .glamDisplay(42, relativeTo: .title)
                .foregroundStyle(GlamoStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Glamo Plus")
                .accessibilityAddTraits(.isHeader)
            LocalizedText(membershipSubtitle)
                .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
    }

    private var membershipSubtitle: String {
        switch requiredBenefit {
        case .mediaExport: "Plus includes file export and sharing."
        case .unlimitedViewing: "Unlimited video views"
        case nil: "Export and share from your video library."
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalizedText("Plus benefits")
                .font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                benefit("MP4 export up to 1080p", symbol: .edit)
                Divider().overlay(GlamoStyle.line)
                benefit("M4A audio export", symbol: .sound)
                Divider().overlay(GlamoStyle.line)
                benefit("Share files", symbol: .driveShare)
            }
            .padding(.horizontal, 12)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
        }
    }

    private func benefit(_ title: String, symbol: GlamoGlyph) -> some View {
        HStack(spacing: 9) {
            Glyph(symbol: symbol, size: 16, tint: GlamoStyle.accent)
                .frame(width: 26, height: 26)
                .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 8))
            LocalizedText(title)
                .font(.glam(.subheadline, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var offerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commerce.premium {
                activeMembership
            } else {
                LocalizedText("Choose your plan")
                    .font(.glam(.headline))
                    .accessibilityAddTraits(.isHeader)
                if api.session == nil { ConnectionPanel() }
                if !plans.isEmpty { planPicker }
                if let error = commerce.plansError {
                    ErrorNote(message: error)
                    Button {
                        Task { await commerce.loadPlans() }
                    } label: {
                        LocalizedText("Reload plans")
                    }.buttonStyle(CompactActionStyle()).disabled(interactionLocked)
                }
                if selectedPlan != nil { renewalDisclosure }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var purchaseFeedback: some View {
        if attemptedPurchaseAction, commerce.error != nil || commerce.message != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let error = commerce.error { ErrorNote(message: error) }
                if let message = commerce.message {
                    LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var supportLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                restoreLink
                PolicyLinks(compact: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                restoreLink
                PolicyLinks(compact: true)
            }
        }
    }

    private var purchaseButtonTitle: String {
        if commerce.preparingPurchase { return "Preparing subscription…" }
        if commerce.loadingProducts || commerce.loadingPlans { return "Loading prices…" }
        if purchaseTask != nil { return "Waiting for Apple…" }
        if commerce.busy { return "Please wait…" }
        return "Subscribe to Plus"
    }

    private var activeMembership: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("Plus is active")
                .font(.glam(.title3, weight: .semibold))
                .foregroundStyle(GlamoStyle.accent).accessibilityAddTraits(.isHeader)
            if let expiration = commerce.expiration {
                let date = expiration.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                LocalizedText("Access through %@", date)
                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted)
    }

    @ViewBuilder
    private var planPicker: some View {
        if plans.count == 2, !typeSize.isAccessibilitySize {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { planOptions(sideBySide: true) }
                VStack(spacing: 8) { planOptions(sideBySide: false) }
            }
        } else {
            VStack(spacing: 8) { planOptions(sideBySide: false) }
        }
    }

    private func planOptions(sideBySide: Bool) -> some View {
        ForEach(plans, id: \.productIdentifier) { plan in
            planOption(plan, sideBySide: sideBySide)
        }
    }

    private func planCopy(_ product: SKProduct) -> (title: String, billing: String) {
        let language = AppLanguage.from(locale)
        if let period = product.subscriptionPeriod, period.numberOfUnits == 1 {
            switch period.unit {
            case .month:
                return (L10n.text("Monthly", language: language), L10n.text("Billed monthly", language: language))
            case .year:
                return (L10n.text("Yearly", language: language), L10n.text("Billed yearly", language: language))
            default:
                break
            }
        }
        let duration = commerce.period(product, locale: locale)
        let billing = duration.isEmpty ? "" : L10n.format("Billed every %@", [duration], language: language)
        return (product.localizedTitle, billing)
    }

    private func planOption(_ product: SKProduct, sideBySide: Bool) -> some View {
        let selected = selectedPlan?.productIdentifier == product.productIdentifier
        let price = commerce.price(product)
        let copy = planCopy(product)
        let shape = RoundedRectangle(cornerRadius: 16)
        return Button { selectedID = product.productIdentifier } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: copy.title)
                    .font(.glam(.subheadline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: price).environment(\.layoutDirection, .leftToRight)
                    .font(.glam(.title2, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selected ? GlamoStyle.accent : GlamoStyle.ink)
                    .fixedSize(horizontal: sideBySide, vertical: true)
                Text(verbatim: copy.billing).font(.glam(.footnote))
                    .foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !sideBySide, selected {
                    selectedLabel
                }
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .frame(minWidth: sideBySide ? 120 : nil, maxWidth: .infinity,
                       minHeight: sideBySide ? 94 : 44, alignment: .topLeading)
                .foregroundStyle(GlamoStyle.ink)
                .glamoGlass(in: shape, tint: selected ? GlamoStyle.paperMuted : GlamoStyle.surface,
                            mediaBackdrop: selected)
                .overlay {
                    shape.strokeBorder(selected ? GlamoStyle.accent : GlamoStyle.line, lineWidth: selected ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
        }.buttonStyle(PressStyle()).disabled(interactionLocked)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("membership.plan.\(product.productIdentifier)")
    }

    private var selectedLabel: some View {
        LocalizedText("Selected").font(.glam(.caption, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(GlamoStyle.accent)
            .background(GlamoStyle.surface, in: Capsule())
            .accessibilityHidden(true)
    }

    private var renewalDisclosure: some View {
        LocalizedText("Renews automatically. Cancel in your Apple account at least 24 hours before renewal.")
            .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bottomBar(pageWidth: CGFloat, showsPrice: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if commerce.premium {
                ActionButton(title: "Manage subscription", primary: false) { managingSubscriptions = true }
                    .disabled(interactionLocked)
            } else {
                if showsPrice, let plan = selectedPlan {
                    selectedPlanPrice(plan)
                }
                purchaseAction
            }
        }
        .pageHorizontalMargins()
        .padding(.vertical, 8)
        .frame(maxWidth: pageWidth)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Divider().overlay(GlamoStyle.line).allowsHitTesting(false)
        }
    }

    private func selectedPlanPrice(_ plan: SKProduct) -> some View {
        let price = Text(verbatim: commerce.price(plan)).environment(\.layoutDirection, .leftToRight)
            .font(.glam(.headline)).monospacedDigit()
        let period = Text(verbatim: planCopy(plan).billing)
            .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                price
                period
                Spacer(minLength: 0)
                selectedLabel
            }
            VStack(alignment: .leading, spacing: 2) {
                price
                period
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var purchaseAction: some View {
        Button(action: subscribe) {
            HStack(spacing: 10) {
                LocalizedText(purchaseButtonTitle)
                    .font(.glam(.subheadline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if canSubscribe {
                    Glyph(symbol: .back, size: 12, tint: GlamoStyle.onAccent)
                        .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                }
            }
        }.buttonStyle(GlamoActionStyle())
            .disabled(!canSubscribe)
            .accessibilityIdentifier("membership.subscribe")
    }

    private func subscribe() {
        guard canSubscribe, let plan = selectedPlan else { return }
        attemptedPurchaseAction = true
        purchaseTask = Task {
            await commerce.purchase(planID: plan.productIdentifier)
            purchaseTask = nil
        }
    }

    private var restoreLink: some View {
        Button {
            attemptedPurchaseAction = true
            commerce.restore()
        } label: {
            LocalizedText("Restore purchases")
                .font(.glam(.footnote, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minHeight: 44)
                .foregroundStyle(GlamoStyle.accent)
                .glamoGlass(in: Capsule(), tint: GlamoStyle.paper, interactive: !interactionLocked)
                .contentShape(Rectangle())
        }.disabled(interactionLocked).buttonStyle(PressStyle())
            .accessibilityIdentifier("membership.restore")
    }
}

struct PlusEntry: View {
    let isMember: Bool
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                actionBar
            }
            .foregroundStyle(GlamoStyle.ink)
            .clipShape(shape)
            .glamoGlass(in: shape, tint: GlamoStyle.paperMuted, interactive: true, mediaBackdrop: true)
            .contentShape(shape)
        }.buttonStyle(PressStyle())
            .accessibilityElement(children: .combine)
    }

    private var hero: some View {
        let artworkHeight: CGFloat = verticalSizeClass == .compact ? 70 : 92
        return Group {
            if typeSize.isAccessibilitySize {
                heroCopy
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        heroCopy.frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)
                        plusArtwork.frame(width: 142, height: artworkHeight)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        heroCopy
                        plusArtwork.frame(width: 148, height: artworkHeight)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "Glamo Plus").glamDisplay(36, relativeTo: .title)
            LocalizedText(isMember ? "Plus is active" : "MP4 and M4A export")
                .font(.glam(.subheadline, weight: .semibold))
                .foregroundStyle(isMember ? GlamoStyle.accent : GlamoStyle.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            LocalizedText(isMember ? "View Plus details" : "View plans")
                .font(.glam(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Glyph(symbol: .back, size: 12, tint: GlamoStyle.onAccent)
                .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
        }
        .foregroundStyle(GlamoStyle.onAccent)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 52)
        .background(GlamoStyle.accent)
    }
}

struct PlusShortcut: View {
    let isMember: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text(verbatim: "Plus")
                .font(.glam(.footnote, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(GlamoStyle.accent)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 12), tint: GlamoStyle.paperMuted,
                            interactive: true, mediaBackdrop: true)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
            .accessibilityLabel("Glamo Plus")
            .accessibilityHint(LocalizedStringKey(isMember ? "Manage membership" : "View plans"))
    }
}

private var plusArtwork: some View {
    Image("DrivePlusArtwork").resizable().interpolation(.high).scaledToFit()
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false).accessibilityHidden(true)
}

struct AccountView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var library: LibraryStore
    @State private var paywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DrivePageTitle(title: "Settings")
                PlusEntry(isMember: commerce.premium) { paywall = true }
                    .accessibilityIdentifier("account.membership")
                AccountSettingsSection(localItemCount: library.movies.count)
                LocalizedText("Version \(api.configuration.version)")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }.glamoPage()
        }.glamoScreenBackground()
            .fullScreenCover(isPresented: $paywall) { MembershipView() }
    }
}

struct WatchLimitPrompt: View {
    @Binding var showingMembership: Bool
    let finish: () -> Void
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var rewardTask: Task<Void, Never>?
    @State private var requestedReward = false
    @State private var previousCompletion: UUID?

    private var eligibleForAd: Bool {
        quota.canRequestReward(for: .watch, premium: commerce.premium)
    }
    private var isLoadingAd: Bool { rewardTask != nil || ads.busy }
    private var actionsLocked: Bool { isLoadingAd || ads.isPresenting || ads.isPreparingAppOpen || showingMembership }
    private var bonus: LuckyRewardNotice? { requestedReward ? ads.luckyReward : nil }
    private var title: String {
        if bonus != nil { return "Bonus added" }
        return eligibleForAd ? "Daily viewing limit reached" : "Playback unavailable"
    }

    var body: some View {
        GeometryReader { container in
            let margins = drivePaneMargins(in: container, includesHorizontalFold: true)
            ScrollView {
                card.padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: max(0, container.size.height - margins.top - margins.bottom))
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(margins)
        }
        .background(Color.black.opacity(0.56).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .onAppear { titleFocused = true }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in quota.resetIfNeeded() }
        .onChange(of: ads.completedReward, initial: true) { _, completion in
            if requestedReward, let completion, completion != previousCompletion { close() }
        }
        .onChange(of: ads.busy) { _, busy in
            // The SDK load may outlast the reward manager's deadline.
            if requestedReward, !busy, !ads.isPresenting {
                rewardTask?.cancel()
                rewardTask = nil
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalizedText(title).font(.glam(.title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
            if let bonus {
                plusArtwork.frame(width: 114, height: 64)
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
                caption("No ad is available right now. \(bonus.message)")
                ActionButton(title: "Done", action: close)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    choice(isLoadingAd ? "Loading ad…" : "Watch ad for views",
                           detail: eligibleForAd ? quota.rewardSummary(for: .watch) : "Rewards are unavailable.",
                           primary: true, action: startAd)
                        .disabled(!eligibleForAd || actionsLocked || commerce.busy || commerce.preparingPurchase)
                        .accessibilityIdentifier("watchLimit.watchAd")
                    if requestedReward, !actionsLocked {
                        if let error = ads.error { ErrorNote(message: error) }
                        else if let message = ads.message { caption(message) }
                        else if eligibleForAd { caption("Rewards are unavailable.") }
                    }
                }
                choice("Get Plus", detail: "Unlimited video views", primary: false) { showingMembership = true }
                    .disabled(actionsLocked)
                    .accessibilityIdentifier("watchLimit.viewPlans")
                Button(action: close) {
                    LocalizedText("Cancel").font(.glam(.subheadline, weight: .semibold))
                        .foregroundStyle(GlamoStyle.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(PressStyle()).disabled(ads.isPresenting || showingMembership)
            }
        }
        .padding(20).frame(maxWidth: 360)
        .foregroundStyle(GlamoStyle.ink)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 26), tint: GlamoStyle.surface, mediaBackdrop: true)
    }

    private func choice(_ title: String, detail: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(title).font(.glam(.subheadline, weight: .semibold))
                LocalizedText(detail).font(.glam(.footnote))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(GlamoActionStyle(primary: primary))
    }

    private func caption(_ key: String) -> some View {
        LocalizedText(key).font(.glam(.subheadline))
            .foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func startAd() {
        guard eligibleForAd, !actionsLocked, !commerce.busy, !commerce.preparingPurchase else { return }
        requestedReward = true
        previousCompletion = ads.completedReward
        ads.luckyReward = nil
        ads.error = nil
        ads.message = nil
        rewardTask = Task {
            if !commerce.hasVerifiedRightsForCurrentAccount || commerce.release == nil { await commerce.refresh() }
            guard !Task.isCancelled else { return }
            await ads.watch(commerce: commerce, quota: quota, kind: .watch)
            if !Task.isCancelled { rewardTask = nil }
        }
    }

    private func close() {
        guard !ads.isPresenting, !showingMembership else { return }
        if let rewardTask {
            rewardTask.cancel()
            self.rewardTask = nil
            ads.cancelRewardLoading()
        }
        if requestedReward { ads.luckyReward = nil }
        finish()
    }
}
