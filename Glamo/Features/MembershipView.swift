import SwiftUI
import StoreKit

struct MembershipView: View {
    enum RequiredBenefit: Equatable {
        case mediaExport
        case unlimitedViewing
    }

    var requiredBenefit: RequiredBenefit? = nil
    @Environment(\.locale) private var locale
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
                    .padding(.horizontal, DriveStyle.pageInset)
                    .padding(.top, compact ? 0 : 8).padding(.bottom, compact ? 2 : 8)
                    .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    .background(DriveStyle.background, ignoresSafeAreaEdges: .top)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: compact ? 12 : 22) {
                            membershipHeader
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
                        .padding(.horizontal, DriveStyle.pageInset)
                        .padding(.top, compact ? 0 : 22).padding(.bottom, 12)
                        .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomBar(pageWidth: pageWidth, compact: paneHeight < 420)
                    }
                    .onChange(of: feedback) { _, value in
                        if value != nil { scroll.scrollTo("membership.purchaseFeedback", anchor: .bottom) }
                    }
                }
            }.padding(paneMargins)
        }
        .driveScreenBackground()
        .presentationBackground(DriveStyle.background)
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
        IconButton(symbol: .back, label: "Close", tint: DriveStyle.ink, glass: true, glyphSize: 13) { dismiss() }
            .disabled(purchasing || ads.isPresenting)
    }

    private var membershipHeader: some View {
        VStack(spacing: 4) {
            LocalizedText(commerce.premium ? "Vifol Plus" : "Get Premium")
                .driveFont(30, relativeTo: .title, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            if let requiredBenefit {
                LocalizedText(requiredBenefit == .mediaExport ? "Plus includes file export and sharing." : "Unlimited video views")
                    .driveFont(14, relativeTo: .footnote)
                    .foregroundStyle(DriveStyle.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            benefit("MP4 export up to 1080p", symbol: .edit)
            benefit("M4A audio export", symbol: .sound)
            benefit("Share files", symbol: .driveShare)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
    }

    private func benefit(_ title: String, symbol: GlamoGlyph) -> some View {
        HStack(spacing: 10) {
            Glyph(symbol: symbol, size: 17, tint: DriveStyle.ink)
                .frame(width: 22, height: 22)
            LocalizedText(title)
                .driveFont(15, relativeTo: .subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
    }

    private var offerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commerce.premium {
                activeMembership
            } else {
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
        return "Upgrade Now"
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

    private var planPicker: some View {
        VStack(spacing: 22) {
            ForEach(plans, id: \.productIdentifier) { plan in
                planOption(plan)
            }
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

    private func planOption(_ product: SKProduct) -> some View {
        let selected = selectedPlan?.productIdentifier == product.productIdentifier
        let price = commerce.price(product)
        let duration = commerce.period(product, locale: locale)
        let copy = planCopy(product)
        let shape = RoundedRectangle(cornerRadius: DriveStyle.cardRadius)

        return Button { selectedID = product.productIdentifier } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: duration.isEmpty ? price : "\(price) / \(duration)")
                        .driveFont(17, relativeTo: .body, weight: .medium)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: copy.billing.isEmpty ? copy.title : copy.billing)
                        .driveFont(12, relativeTo: .caption)
                        .foregroundStyle(DriveStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Circle()
                    .fill(selected ? DriveStyle.accent : .clear)
                    .overlay {
                        Circle().strokeBorder(selected ? DriveStyle.accent : DriveStyle.secondary.opacity(0.45))
                    }
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .foregroundStyle(DriveStyle.ink)
            .background(.white, in: shape)
            .overlay {
                if selected {
                    shape.strokeBorder(DriveStyle.accent, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressStyle()).disabled(interactionLocked)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("membership.plan.\(product.productIdentifier)")
    }

    private var renewalDisclosure: some View {
        LocalizedText("Renews automatically. Cancel in your Apple account at least 24 hours before renewal.")
            .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bottomBar(pageWidth: CGFloat, compact: Bool) -> some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 8))
        return layout {
            if commerce.premium {
                Button { managingSubscriptions = true } label: {
                    LocalizedText("Manage subscription")
                }.buttonStyle(DrivePrimaryButtonStyle()).disabled(interactionLocked)
            } else {
                purchaseAction
            }
            Button { dismiss() } label: {
                LocalizedText("Maybe Later")
                    .driveFont(17, relativeTo: .body, weight: .semibold)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(DriveStyle.ink)
                    .glamoGlass(in: Capsule(), tint: .white, interactive: true)
                    .contentShape(Capsule())
            }.buttonStyle(PressStyle()).disabled(purchasing || ads.isPresenting)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
        .background(DriveStyle.background, ignoresSafeAreaEdges: .bottom)
    }

    private var purchaseAction: some View {
        Button(action: subscribe) {
            LocalizedText(purchaseButtonTitle)
        }
        .buttonStyle(DrivePrimaryButtonStyle()).disabled(!canSubscribe)
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
            .accessibilityLabel("Vifol Plus")
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
    @Environment(\.locale) private var locale
    @State private var deviceCapacity: Int64?
    @State private var paywall = false
    let browse: () -> Void
    let showActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DrivePageTitle(title: "Profile")
                .padding(.horizontal, DriveStyle.pageInset).frame(minHeight: 44, alignment: .leading)
                .padding(.vertical, 8)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    VStack(spacing: 0) {
                        librarySummary
                        Divider().overlay(DriveStyle.separator).padding(.horizontal, 16)
                        plusEntry
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
                    AccountSettingsSection(showActivity: showActivity)
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.top, 22).padding(.bottom, 24)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .driveScreenBackground()
        .task {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let capacity = try? documents?.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity {
                deviceCapacity = Int64(capacity)
            }
        }
        .fullScreenCover(isPresented: $paywall) { MembershipView() }
    }

    private var identity: some View {
        let name = Text(verbatim: "Vifol").driveFont(16, relativeTo: .subheadline, weight: .medium)
        let badge = Text(verbatim: "Plus")
            .driveFont(10, relativeTo: .caption2, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(DriveStyle.accent, in: RoundedRectangle(cornerRadius: 3))
        return HStack(spacing: 12) {
            DriveProfileAvatar(size: 60)
            VStack(alignment: .leading, spacing: 4) {
                if commerce.premium {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            name
                            badge
                        }.fixedSize()
                        VStack(alignment: .leading, spacing: 4) {
                            name
                            badge
                        }
                    }
                } else {
                    name
                }
                if let id = api.session?.userId.value, !id.isEmpty {
                    LocalizedText("Account ID · %@", id)
                        .driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private var localBytes: Int64? {
        let sizes = library.movies.compactMap(\.byteCount)
        guard !sizes.isEmpty, sizes.count == library.movies.count else { return nil }
        return sizes.reduce(Int64(0), +)
    }

    private var librarySummary: some View {
        let count = library.movies.count
        let size = localBytes
        let localSize = size?.formatted(.byteCount(style: .file).locale(locale))
        let heading = LocalizedText("On this device").driveFont(16, relativeTo: .subheadline, weight: .semibold)
        let fileCount = LocalizedText(count == 1 ? "%@ item" : "%@ items", count.formatted(.number.locale(locale)))
        let usage = Text(verbatim: localSize ?? "").accessibilityHidden(localSize == nil)
        let summary = Group {
            if localSize != nil {
                usage
            } else {
                fileCount
            }
        }.driveFont(14, relativeTo: .footnote).monospacedDigit().foregroundStyle(DriveStyle.secondary)
        return Button(action: browse) {
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        heading.fixedSize(horizontal: true, vertical: false)
                        if let size, let deviceCapacity, deviceCapacity > 0 {
                            DriveMeter(value: Double(size) / Double(deviceCapacity),
                                       tint: Color(red: 0.23, green: 0.72, blue: 0.36), thickness: 7)
                                .frame(width: 68)
                        }
                        Spacer(minLength: 0)
                        summary.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        heading
                        summary
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 10, tint: DriveStyle.secondary)
                    .rotationEffect(.degrees(180))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .foregroundStyle(DriveStyle.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
    }

    private var plusEntry: some View {
        let description = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Vifol Plus").driveFont(16, relativeTo: .subheadline, weight: .medium)
            LocalizedText(commerce.premium ? "Plus is active" : "MP4 and M4A export")
                .driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
        }.fixedSize(horizontal: false, vertical: true)
        let plansButton = Button { paywall = true } label: {
            LocalizedText(commerce.premium ? "View Plus details" : "Upgrade")
                .driveFont(14, relativeTo: .footnote, weight: .semibold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(minHeight: 26)
                .background(DriveStyle.accent, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityIdentifier("account.membership")

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                description.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                plansButton.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                description
                plansButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
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
