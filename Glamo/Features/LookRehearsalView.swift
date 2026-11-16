import SwiftUI

private enum RehearsalSheet: Identifiable {
    case csv(URL), recap(String), membership
    var id: String {
        switch self {
        case .csv: "csv"
        case .recap: "recap"
        case .membership: "membership"
        }
    }
}

struct LookRehearsalEntry: View {
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalizedText("Look rehearsal").font(.glam(.headline))
                    LocalizedText("Time a look and track what needs a touch-up.").font(.glam(.subheadline))
                        .foregroundStyle(GlamoStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Glyph(symbol: .back, size: 14, tint: GlamoStyle.accent).rotationEffect(.degrees(180))
                    .frame(width: 44, height: 44)
                    .glamoGlass(in: Circle(), tint: GlamoStyle.paper)
            }
            .padding(.vertical, 12)
            .foregroundStyle(GlamoStyle.ink)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityIdentifier("rehearsal.open")
    }
}

struct LookRehearsalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var commerce: CommerceStore
    @StateObject private var journal = LookRehearsalJournal()
    @State private var area = LookArea.base
    @State private var lookName = ""
    @State private var checkNote = ""
    @State private var showingHistory = false
    @State private var selected: LookRehearsal?
    @State private var pendingRemoval: LookRehearsal?
    @State private var sheet: RehearsalSheet?
    @State private var recapTask: Task<Void, Never>?
    @State private var recapError: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Look rehearsal") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ChipFilter(values: ["Practice", "History"], selected: showingHistory ? "History" : "Practice") {
                        nameFocused = false
                        showingHistory = $0 == "History"
                    }
                    if let message = journal.storageMessage { ErrorNote(message: message) }
                    if !showingHistory, journal.active == nil {
                        LocalizedText("Start the timer and record each mirror check as you go. The recap shows your results and total time.")
                            .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                    }
                    if showingHistory { history } else { rehearse }
                }.glamoPage()
            }.scrollDismissesKeyboard(.interactively)
        }.glamoScreenBackground()
            .sheet(item: $selected) { session in details(session) }
    }

    @ViewBuilder private var rehearse: some View {
        if let session = journal.active {
            lookTitle(session)
                .font(.glam(.title2, editorial: true))
            LocalizedText("Pick an area and record what you see in the mirror.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ChipFilter(values: LookArea.allCases.map(\.label), selected: area.label) { label in
                if let match = LookArea.allCases.first(where: { $0.label == label }) { area = match }
            }
            summary(session)
            TextField("Touch-up note (optional)", text: $checkNote,
                      prompt: Text("Touch-up note (optional)").foregroundColor(GlamoStyle.secondary), axis: .vertical)
                .lineLimit(2...5).glamoField()
            LocalizedText("Mirror check").font(.glam(.headline))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(MirrorCheck.allCases) { result in
                    ActionButton(title: result.label, primary: result == .ready) {
                        if journal.record(result, for: area, note: checkNote) { checkNote = "" }
                    }.disabled(!journal.available)
                }
            }
            HStack {
                Button { journal.undoLastCheck() } label: { LocalizedText("Undo last check") }
                    .buttonStyle(CompactActionStyle()).disabled(session.checks.isEmpty)
                Spacer(minLength: 0)
            }
            ActionButton(title: "Finish rehearsal", primary: false) {
                journal.finish()
                if journal.active == nil {
                    checkNote = ""
                    showingHistory = !journal.completed.isEmpty
                }
            }
        } else {
            TextField("Look name (optional)", text: $lookName,
                      prompt: Text("Look name (optional)").foregroundColor(GlamoStyle.secondary))
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($nameFocused)
                .glamoField()
                .accessibilityIdentifier("rehearsal.lookName")
            ActionButton(title: "Start rehearsal") {
                nameFocused = false
                journal.begin(lookName: lookName)
                if journal.active != nil { lookName = ""; area = .base }
            }.disabled(!journal.available)
        }
        LocalizedText("Glamo stores the checks you enter on this device. It does not analyze your face or video.")
            .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var history: some View {
        if journal.completed.isEmpty {
            if journal.available {
                GlamoEmptyState(title: "No rehearsals yet",
                                message: "Finish a rehearsal to see it here.") {
                    ActionButton(title: journal.active == nil ? "Go to practice" : "Resume rehearsal") {
                        showingHistory = false
                    }
                }
            }
        } else {
            ForEach(journal.completed) { session in
                Button {
                    recapError = nil
                    selected = session
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            lookTitle(session)
                                .font(.glam(.headline)).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(session.startedAt, format: .dateTime.month().day().hour().minute().locale(locale))
                                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                        }
                        summary(session)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .glamoCard(radius: 20).contentShape(Rectangle())
                }.buttonStyle(PressStyle())
            }
        }
    }

    private func details(_ session: LookRehearsal) -> some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Rehearsal results") { selected = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    lookTitle(session)
                        .font(.glam(.title2, editorial: true))
                    Text(session.startedAt, format: .dateTime.year().month().day().hour().minute().locale(locale))
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                    summary(session)
                    areaBreakdown(session)
                    ForEach(session.checks) { check in
                        if let note = check.note {
                            VStack(alignment: .leading, spacing: 6) {
                                LocalizedText(check.area.label).font(.glam(.headline))
                                Text(verbatim: note).font(.glam(.subheadline))
                            }
                        }
                    }
                    ActionButton(title: commerce.premium ? "Share rehearsal recap" : "Share recap with Plus",
                                 busy: recapTask != nil) {
                        guard recapTask == nil else { return }
                        recapTask = Task {
                            await prepareRecap(for: session)
                            recapTask = nil
                        }
                    }.accessibilityIdentifier("rehearsal.shareRecap")
                    if let recapError { ErrorNote(message: recapError) }
                    ActionButton(title: "Export rehearsal CSV", primary: false) {
                        if let url = journal.export(session) { sheet = .csv(url) }
                    }
                    if let message = journal.storageMessage { ErrorNote(message: message) }
                    Button { pendingRemoval = session } label: { LocalizedText("Delete rehearsal") }
                        .buttonStyle(CompactActionStyle())
                }.glamoPage()
            }
        }.glamoScreenBackground()
            .onDisappear { recapTask?.cancel() }
            .sheet(item: $sheet) { destination in
                switch destination {
                case .csv(let url): ShareSheet(items: [url])
                case .recap(let text): ShareSheet(items: [text])
                case .membership: MembershipView(requiredBenefit: .rehearsalRecap)
                }
            }
            .fullScreenCover(item: $pendingRemoval) { session in
                AccountDecisionDialog(title: "Delete rehearsal?", message: "This deletes the rehearsal, checks and notes from this device.",
                    confirmTitle: "Delete rehearsal", destructive: true,
                    cancel: { pendingRemoval = nil }) {
                        journal.remove(session.id)
                        pendingRemoval = nil
                        if !journal.completed.contains(where: { $0.id == session.id }) { selected = nil }
                    }.presentationBackground(.clear)
            }
    }

    private func prepareRecap(for session: LookRehearsal) async {
        guard !Task.isCancelled else { return }
        recapError = nil
        if !commerce.hasVerifiedRightsForCurrentAccount, commerce.api.session != nil {
            await commerce.refresh()
        }
        guard selected?.id == session.id, sheet == nil, pendingRemoval == nil, !Task.isCancelled else { return }
        if commerce.hasVerifiedMembership {
            sheet = .recap(recap(for: session))
        } else if !commerce.hasVerifiedRightsForCurrentAccount, commerce.api.session != nil {
            recapError = "Connect to verify your Plus membership before sharing a recap."
        } else {
            sheet = .membership
        }
    }

    private func recap(for session: LookRehearsal) -> String {
        let language = AppLanguage.from(locale)
        let date = session.startedAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale))
        var lines = [L10n.text("Rehearsal recap", language: language),
                     session.lookName.nilIfBlank ?? L10n.text("Untitled look", language: language), date]
        if let duration = session.duration {
            lines.append("\(L10n.text("Time taken", language: language)) · \(durationText(duration))")
        }
        let count = session.checks.count.formatted(.number.locale(locale))
        let ready = session.readyCount.formatted(.number.locale(locale))
        lines.append("\(L10n.text("Party-ready", language: language)) · \(ready) / \(count)")
        for area in LookArea.allCases {
            let checks = session.checks.filter { $0.area == area }
            guard !checks.isEmpty else { continue }
            lines.append(contentsOf: ["", L10n.text(area.label, language: language)])
            for check in checks {
                let result = L10n.text(check.result.label, language: language)
                let note = check.note.map { " — \($0)" } ?? ""
                lines.append("• \(result)\(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // User-entered names stay verbatim; only the default title is translated.
    @ViewBuilder private func lookTitle(_ session: LookRehearsal) -> some View {
        if let name = session.lookName.nilIfBlank { Text(verbatim: name) }
        else { LocalizedText("Untitled look") }
    }

    private func summary(_ session: LookRehearsal) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { metrics(session) }
            VStack(alignment: .leading, spacing: 10) { metrics(session) }
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func metrics(_ session: LookRehearsal) -> some View {
        metric("Mirror checks", value: session.checks.count.formatted(.number.locale(locale)))
        metric("Party-ready", value: session.readyShare.map {
            $0.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        } ?? "—")
        if let duration = session.duration {
            metric("Time taken", value: durationText(duration))
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        Duration.seconds(duration)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(locale))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value).font(.glam(.title2, weight: .semibold)).monospacedDigit()
            LocalizedText(title).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func areaBreakdown(_ session: LookRehearsal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalizedText("By area").font(.glam(.headline))
            ForEach(LookArea.allCases) { area in
                let checks = session.checks.filter { $0.area == area }
                if !checks.isEmpty {
                    HStack {
                        LocalizedText(area.label)
                        Spacer(minLength: 8)
                        Text(verbatim: "\(checks.filter { $0.result.isReady }.count) / \(checks.count)")
                            .monospacedDigit()
                            .environment(\.layoutDirection, .leftToRight)
                    }.font(.glam(.subheadline))
                }
            }
            LocalizedText("Ready checks out of all checks for each area.")
                .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
        }
    }
}
