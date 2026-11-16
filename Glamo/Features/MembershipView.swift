import SwiftUI
import StoreKit

struct MembershipView: View {
    enum RequiredBenefit: Equatable {
        case mediaExport
    }

    var rewardKind: AllowanceKind? = nil
    var requiredBenefit: RequiredBenefit? = nil
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String?
    @State private var attemptedPurchaseAction = false
    @State private var managingSubscriptions = false
    @State private var purchaseTask: Task<Void, Never>?
    @State private var rewardTask: Task<Void, Never>?
    @State private var requestedReward = false
    @State private var acknowledgedLuckyReward = false

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
            let paneMargins = drivePaneMargins(in: container)
            let paneWidth = container.size.width - paneMargins.leading - paneMargins.trailing
            let wide = paneWidth >= 740 && !typeSize.isAccessibilitySize && !driveHasReservedRegion(container)
            let pageWidth: CGFloat = wide ? 880 : 540
            let benefitsFirst = !commerce.premium && rewardKind != .watch
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            VStack(spacing: 0) {
                closeButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .pageHorizontalMargins().padding(.vertical, 8)
                    .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    .background(GlamoStyle.background, ignoresSafeAreaEdges: .top)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        membershipHeader(wide: wide, paneWidth: paneWidth)
                        if rewardKind == .watch, !commerce.premium, api.session != nil {
                            rewardOption
                        }
                        layout {
                            if benefitsFirst {
                                benefits.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                            }
                            offerContent
                            if !benefitsFirst {
                                benefits.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                            }
                        }
                    }
                    .pageHorizontalMargins().padding(.bottom, 24)
                    .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
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
            if !ads.isPresenting { cancelRewardRequest() }
        }
        .onChange(of: ads.completedReward) { _, completion in
            if requestedReward, completion != nil { dismiss() }
        }
        .manageSubscriptionsSheet(isPresented: $managingSubscriptions)
        .onChange(of: managingSubscriptions) { _, isPresented in
            if !isPresented { Task { await commerce.refresh() } }
        }
        .interactiveDismissDisabled(purchasing || ads.isPresenting)
        .fullScreenCover(item: $ads.luckyReward, onDismiss: {
            if acknowledgedLuckyReward && requestedReward { dismiss() }
        }) { reward in
            LuckyRewardView(message: reward.message) {
                acknowledgedLuckyReward = true
                ads.luckyReward = nil
            }
                .presentationBackground(.clear)
        }
    }

    private var closeButton: some View {
        IconButton(symbol: .close, label: "Close", glass: true) {
            cancelRewardRequest()
            dismiss()
        }.disabled(purchasing || ads.isPresenting)
    }

    private func membershipHeader(wide: Bool, paneWidth: CGFloat) -> some View {
        let inlineArtwork = paneWidth >= 360
        let artworkHeight: CGFloat = verticalSizeClass == .compact ? 76 : (wide ? 126 : 104)
        let layout = inlineArtwork ? AnyLayout(HStackLayout(spacing: 12))
                                   : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            heroCopy
            if !typeSize.isAccessibilitySize {
                plusArtwork
                    .frame(width: wide ? 216 : 128, height: artworkHeight)
                    .frame(maxWidth: inlineArtwork ? nil : .infinity, alignment: .trailing)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 24), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Glamo Plus")
                .font(.glam(.title, weight: .semibold))
                .foregroundStyle(GlamoStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Glamo Plus")
                .accessibilityAddTraits(.isHeader)
            LocalizedText(requiredBenefit == .mediaExport
                          ? "Export is included with Plus."
                          : "Export and share from your video library.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("Member benefits")
                .font(.glam(.title3, weight: .semibold)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                benefit("MP4 export up to 1080p", detail: "Save a separate MP4 copy of your edits.", symbol: .edit)
                Divider().overlay(GlamoStyle.line)
                benefit("M4A audio export", detail: "Keep just the soundtrack as an M4A file.", symbol: .sound)
                Divider().overlay(GlamoStyle.line)
                benefit("Share files", detail: "Send an original file or an export to another app.", symbol: .driveShare)
            }
            .padding(.horizontal, 12)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
        }
    }

    private func benefit(_ title: String, detail: String, symbol: GlamoGlyph) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Glyph(symbol: symbol, size: 18, tint: GlamoStyle.accent)
                .frame(width: 30, height: 30)
                .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                LocalizedText(title)
                    .font(.glam(.subheadline, weight: .semibold))
                LocalizedText(detail)
                    .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var offerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if commerce.premium {
                activeMembership
            } else {
                LocalizedText("Choose your plan")
                    .font(.glam(.title3, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if rewardKind == .watch {
                    LocalizedText("Unlimited video views")
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                }
                if api.session == nil { ConnectionPanel() }
                if !plans.isEmpty { planPicker }
                if let error = commerce.plansError {
                    ErrorNote(message: error)
                    Button("Retry") { Task { await commerce.loadPlans() } }
                        .buttonStyle(CompactActionStyle()).disabled(interactionLocked)
                }
                if !plans.isEmpty || commerce.loadingPlans || commerce.loadingProducts || purchasing {
                    checkoutPanel
                }
            }
            if attemptedPurchaseAction {
                if let error = commerce.error { ErrorNote(message: error) }
                if let message = commerce.message {
                    LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.accent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                restoreLink
                PolicyLinks(compact: true)
            }
            .padding(.top, 4)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            ActionButton(title: "Manage subscription", primary: false) { managingSubscriptions = true }
                .disabled(interactionLocked)
                .padding(.top, 4)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
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

    private func planOption(_ product: SKProduct, sideBySide: Bool) -> some View {
        let selected = selectedPlan?.productIdentifier == product.productIdentifier
        let price = commerce.price(product)
        let period = commerce.period(product, locale: locale)
        let shape = RoundedRectangle(cornerRadius: 18)
        return Button { selectedID = product.productIdentifier } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: product.localizedTitle)
                    .font(.glam(.subheadline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: price).environment(\.layoutDirection, .leftToRight)
                    .font(.glam(.title, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selected ? GlamoStyle.accent : GlamoStyle.ink)
                    .fixedSize(horizontal: sideBySide, vertical: true)
                LocalizedText("Billed every %@", period).font(.glam(.footnote))
                    .foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if sideBySide || selected {
                    selectedLabel.opacity(selected ? 1 : 0)
                }
            }.padding(14)
                .frame(minWidth: sideBySide ? 124 : nil, maxWidth: .infinity,
                       minHeight: sideBySide ? 136 : 44, alignment: .topLeading)
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

    private var checkoutPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        return VStack(alignment: .leading, spacing: 0) {
            if let plan = selectedPlan {
                VStack(alignment: .leading, spacing: 6) {
                    selectedPlanPrice(plan)
                    renewalDisclosure
                }
                .padding(14)
            }
            purchaseAction
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .glamoGlass(in: shape, tint: GlamoStyle.paper)
    }

    private func selectedPlanPrice(_ plan: SKProduct) -> some View {
        let price = Text(verbatim: commerce.price(plan)).environment(\.layoutDirection, .leftToRight)
            .font(.glam(.headline)).monospacedDigit()
        let period = LocalizedText("Billed every %@", commerce.period(plan, locale: locale))
            .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                price
                period
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
                    Glyph(symbol: .back, size: 12, tint: GlamoStyle.onAccent).rotationEffect(.degrees(180))
                }
            }
            .foregroundStyle(canSubscribe ? GlamoStyle.onAccent : GlamoStyle.secondary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(minHeight: 52)
            .background(canSubscribe ? GlamoStyle.accent : GlamoStyle.raised)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
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

    private var rewardOption: some View {
        let eligible = quota.canRequestReward(for: .watch, premium: commerce.premium)
        return VStack(alignment: .leading, spacing: 12) {
            LocalizedText(eligible ? "Earn more with ads" : "Free plan").font(.glam(.headline))
            if eligible {
                LocalizedText(quota.rewardSummary(for: .watch)).font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                ActionButton(title: "Watch ad for views", primary: false) {
                    requestedReward = true
                    rewardTask = Task { await ads.watch(commerce: commerce, quota: quota, kind: .watch) }
                }.disabled(purchasing || ads.isPreparingAppOpen || ads.busy || ads.isPresenting)
            }
            if ads.busy {
                HStack(spacing: 12) {
                    Image("GlamoLoadingMark").resizable().scaledToFit().frame(width: 28, height: 5)
                        .phaseAnimator([false, true]) { mark, faded in
                            mark.opacity(reduceMotion || scenePhase != .active ? 1 : (faded ? 0.35 : 1))
                        } animation: { _ in
                            reduceMotion || scenePhase != .active ? nil : .easeInOut(duration: 0.6)
                        }
                        .accessibilityHidden(true)
                    LocalizedText("Loading ad…").font(.glam(.footnote))
                    Spacer(minLength: 12)
                    Button("Cancel") { cancelRewardRequest() }
                        .buttonStyle(CompactActionStyle())
                }
            }
            LocalizedText(quota.unlimited ? "Unlimited views today" : "\(quota.watchesLeft) views left today")
            AllowanceResetText()
            if !eligible {
                LocalizedText("Ad rewards are available once you run out of views.")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = ads.error { ErrorNote(message: error) }
            if let error = quota.error { ErrorNote(message: error) }
            if let message = ads.message {
                LocalizedText(message).font(.glam(.footnote)).foregroundStyle(GlamoStyle.accent)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glamoCard(radius: 18, fill: GlamoStyle.surface)
    }

    private func cancelRewardRequest() {
        rewardTask?.cancel()
        rewardTask = nil
        ads.cancelRewardLoading()
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
        let artworkHeight: CGFloat = verticalSizeClass == .compact ? 76 : 110
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Glamo Plus").font(.glam(.title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if typeSize.isAccessibilitySize {
                membershipDetail
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        membershipDetail.frame(width: 128, alignment: .leading)
                        Spacer(minLength: 0)
                        plusArtwork.frame(width: 156, height: artworkHeight)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        membershipDetail
                        plusArtwork.frame(maxWidth: 184, maxHeight: artworkHeight)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var membershipDetail: some View {
        LocalizedText(isMember ? "Plus is active" : "MP4 and M4A export")
            .font(.glam(.subheadline, weight: .semibold))
            .foregroundStyle(isMember ? GlamoStyle.accent : GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            LocalizedText(isMember ? "Manage membership" : "View plans")
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
            .sheet(isPresented: $paywall) { MembershipView() }
    }
}

struct LuckyRewardView: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    plusArtwork.frame(maxWidth: 144, maxHeight: 92)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.88)
                        .accessibilityHidden(true)
                    LocalizedText("Bonus added").font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                    LocalizedText("No ad is available right now. \(message)")
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    ActionButton(title: "Done", action: dismiss)
                }.padding(20).frame(maxWidth: 360)
                    .glamoCard(radius: 28)
                    .padding(24).frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }.background(Color.black.opacity(0.68).ignoresSafeArea())
            .accessibilityAddTraits(.isModal).interactiveDismissDisabled()
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { appeared = true } }
    }
}


struct AllowanceResetText: View {
    @Environment(\.locale) private var locale
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let next = QuotaStore.nextReset(after: context.date)
            LocalizedText("Resets %@ (local time)", localTime(next))
                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}
