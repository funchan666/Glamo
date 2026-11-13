import SwiftUI

struct LookRehearsalEntry: View {
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    LocalizedText("Look rehearsal").font(.glam(.title3, weight: .semibold, editorial: true))
                    LocalizedText("Try a look before the night. Mark each mirror check.").font(.glam(.subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 14, tint: GlamoStyle.accent).rotationEffect(.degrees(180))
            }
            .foregroundStyle(GlamoStyle.paper)
            .padding(20).frame(maxWidth: .infinity, minHeight: 176, alignment: .bottomLeading)
            .background {
                GlamCover(kind: .rehearsal).overlay(GlamoStyle.background.opacity(0.35))
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityIdentifier("rehearsal.open")
    }
}

struct LookRehearsalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @StateObject private var journal = LookRehearsalJournal()
    @State private var area = LookArea.base
    @State private var lookName = ""
    @State private var checkNote = ""
    @State private var showingHistory = false
    @State private var selected: LookRehearsal?
    @State private var pendingRemoval: LookRehearsal?
    @State private var sharedExport: SharedFile?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Look rehearsal") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GlamCover(kind: .rehearsal).aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    ChipFilter(values: ["Rehearse", "History"], selected: showingHistory ? "History" : "Rehearse") {
                        nameFocused = false
                        showingHistory = $0 == "History"
                    }
                    if let message = journal.storageMessage { ErrorNote(message: message) }
                    if showingHistory { history } else { rehearse }
                }.glamoPage()
            }.scrollDismissesKeyboard(.interactively)
        }.foregroundStyle(GlamoStyle.paper).glamoScreenBackground()
            .sheet(item: $selected) { session in details(session) }
    }

    @ViewBuilder private var rehearse: some View {
        if let session = journal.active {
            lookTitle(session)
                .font(.glam(.title2, editorial: true))
            LocalizedText("Pick the area you just worked on, look in the mirror, then mark how it looks.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ChipFilter(values: LookArea.allCases.map(\.label), selected: area.label) { label in
                if let match = LookArea.allCases.first(where: { $0.label == label }) { area = match }
            }
            summary(session)
            TextField("Touch-up note (optional)", text: $checkNote, axis: .vertical)
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
            LocalizedText("Rehearse the look before the party.").font(.glam(.title2, editorial: true))
                .fixedSize(horizontal: false, vertical: true)
            LocalizedText("Name the look, start the timer, and mark each area as you check it in the mirror. You’ll see which steps need practice and how long the whole look takes.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(LocalizedStringKey("Look name (optional)"), text: $lookName)
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
        LocalizedText("Records are kept on this device and come only from what you mark. Glamo does not analyse your face or video.")
            .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var history: some View {
        if journal.completed.isEmpty {
            LocalizedText("No rehearsals yet.").font(.glam(.headline))
            LocalizedText("Finished rehearsals appear here with their mirror checks and time taken.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
        } else {
            ForEach(journal.completed) { session in
                Button { selected = session } label: {
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
                        .background { GlamSurface(tone: .mauve, radius: 20) }.contentShape(Rectangle())
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
                    ActionButton(title: "Export rehearsal CSV", primary: false) {
                        if let url = journal.export(session) { sharedExport = SharedFile(url: url) }
                    }
                    if let message = journal.storageMessage { ErrorNote(message: message) }
                    Button { pendingRemoval = session } label: { LocalizedText("Delete rehearsal") }
                        .buttonStyle(CompactActionStyle())
                }.glamoPage()
            }
        }.glamoScreenBackground().foregroundStyle(GlamoStyle.paper)
            .sheet(item: $sharedExport) { ShareSheet(items: [$0.url]) }
            .fullScreenCover(item: $pendingRemoval) { session in
                AccountDecisionDialog(title: "Delete rehearsal?", message: "This removes the rehearsal and all of its mirror checks from this device.",
                    confirmTitle: "Delete rehearsal", destructive: true,
                    cancel: { pendingRemoval = nil }) {
                        journal.remove(session.id)
                        pendingRemoval = nil
                        if !journal.completed.contains(where: { $0.id == session.id }) { selected = nil }
                    }.presentationBackground(.clear)
            }
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
            metric("Time taken", value: Duration.seconds(duration)
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale)))
        }
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
            LocalizedText("Party-ready checks / all checks for that area.")
                .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
        }
    }
}
