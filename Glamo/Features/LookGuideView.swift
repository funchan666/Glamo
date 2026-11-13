import SwiftUI

// Bundled editorial content. Reading never calls video, quota or advertising APIs.
private struct LookNote: Identifiable {
    struct Section {
        let title: String
        let body: String
        init(_ title: String, _ body: String) { self.title = title; self.body = body }
    }
    struct Source {
        let title: String
        let address: String
    }
    let id: String
    let category: String
    let title: String
    let summary: String
    let cover: GlamArt
    let sections: [Section]
    let takeaway: String
    let sources: [Source]

    // Original, evergreen technique notes. Safety points follow the linked FDA
    // consumer page (checked 2026-11-12); no product, brand or medical claims.
    static let all: [LookNote] = [
        LookNote(
            id: "base", category: "Base", title: "A base that lasts the night.",
            summary: "Thin layers, set only where you shine.", cover: .base,
            sections: [
                .init("Start with settled skin",
                      "Apply makeup to clean, moisturised skin and give skincare a few minutes to settle. Base products tend to sit more evenly on skin that is no longer damp."),
                .init("Build in thin layers",
                      "Start with a small amount where you want the most coverage, then blend outwards. A second thin layer usually looks more natural than one heavy layer."),
                .init("Set only where you need it",
                      "Powder helps where makeup tends to move, such as around the nose or across the forehead. Press it in with a puff or brush instead of dragging it across the skin.")
            ],
            takeaway: "Check your base by a window or in daylight before you add colour.",
            sources: []),
        LookNote(
            id: "eyes", category: "Eyes", title: "Eyes made for low light.",
            summary: "Shimmer where light lands, depth where it doesn’t.", cover: .eyes,
            sections: [
                .init("Place shimmer with intent",
                      "Party lighting is often dim and warm. Shimmer or metallic shades on the centre of the lid or the inner corner catch the light, while deeper matte shades in the crease add shape."),
                .init("Soften every edge",
                      "Where two shades meet, blend with a clean brush in small circles or short back-and-forth strokes. Soft edges look better in close-up photos."),
                .init("Finish with liner and lashes",
                      "Apply liner and mascara after eyeshadow so you can clean up any fallout first. If you wear strip lashes, trim the band to fit your eye before applying.")
            ],
            takeaway: "Check your eyes from arm’s length — the distance most people will see them from.",
            sources: []),
        LookNote(
            id: "lips", category: "Lips", title: "Lips that last past midnight.",
            summary: "Line, layer, blot, and plan one touch-up.", cover: .lips,
            sections: [
                .init("Line, then fill",
                      "A liner close to your lip colour defines the shape and can slow colour from moving. Lightly fill the lips with liner before adding lipstick."),
                .init("Layer and blot",
                      "Apply a thin layer, blot with a tissue, then apply again. Two thin layers usually wear longer than one thick coat."),
                .init("Pack for one touch-up",
                      "Food and drinks wear colour away. Carry the lip product you’re wearing and check a mirror after you eat.")
            ],
            takeaway: "Touch up with the same shade. A different colour over a worn one rarely matches.",
            sources: []),
        LookNote(
            id: "glow", category: "Glow", title: "Glow that photographs well.",
            summary: "Highlight the high points, then check under flash.", cover: .glow,
            sections: [
                .init("Find the high points",
                      "Highlighter usually goes where light naturally falls: the tops of the cheekbones, the bridge of the nose and the centre of the brow bone."),
                .init("Start with less",
                      "Apply a little, step back, then add more if you want it. Removing extra shine without disturbing your base is harder than adding it."),
                .init("Test with your camera",
                      "Phone flash and party lights can make shimmer and some powders look different from your mirror. Take one flash photo before you leave.")
            ],
            takeaway: "One flash photo at home saves surprises later.",
            sources: []),
        LookNote(
            id: "care", category: "Care", title: "Party-proof hygiene.",
            summary: "Small habits that protect your eyes and skin.", cover: .care,
            sections: [
                .init("Keep eye products to yourself",
                      "Don’t share eye makeup. If you try a store tester, use a fresh single-use applicator such as a clean cotton swab."),
                .init("Replace and store with care",
                      "Replace mascara every few months and throw it away once it dries out — never add water or saliva. Keep products away from heat, such as a parked car."),
                .init("Apply safely",
                      "Wash your hands and clean your tools before working near your eyes, and don’t apply or remove eye makeup in a moving vehicle. Stop using a product that irritates, and contact a healthcare provider if you have a bad reaction.")
            ],
            takeaway: "Lessons show technique. Always follow each product’s own label and directions.",
            sources: [.init(title: "FDA · Eye cosmetic safety", address: "https://www.fda.gov/cosmetics/cosmetic-products/eye-cosmetic-safety")])
    ]
}

