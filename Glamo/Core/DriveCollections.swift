import Foundation
import Combine

// Landing-page endpoints use numeric or string IDs and sizes. Keep that wire
// representation separate from the persisted, user-owned library.
enum LandingValue: Decodable {
    case text(String), number(Double), flag(Bool), object([String: LandingValue]), array([LandingValue]), null
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .flag(value) }
        else if let value = try? box.decode(String.self) { self = .text(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try box.decode([Self].self)) }
    }
    var text: String {
        switch self {
        case .text(let value): value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value): value.isFinite && value.rounded() == value && abs(value) < Double(Int64.max) ? String(Int64(value)) : String(value)
        default: ""
        }
    }
    var number: Double { Double(text) ?? 0 }
    var object: [String: Self] { if case .object(let value) = self { return value }; return [:] }
    var flag: Bool? { if case .flag(let value) = self { return value }; return nil }
}

struct DriveCollection: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let coverURL: URL?
    let isFolder: Bool
    let clip: LessonClip?
    var sort: String = "1"
    var addedAt: Date? = nil
    static func linkID(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: #"\]\([^)]+\)"#, options: .regularExpression) {
            value = String(value[range].dropFirst(2).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let url = URLComponents(string: value), !url.path.isEmpty {
            return url.path.split(separator: "/").last.map(String.init) ?? value
        }
        return value
    }
    static func incomingLinkID(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let nested = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let value = URLComponents(string: nested),
              let segment = value.path.split(separator: "/", omittingEmptySubsequences: false).last,
              !segment.isEmpty else { return nil }
        return segment.count > 6 ? String(segment.dropFirst()) : String(segment)
    }
}

struct LandingResource: Decodable {
    let fields: [String: LandingValue]
    init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: LandingValue].self) }
    func collection(id requestedID: String? = nil, inheritedSort: String? = nil) -> DriveCollection? {
        let disk = fields["netDiskInfo"]?.object ?? fields
        let extra = fields["extraInfo"]?.object ?? [:]
        guard let folder = disk["isFolder"]?.flag else { return nil }
        let link = DriveCollection.linkID(disk["landingPage"]?.text ?? "")
        let rawID = disk["id"]?.text ?? ""
        let id = requestedID ?? ((fields["netDiskInfo"] != nil || folder) && !link.isEmpty ? link : rawID)
        guard !id.isEmpty else { return nil }
        let name = disk["name"]?.text.nilIfBlank ?? fields["folderName"]?.text.nilIfBlank
            ?? extra["channelName"]?.text.nilIfBlank ?? L10n.text("Untitled clip")
        let cover = folder
            ? (WebAddress.media(fields["shortCover"]?.text) ?? WebAddress.media(disk["shortCover"]?.text))
            : WebAddress.media(disk["coverImage"]?.text)
        var clip: LessonClip?
        if !folder {
            let originalURL = WebAddress.media(disk["originUrl"]?.text)
            guard let source = WebAddress.media(disk["fileUrl"]?.text)
                ?? WebAddress.media(disk["m3u8Url"]?.text) ?? originalURL else { return nil }
            let bytes = disk["fileSize"].flatMap { Int64($0.text) }
            clip = LessonClip(id: id, title: name, playbackURL: source, coverURL: cover,
                              shortLink: link.nilIfBlank ?? id, channel: extra["externalLinks"]?.text ?? "",
                              duration: disk["length"]?.number, originalURL: originalURL,
                              byteCount: bytes.flatMap { $0 > 0 ? $0 : nil })
        }
        let stamp = disk["createTime"]?.number ?? 0
        return DriveCollection(id: id, title: name, coverURL: cover, isFolder: folder, clip: clip,
                               sort: inheritedSort ?? extra["sortOrder"]?.text.nilIfBlank ?? "1",
                               addedAt: stamp > 0 ? Date(timeIntervalSince1970: stamp / 1000) : nil)
    }
}

struct LandingResourcePage: Decodable {
    let list: [LandingResource]
    let total: ServiceID?
}

@MainActor
final class DriveCollectionStore: ObservableObject {
    @Published private(set) var items: [DriveCollection] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    private(set) var page = 1
    private var generation = UUID()
    func load(_ collection: DriveCollection, api: APIClient, refresh: Bool = false) async {
        if refresh { generation = UUID(); page = 1; hasMore = true; loading = false }
        guard hasMore, !loading else { return }
        let token = generation
        let requestedPage = page
        loading = true; error = nil
        defer { if token == generation { loading = false } }
        do {
            let response = try await api.collectionPage(link: collection.id, page: requestedPage)
            try Task.checkCancellation()
            guard token == generation else { return }
            var seen = Set(requestedPage == 1 ? [] : items.map(\.id))
            let parsed = response.list.compactMap { $0.collection(inheritedSort: collection.sort) }
                .filter { seen.insert($0.id).inserted }
            if requestedPage == 1 {
                items = parsed.sorted { a, b in
                    if a.isFolder != b.isFolder { return a.isFolder }
                    if collection.sort == "2" { return (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast) }
                    if collection.sort == "3" { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
                    return false
                }
            } else {
                items += parsed
            }
            hasMore = !response.list.isEmpty && (response.total.flatMap { Int($0.value) }.map { requestedPage * 10 < $0 } ?? (response.list.count >= 10))
            page += 1
        } catch is CancellationError { }
        catch { if token == generation { self.error = error.localizedDescription } }
    }
}

@MainActor
extension LibraryStore {
    func refreshPackageCollections(_ links: [String], api: APIClient) async {
        let request = UUID()
        packageCollectionRequest = request
        let owner = api.session?.userId.value
        do {
            let items = try await api.packageCollections(links: links)
            try Task.checkCancellation()
            guard api.session?.userId.value == owner, packageCollectionRequest == request else { return }
            try updateLibrary { $0.packageCollections = items }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
