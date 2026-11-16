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
            id: "base", category: "Base", title: "Base makeup for a night out",
            summary: "Build coverage in thin layers and set where makeup moves.", cover: .base,
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
            id: "eyes", category: "Eyes", title: "Eye makeup for dim light",
            summary: "Use shimmer on the lid and matte shadow in the crease.", cover: .eyes,
            sections: [
                .init("Place shimmer with intent",
                      "Party lighting is often dim and warm. Shimmer or metallic shades on the centre of the lid or the inner corner catch the light, while deeper matte shades in the crease add shape."),
                .init("Soften every edge",
                      "Where two shades meet, blend with a clean brush in small circles or short back-and-forth strokes. Soft edges look better in close-up photos."),
                .init("Finish with liner and lashes",
                      "Apply liner and mascara after eyeshadow so you can clean up any fallout first. If you wear strip lashes, trim the band to fit your eye before applying.")
            ],
            takeaway: "Check your eyeshadow from arm’s length.",
            sources: []),
        LookNote(
            id: "lips", category: "Lips", title: "Lipstick that wears longer",
            summary: "Apply thin layers and keep your shade handy for a touch-up.", cover: .lips,
            sections: [
                .init("Line, then fill",
                      "A liner close to your lip colour defines the shape and can slow colour from moving. Lightly fill the lips with liner before adding lipstick."),
                .init("Layer and blot",
                      "Apply a thin layer, blot with a tissue, then apply again. Two thin layers usually wear longer than one thick coat."),
                .init("Pack for one touch-up",
                      "Food and drinks wear colour away. Carry the lip product you’re wearing and check a mirror after you eat.")
            ],
            takeaway: "Use the same shade when you touch up after eating.",
            sources: []),
        LookNote(
            id: "glow", category: "Glow", title: "Highlighter for flash photos",
            summary: "Add light to cheekbones and check how it looks on camera.", cover: .glow,
            sections: [
                .init("Find the high points",
                      "Highlighter usually goes where light naturally falls: the tops of the cheekbones, the bridge of the nose and the centre of the brow bone."),
                .init("Start with less",
                      "Apply a little, step back, then add more if you want it. Removing extra shine without disturbing your base is harder than adding it."),
                .init("Test with your camera",
                      "Phone flash and party lights can make shimmer and some powders look different from your mirror. Take one flash photo before you leave.")
            ],
            takeaway: "Take a flash photo before you leave.",
            sources: []),
        LookNote(
            id: "care", category: "Care", title: "Makeup hygiene",
            summary: "Keep eye makeup and applicators clean.", cover: .care,
            sections: [
                .init("Keep eye products to yourself",
                      "Don’t share eye makeup. If you try a store tester, use a fresh single-use applicator such as a clean cotton swab."),
                .init("Replace and store with care",
                      "Replace mascara every few months. Throw away dried mascara. Keep water and saliva out of the tube and store makeup away from heat."),
                .init("Apply safely",
                      "Wash your hands and clean your tools before working near your eyes, and don’t apply or remove eye makeup in a moving vehicle. Stop using a product that irritates, and contact a healthcare provider if you have a bad reaction.")
            ],
            takeaway: "Follow the directions on each product label.",
            sources: [.init(title: "FDA · Eye cosmetic safety", address: "https://www.fda.gov/cosmetics/cosmetic-products/eye-cosmetic-safety")])
    ]
}

// Shared entry point for Home and the Tools tab.
struct LookGuideEntry: View {
    let open: () -> Void
    @Environment(\.locale) private var locale
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalizedText("Makeup guides").font(.glam(.headline))
                    LocalizedText("%@ guides · Read offline", LookNote.all.count.formatted(.number.locale(locale)))
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Glyph(symbol: .back, size: 14, tint: GlamoStyle.accent)
                    .rotationEffect(.degrees(180)).frame(width: 44, height: 44)
                    .glamoGlass(in: Circle(), tint: GlamoStyle.paper)
            }.padding(.vertical, 12)
                .foregroundStyle(GlamoStyle.ink)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityIdentifier("lookGuide.open")
    }
}

struct LookGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category = "All"
    @State private var path: [String] = []
    private let categories = ["All", "Base", "Eyes", "Lips", "Glow", "Care"]

    private var notes: [LookNote] {
        LookNote.all.filter { category == "All" || $0.category == category }
    }
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                SheetHeading(title: "Makeup guides") { dismiss() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ChipFilter(values: categories, selected: category) { category = $0 }
                        ForEach(notes) { note in
                            NavigationLink(value: note.id) {
                                HStack(spacing: 12) {
                                    GlamCover(kind: note.cover)
                                        .frame(width: 68, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                    LocalizedText(note.title).font(.glam(.headline))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Glyph(symbol: .back, size: 11, tint: GlamoStyle.secondary)
                                        .rotationEffect(.degrees(180))
                                }.foregroundStyle(GlamoStyle.ink).contentShape(Rectangle())
                            }.buttonStyle(PressStyle()).accessibilityIdentifier("lookGuide.\(note.id)")
                        }
                    }.glamoPage()
                }
            }.glamoScreenBackground()
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
                IconButton(symbol: .back, label: "Back to makeup guides", glass: true) { dismiss() }
                LocalizedText(note.category).font(.glam(.subheadline, weight: .semibold))
                    .foregroundStyle(GlamoStyle.secondary)
                Spacer(minLength: 0)
            }.pageHorizontalMargins().padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    GlamCover(kind: note.cover).aspectRatio(1.56, contentMode: .fit)
                        .frame(maxHeight: 390)
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 10) {
                            LocalizedText(note.title)
                                .font(.glam(.title, weight: .semibold))
                                .foregroundStyle(GlamoStyle.ink).accessibilityAddTraits(.isHeader)
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
                                    .foregroundStyle(GlamoStyle.ink)
                                    .textSelection(.enabled)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            LocalizedText("Before you head out").font(.glam(.subheadline, weight: .semibold))
                                .foregroundStyle(GlamoStyle.secondary)
                            LocalizedText(note.takeaway).font(.glam(.title3, editorial: true)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }.foregroundStyle(GlamoStyle.ink)
                            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                            .glamoCard(radius: 22, fill: GlamoStyle.paper)
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
            }
        }.glamoScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $source) { PolicyBrowser(document: $0) }
    }
}
