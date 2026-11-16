import SwiftUI
import StoreKit

struct MembershipView: View {
    enum RequiredBenefit {
        case mediaExport, rehearsalRecap
    }

    var rewardKind: AllowanceKind? = nil
    var requiredBenefit: RequiredBenefit? = nil
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
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
            let wide = container.size.width >= 740 && !typeSize.isAccessibilitySize && !hasReservedRegion(container)
            let pageWidth: CGFloat = wide ? 880 : 540
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            VStack(spacing: 0) {
                HStack { Spacer(minLength: 0); closeButton }
                    .pageHorizontalMargins().padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        membershipHeader
                        layout {
                            offerContent.frame(maxWidth: .infinity, alignment: .leading)
                            benefits.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if requiredBenefit == nil, !commerce.premium, api.session != nil {
                            rewardOption
                        }
                    }
                    .pageHorizontalMargins().padding(.bottom, 24)
                    .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                }
            }
        }
        .glamoScreenBackground()
        .task {
            async let rights: Void = commerce.refresh()
            await commerce.loadPlans()
            await rights
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

    private func hasReservedRegion(_ container: GeometryProxy) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        let bounds = CGRect(origin: .zero, size: container.size)
        let regions = container.reservedRegions(kind: .division) + container.reservedRegions(kind: .occlusion)
        return regions.contains { $0.isActive && bounds.intersects($0.frame) }
    }

    private var closeButton: some View {
        IconButton(symbol: .close, label: "Close", glass: true) {
            cancelRewardRequest()
            dismiss()
        }.disabled(purchasing || ads.isPresenting)
    }

    private var membershipHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Glamo Plus")
                .glamDisplay(42)
                .foregroundStyle(GlamoStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Glamo Plus")
                .accessibilityAddTraits(.isHeader)
            LocalizedText(heroSubtitle)
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var heroSubtitle: String {
        switch requiredBenefit {
        case .mediaExport: "Export is included with Plus."
        case .rehearsalRecap: "Share a recap with your time, mirror checks and notes."
        case nil: "Export video up to 1080p or save the audio as M4A."
        }
    }

    private var benefits: some View {
        let column: GridItem.Size = typeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 136)
        return VStack(alignment: .leading, spacing: 10) {
            LocalizedText("Member benefits")
                .font(.glam(.headline, editorial: true)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(column, spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
                benefit("MP4 export up to 1080p", symbol: .edit)
                benefit("M4A audio export", symbol: .sound)
                benefit("Skip launch ads", symbol: .home)
                benefit("Unlimited lesson views", symbol: .play)
                benefit("Unlimited downloads", symbol: .download)
                benefit("Share rehearsal recaps", symbol: .library)
            }
        }.padding(.horizontal, 4)
    }

    private func benefit(_ title: String, symbol: GlamoGlyph) -> some View {
        HStack(spacing: 8) {
            Glyph(symbol: symbol, size: 13, tint: GlamoStyle.accent)
                .frame(width: 28, height: 28)
                .background(GlamoStyle.paper, in: Circle())
            LocalizedText(title).font(.glam(.footnote, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var offerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if commerce.premium {
                activeMembership
            } else {
                LocalizedText("Choose your plan")
                    .font(.glam(.title3, weight: .semibold, editorial: true))
                    .accessibilityAddTraits(.isHeader)
                if api.session == nil { ConnectionPanel() }
                if !plans.isEmpty { planPicker }
                if let error = commerce.plansError {
                    ErrorNote(message: error)
                    Button("Retry") { Task { await commerce.loadPlans() } }
                        .buttonStyle(CompactActionStyle()).disabled(interactionLocked)
                }
                if !plans.isEmpty || commerce.loadingPlans || commerce.loadingProducts || purchasing {
                    if !plans.isEmpty { renewalDisclosure }
                    purchaseAction
                }
            }
            if attemptedPurchaseAction {
                if let error = commerce.error { ErrorNote(message: error) }
                if let message = commerce.message {
                    LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.accent)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                restoreLink
                PolicyLinks(compact: true)
            }
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
                .font(.glam(.title3, weight: .semibold, editorial: true))
                .foregroundStyle(GlamoStyle.accent).accessibilityAddTraits(.isHeader)
            if let expiration = commerce.expiration {
                let date = expiration.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                LocalizedText("Access through %@", date)
                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            }
            ActionButton(title: "Manage subscription", primary: false) { managingSubscriptions = true }
                .disabled(interactionLocked)
                .padding(.top, 4)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        return Button { selectedID = product.productIdentifier } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: product.localizedTitle)
                    .font(.glam(.footnote, weight: .semibold))
                    .foregroundStyle(selected ? GlamoStyle.accent : GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: price).environment(\.layoutDirection, .leftToRight)
                    .font(.glam(.title2, weight: .semibold, editorial: true))
                    .fixedSize(horizontal: sideBySide, vertical: true)
                LocalizedText("Billed every %@", period).font(.glam(.caption))
                    .foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if sideBySide || selected { selectedLabel.opacity(selected ? 1 : 0) }
            }.padding(11)
                .frame(minWidth: sideBySide ? 120 : nil, maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .foregroundStyle(GlamoStyle.ink)
                .glamoCard(radius: 15, fill: selected ? GlamoStyle.paper : GlamoStyle.background,
                           border: selected ? GlamoStyle.accent : GlamoStyle.line)
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(PressStyle()).disabled(interactionLocked)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("membership.plan.\(product.productIdentifier)")
    }

    private var selectedLabel: some View {
        LocalizedText("Selected").font(.glam(.caption, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(GlamoStyle.accent)
            .background(GlamoStyle.paperMuted, in: Capsule())
            .accessibilityHidden(true)
    }

    private var renewalDisclosure: some View {
        LocalizedText("Renews automatically. Cancel in your Apple account at least 24 hours before renewal.")
            .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var purchaseAction: some View {
        Button(action: subscribe) {
            HStack(spacing: 10) {
                LocalizedText(purchaseButtonTitle)
                if canSubscribe {
                    Glyph(symbol: .back, size: 12, tint: GlamoStyle.onAccent).rotationEffect(.degrees(180))
                }
            }.frame(minHeight: 28)
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

    private var rewardOption: some View {
        let eligible = (rewardKind.map { [$0] } ?? AllowanceKind.allCases)
            .filter { quota.canRequestReward(for: $0, premium: commerce.premium) }
        return VStack(alignment: .leading, spacing: 12) {
            LocalizedText(eligible.isEmpty ? "Free plan" : "Earn more with ads").font(.glam(.headline))
            ForEach(eligible) { kind in
                LocalizedText(quota.rewardSummary(for: kind)).font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                ActionButton(title: kind == .watch ? "Watch ad for views" : "Watch ad for downloads",
                             primary: false) {
                    requestedReward = true
                    rewardTask = Task { await ads.watch(commerce: commerce, quota: quota, kind: kind) }
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
            LocalizedText(quota.downloadsUnlimited ? "Unlimited downloads today" : "\(quota.downloadsLeft) downloads left today")
            AllowanceResetText()
            if eligible.isEmpty {
                LocalizedText("Ad rewards are available once you run out of views or downloads.")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = ads.error { ErrorNote(message: error) }
            if let error = quota.error { ErrorNote(message: error) }
            if let message = ads.message {
                LocalizedText(message).font(.glam(.footnote)).foregroundStyle(GlamoStyle.accent)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glamoCard()
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

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Glyph(symbol: .download, size: 18, tint: GlamoStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(GlamoStyle.paperMuted, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Glamo Plus").font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                    LocalizedText(isMember ? "Manage membership" : "MP4 and M4A export")
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 12, tint: GlamoStyle.accent)
                    .rotationEffect(.degrees(180))
            }
            .padding(13)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.surface, interactive: true)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
            .accessibilityElement(children: .combine)
    }
}

struct AccountView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @State private var paywall = false
    private var unavailable: Bool {
        accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPresenting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LocalizedText("Me").font(.glam(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                PlusEntry(isMember: commerce.premium) { paywall = true }
                    .disabled(unavailable)
                    .accessibilityIdentifier("account.membership")
                AccountSettingsSection()
                if let session = api.session {
                    accountIdentity(session.userId.value)
                    allowance
                } else {
                    ConnectionPanel()
                }
                LocalizedText("Version \(api.configuration.version)")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 4)
            }.glamoPage()
        }.glamoScreenBackground()
            .sheet(isPresented: $paywall) { MembershipView() }
    }

    private func accountIdentity(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LocalizedText("Account ID").font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
            Text(verbatim: id).font(.caption.monospaced()).foregroundStyle(GlamoStyle.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allowance: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LocalizedText(commerce.premium ? "Plus active" : "Daily limits").font(.glam(.headline))
                Spacer(minLength: 0)
                if !commerce.premium {
                    Button { paywall = true } label: {
                        LocalizedText("View options")
                    }.buttonStyle(CompactActionStyle()).disabled(unavailable)
                        .accessibilityLabel("View options for more views and downloads")
                }
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                balances
            }
            if !commerce.premium { AllowanceResetText() }
        }
        .padding(16)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 25), tint: GlamoStyle.paper)
    }

    @ViewBuilder private var balances: some View {
        balance(value: commerce.premium || quota.unlimited ? "Unlimited" : "\(quota.watchesLeft)", label: "Views left")
        balance(value: commerce.premium || quota.downloadsUnlimited ? "Unlimited" : "\(quota.downloadsLeft)", label: "Downloads left")
    }

    private func balance(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalizedText(value).font(value == "Unlimited" ? .headline : .title.weight(.semibold))
                .monospacedDigit().foregroundStyle(GlamoStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            LocalizedText(label).font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                    GlamArtwork(kind: .pouch, height: 108)
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
