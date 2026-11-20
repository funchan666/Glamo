import SwiftUI
import StoreKit
import UIKit

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
            let compact = verticalSizeClass == .compact || paneHeight < 680
            let pageWidth: CGFloat = wide ? 880 : 560
            let benefitsFirst = !commerce.premium && requiredBenefit != .unlimitedViewing
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: compact ? 12 : 24))
            let feedback = attemptedPurchaseAction ? (commerce.error ?? commerce.message) : nil
            VStack(spacing: 0) {
                closeButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DriveStyle.pageInset)
                    .padding(.top, compact ? 0 : 8)
                    .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    .background(DriveStyle.background, ignoresSafeAreaEdges: [.horizontal, .top])
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: compact ? 12 : 24) {
                            membershipHeader
                            layout {
                                if benefitsFirst {
                                    benefits.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                                }
                                offerContent(compact: compact)
                                if !benefitsFirst {
                                    benefits.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                cloudAvailability
                                if !commerce.premium, selectedPlan != nil { renewalDisclosure }
                                purchaseFeedback
                                    .id("membership.purchaseFeedback")
                                supportLinks
                            }
                            .padding(.horizontal, 2)
                        }
                        .padding(.horizontal, DriveStyle.pageInset)
                        .padding(.top, compact ? 2 : 24).padding(.bottom, 12)
                        .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomBar(pageWidth: pageWidth, compact: paneHeight < 470 && paneWidth >= 300)
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
        LocalizedText(commerce.premium ? "Ecloud Plus" : "Get Premium")
            .driveFont(30, relativeTo: .title, weight: .bold)
            .accessibilityAddTraits(.isHeader)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 0) {
            benefit("Up to 10 TB of cloud storage", symbol: .driveFolder)
            benefit("Ad-free", symbol: .close)
            benefit("Preview unsaved shared photos and videos", symbol: .play)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .driveGlassCard()
    }

    private var cloudAvailability: some View {
        LocalizedText("Cloud storage and previews of unsaved shared files will be available when the cloud drive launches.")
            .driveFont(12, relativeTo: .caption)
            .foregroundStyle(DriveStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func benefit(_ title: String, symbol: GlamoGlyph) -> some View {
        HStack(spacing: 10) {
            Glyph(symbol: symbol, size: 17, tint: DriveStyle.ink)
                .frame(width: 22, height: 22)
            LocalizedText(title)
                .driveFont(14, relativeTo: .subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 32)
    }

    private func offerContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if commerce.premium {
                activeMembership
            } else {
                if api.session == nil { ConnectionPanel() }
                if !plans.isEmpty {
                    planPicker(compact: compact)
                } else if commerce.loadingPlans || commerce.loadingProducts {
                    AccountLoadingIndicator(title: "Loading prices…")
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .driveGlassCard()
                }
                if let error = commerce.plansError {
                    ErrorNote(message: error)
                    Button {
                        Task { await commerce.loadPlans() }
                    } label: {
                        LocalizedText("Reload plans")
                    }.buttonStyle(CompactActionStyle()).disabled(interactionLocked)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var purchaseFeedback: some View {
        if attemptedPurchaseAction {
            if let error = commerce.error {
                ErrorNote(message: error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let message = commerce.message {
                Group {
                    if commerce.busy && message == "Restoring purchases…" {
                        AccountLoadingIndicator(title: message)
                    } else {
                        LocalizedText(message)
                            .driveFont(15, relativeTo: .subheadline, weight: .medium)
                            .foregroundStyle(DriveStyle.link)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .driveGlassCard()
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

    private func planPicker(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 24) {
            ForEach(plans, id: \.productIdentifier) { plan in
                planOption(plan)
            }
        }
    }

    private func planCopy(_ product: SKProduct) -> (duration: String, billing: String) {
        let language = AppLanguage.from(locale)
        if let period = product.subscriptionPeriod, period.numberOfUnits == 1 {
            switch period.unit {
            case .month:
                return (L10n.text("month", language: language), L10n.text("Billed monthly", language: language))
            case .year:
                return (L10n.text("year", language: language), L10n.text("Billed yearly", language: language))
            default:
                break
            }
        }
        let duration = commerce.period(product, locale: locale)
        let billing = duration.isEmpty ? product.localizedTitle : L10n.format("Billed every %@", [duration], language: language)
        return (duration, billing)
    }

    private func planOption(_ product: SKProduct) -> some View {
        let selected = selectedPlan?.productIdentifier == product.productIdentifier
        let price = commerce.price(product)
        let copy = planCopy(product)
        let shape = RoundedRectangle(cornerRadius: DriveStyle.cardRadius)

        return Button { selectedID = product.productIdentifier } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: copy.duration.isEmpty ? price : "\(price)/\(copy.duration)")
                        .driveFont(16, relativeTo: .body, weight: .medium)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: copy.billing)
                        .driveFont(12, relativeTo: .caption)
                        .foregroundStyle(DriveStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Circle().strokeBorder(selected ? DriveStyle.accent : DriveStyle.secondary.opacity(0.55),
                                      lineWidth: selected ? 5 : 1)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .foregroundStyle(DriveStyle.ink)
            .glamoGlass(in: shape, tint: .white)
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
        let layout = compact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 16))
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
                    .driveFont(18, relativeTo: .body, weight: .semibold)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(DriveStyle.ink)
                    .glamoGlass(in: Capsule(), tint: .white, interactive: true)
                    .contentShape(Capsule())
            }.buttonStyle(PressStyle()).disabled(purchasing || ads.isPresenting)
        }
        .padding(.horizontal, 16)
        .padding(.top, compact ? 10 : 20).padding(.bottom, compact ? 6 : 10)
        .frame(maxWidth: pageWidth).frame(maxWidth: .infinity)
        .background(DriveStyle.background, ignoresSafeAreaEdges: [.horizontal, .bottom])
        .overlay(alignment: .top) {
            GlamoStyle.line.frame(height: 1).allowsHitTesting(false).accessibilityHidden(true)
        }
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
                .driveFont(14, relativeTo: .footnote, weight: .semibold)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(DriveStyle.link)
                .glamoGlass(in: Capsule(), tint: GlamoStyle.paper,
                            interactive: true, mediaBackdrop: true)
                .contentShape(Capsule())
        }.buttonStyle(PressStyle())
            .accessibilityLabel("Ecloud Plus")
            .accessibilityHint(LocalizedStringKey(isMember ? "Manage membership" : "View plans"))
    }
}

private var plusArtwork: some View {
    Image("DrivePlusArtwork").resizable().interpolation(.high).scaledToFit()
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false).accessibilityHidden(true)
}

struct AccountView: View {
    @Environment(\.driveBottomOverlayInset) private var bottomOverlayInset
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var deviceCapacity: Int64?
    @State private var deviceAvailable: Int64?
    @State private var measuredFileBytes: Int64?
    @State private var copiedAccountID = false
    @State private var paywall = false
    @State private var storagePresented = false
    let showActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DrivePageTitle(title: "Profile")
                .padding(.horizontal, DriveStyle.pageInset + 4)
                .frame(minHeight: 44, alignment: .leading)
                .padding(.top, 4)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    identity
                    VStack(spacing: 0) {
                        librarySummary
                        Divider().overlay(GlamoStyle.line).padding(.horizontal, 16)
                        plusEntry
                    }
                    .driveGlassCard()
                    AccountSettingsSection(showActivity: showActivity)
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.top, 24).padding(.bottom, 24 + bottomOverlayInset)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .driveScreenBackground()
        .task(id: storageRevision) { await refreshStorage() }
        .task(id: copiedAccountID) {
            guard copiedAccountID else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedAccountID = false
        }
        .onDisappear { copiedAccountID = false }
        .onChange(of: api.session?.userId.value) { _, _ in copiedAccountID = false }
        .fullScreenCover(isPresented: $paywall) { MembershipView() }
        .driveDialog(isPresented: $storagePresented, maxWidth: 460, height: 580) { StorageManagementSheet() }
    }

    @ViewBuilder private var identity: some View {
        if let id = api.session?.userId.value, !id.isEmpty {
            Button {
                UIPasteboard.general.string = id
                copiedAccountID = true
            } label: {
                identityCard(accountID: id)
            }
            .buttonStyle(PressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LocalizedStringKey(copiedAccountID ? "Account ID copied" : "Copy account ID"))
            .accessibilityValue(Text(verbatim: id))
        } else {
            identityCard(accountID: nil)
        }
    }

    private func identityCard(accountID: String?) -> some View {
        let name = Group {
            if let accountID { LocalizedText("User %@", accountID) }
            else { Text(verbatim: "Ecloud") }
        }
        .driveFont(16, relativeTo: .subheadline, weight: .medium)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        .truncationMode(.middle)
        let badge = Text(verbatim: "Plus")
            .driveFont(10, relativeTo: .caption2, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(DriveStyle.accent, in: RoundedRectangle(cornerRadius: 3))
        return HStack(spacing: 16) {
            DriveProfileAvatar(size: 60)
            VStack(alignment: .leading, spacing: 3) {
                if commerce.premium {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            name
                            badge
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            name
                            badge
                        }
                    }
                } else {
                    name
                }
                if let accountID {
                    Group {
                        if copiedAccountID { LocalizedText("Copied") }
                        else { LocalizedText("Account ID · %@", accountID) }
                    }
                    .driveFont(12, relativeTo: .caption)
                    .foregroundStyle(DriveStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if accountID != nil { disclosureChevron }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .foregroundStyle(DriveStyle.ink)
        .driveGlassCard()
        .contentShape(RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
    }

    private var localBytes: Int64? {
        library.movies.isEmpty && library.savedVideos.isEmpty ? 0 : measuredFileBytes
    }
    private var storageRevision: [String] {
        library.movies.map { $0.id.uuidString } + library.savedVideos.map { "\($0.id):\($0.state.rawValue)" }
    }

    private func refreshStorage() async {
        let revision = storageRevision
        let files = library.movies.map { library.url(for: $0) }
            + library.savedVideos.filter { $0.state == .ready }.compactMap { library.offlineURL(for: $0) }
        let result = await Task.detached(priority: .utility) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let capacity = try? documents?.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let sizes = files.map { MediaStorageSize.bytes(at: $0) }
            let bytes: Int64? = sizes.allSatisfy { $0 != nil } ? sizes.compactMap { $0 }.reduce(0, +) : nil
            return (bytes, capacity?.volumeTotalCapacity.map(Int64.init), capacity?.volumeAvailableCapacityForImportantUsage)
        }.value
        guard !Task.isCancelled, revision == storageRevision else { return }
        measuredFileBytes = result.0
        deviceCapacity = result.1
        deviceAvailable = result.2
    }

    private var librarySummary: some View {
        let count = library.movies.count + library.folders.count + library.favorites.count
        let size = localBytes
        let heading = LocalizedText("File storage").driveFont(16, relativeTo: .subheadline, weight: .medium)
        let usage = Group {
            if let size { Text(verbatim: size.formatted(.byteCount(style: .file).locale(locale))) }
            else { LocalizedText("Calculating…") }
        }.driveFont(14, relativeTo: .footnote).monospacedDigit().foregroundStyle(DriveStyle.secondary)
        return Button { storagePresented = true } label: {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        heading.fixedSize()
                        storageMeter.frame(width: 70)
                        Spacer(minLength: 0)
                        usage.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        heading
                        usage
                        storageMeter.frame(width: 70)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                disclosureChevron
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .foregroundStyle(DriveStyle.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(storageDetails(itemCount: count))
    }

    @ViewBuilder private var storageMeter: some View {
        if let localBytes, let deviceCapacity, deviceCapacity > 0 {
            DriveMeter(value: Double(localBytes) / Double(deviceCapacity),
                       tint: Color(red: 0.18, green: 0.78, blue: 0.35), thickness: 8)
        }
    }

    private var disclosureChevron: some View {
        Glyph(symbol: .back, size: 10, tint: DriveStyle.secondary)
            .rotationEffect(.degrees(layoutDirection == .rightToLeft ? 0 : 180))
            .frame(width: 20, height: 24)
            .accessibilityHidden(true)
    }

    private func storageDetails(itemCount: Int) -> Text {
        let language = AppLanguage.from(locale)
        let count = L10n.format(itemCount == 1 ? "%@ item" : "%@ items",
                                [itemCount.formatted(.number.locale(locale))], language: language)
        if let deviceAvailable {
            let free = L10n.format("%@ free on this device", [deviceAvailable.formatted(.byteCount(style: .file).locale(locale))], language: language)
            return Text(verbatim: "\(count). \(free)")
        }
        return Text(verbatim: count)
    }

    private var plusEntry: some View {
        let description = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Ecloud Plus").driveFont(16, relativeTo: .subheadline, weight: .medium)
            LocalizedText(commerce.premium ? "Plus is active" : "Ad-free")
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
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct WatchLimitPrompt: View {
    @Binding var showingMembership: Bool
    var kind: AllowanceKind = .watch
    let finish: () -> Void
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var rewardTask: Task<Void, Never>?
    @State private var requestedReward = false
    @State private var previousCompletion: UUID?

    private var eligibleForAd: Bool {
        quota.canRequestReward(for: kind, premium: commerce.premium)
    }
    private var isLoadingAd: Bool { rewardTask != nil || ads.busy }
    private var actionsLocked: Bool { isLoadingAd || ads.isPresenting || ads.isPreparingAppOpen || showingMembership }
    private var bonus: LuckyRewardNotice? { requestedReward ? ads.luckyReward : nil }
    private var title: String {
        if bonus != nil { return "Bonus added" }
        if kind == .collect { return "Daily saving limit reached" }
        return eligibleForAd ? "Daily viewing limit reached" : "Playback unavailable"
    }

    var body: some View {
        DriveFloatingDialog { card }
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
                    choice(isLoadingAd ? "Loading ad…" : kind == .watch ? "Watch ad for views" : "Watch ad to save more",
                           detail: eligibleForAd ? quota.rewardSummary(for: kind) : "Rewards are unavailable.",
                           primary: true, action: startAd)
                        .disabled(!eligibleForAd || actionsLocked || commerce.busy || commerce.preparingPurchase)
                        .accessibilityIdentifier("watchLimit.watchAd")
                    if requestedReward, !actionsLocked {
                        if let error = ads.error { ErrorNote(message: error) }
                        else if let message = ads.message { caption(message) }
                        else if eligibleForAd { caption("Rewards are unavailable.") }
                    }
                }
                choice("Get Plus", detail: "View plans", primary: false) { showingMembership = true }
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
            await ads.watch(commerce: commerce, quota: quota, kind: kind)
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