// Shared entry point for Home and the Tools tab.
struct LookGuideEntry: View {
    var compact = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 18) {
                GlamCover(kind: .eyes)
                    .frame(width: compact ? 72 : 92, height: compact ? 88 : 112)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    LocalizedText("Party look notes").font(.glam(.headline))
                        .foregroundStyle(GlamoStyle.paper)
                    LocalizedText("\(LookNote.all.count) short reads · Available offline")
                        .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Glyph(symbol: .back, size: 12, tint: GlamoStyle.accent)
                    .rotationEffect(.degrees(180)).frame(width: 20)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background { GlamSurface(tone: .mauve, radius: 22) }
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityIdentifier("lookGuide.open")
    }
}

struct LookGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var category = "All"
    private let categories = ["All", "Base", "Eyes", "Lips", "Glow", "Care"]
    private var notes: [LookNote] {
        LookNote.all.filter { category == "All" || $0.category == category }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeading(title: "Party look notes") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ChipFilter(values: categories, selected: category) { category = $0 }
                        if let first = notes.first {
                            NavigationLink(value: first.id) {
                                VStack(alignment: .leading, spacing: 0) {
                                    GlamCover(kind: first.cover).aspectRatio(4 / 3, contentMode: .fit)
                                    VStack(alignment: .leading, spacing: 8) {
                                        LocalizedText(first.category).font(.glam(.caption, weight: .semibold))
                                            .foregroundStyle(GlamoStyle.paperSecondary)
                                        LocalizedText(first.title).font(.glam(.title2, editorial: true))
                                            .fixedSize(horizontal: false, vertical: true)
                                        LocalizedText(first.summary).font(.glam(.subheadline))
                                            .foregroundStyle(GlamoStyle.paperSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                }.foregroundStyle(GlamoStyle.ink)
                                    .background(GlamoStyle.paper)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    .contentShape(Rectangle())
                            }.buttonStyle(PressStyle()).accessibilityIdentifier("lookGuide.\(first.id)")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 150), spacing: 16)], alignment: .leading, spacing: 22) {
                            ForEach(Array(notes.dropFirst())) { note in
                                NavigationLink(value: note.id) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        GlamCover(kind: note.cover).aspectRatio(1, contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        LocalizedText(note.category).font(.glam(.caption, weight: .semibold))
                                            .foregroundStyle(GlamoStyle.accent)
                                        LocalizedText(note.title).font(.glam(.headline, editorial: true))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.foregroundStyle(GlamoStyle.paper).contentShape(Rectangle())
                                }.buttonStyle(PressStyle()).accessibilityIdentifier("lookGuide.\(note.id)")
                            }
                        }
                    }.glamoPage()
                }
            }.glamoScreenBackground().foregroundStyle(GlamoStyle.paper)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in
                    if let note = LookNote.all.first(where: { $0.id == id }) {
                        LookNoteReader(note: note)
                    }
                }
        }
    }
}

private struct LookNoteReader: View {
    let note: LookNote
    @Environment(\.dismiss) private var dismiss
    @State private var source: PolicyDocument?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconButton(symbol: .back, label: "Back to look notes") { dismiss() }
                LocalizedText(note.category).font(.glam(.subheadline, weight: .semibold))
                    .foregroundStyle(GlamoStyle.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    GlamCover(kind: note.cover).aspectRatio(4 / 3, contentMode: .fit)
                        .frame(maxWidth: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        LocalizedText(note.title)
                            .font(.glam(.title, editorial: true))
                            .foregroundStyle(GlamoStyle.paper).accessibilityAddTraits(.isHeader)
                            .fixedSize(horizontal: false, vertical: true)
                        LocalizedText(note.summary).font(.glam(.subheadline))
                            .foregroundStyle(GlamoStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(note.sections.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 10) {
                            LocalizedText(note.sections[index].title).font(.glam(.headline))
                                .accessibilityAddTraits(.isHeader)
                            LocalizedText(note.sections[index].body).font(.glam(.body)).lineSpacing(5)
                                .foregroundStyle(GlamoStyle.paper.opacity(0.92))
                                .textSelection(.enabled)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        LocalizedText("Before you head out").font(.glam(.subheadline, weight: .semibold))
                            .foregroundStyle(GlamoStyle.paperSecondary)
                        LocalizedText(note.takeaway).font(.glam(.title3, editorial: true)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(GlamoStyle.ink)
                        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background { GlamSurface(tone: .blush, radius: 22) }
                    if !note.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            LocalizedText("Further reading").font(.glam(.headline))
                            LocalizedText("Official source · Opens online")
                                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                            ForEach(note.sources, id: \.address) { reference in
                                if let url = URL(string: reference.address) {
                                    Button {
                                        source = PolicyDocument(title: reference.title, url: url)
                                    } label: {
                                        LocalizedText(reference.title).font(.glam(.subheadline, weight: .medium))
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }.foregroundStyle(GlamoStyle.accent).buttonStyle(PressStyle())
                                }
                            }
                        }
                    }
                }.glamoPage()
            }
        }.glamoScreenBackground().foregroundStyle(GlamoStyle.paper)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $source) { PolicyBrowser(document: $0) }
    }
}
