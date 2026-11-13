import Foundation
import Combine

// Manual look-rehearsal records. The person marks each mirror check themselves;
// nothing here analyses video or faces.

enum LookArea: String, Codable, CaseIterable, Identifiable {
    case base, eyes, brows, cheeks, lips, setting
    var id: String { rawValue }
    var label: String {
        switch self {
        case .base: "Base"
        case .eyes: "Eyes"
        case .brows: "Brows"
        case .cheeks: "Cheeks"
        case .lips: "Lips"
        case .setting: "Setting"
        }
    }
}

enum MirrorCheck: String, Codable, CaseIterable, Identifiable {
    case ready, needsBlending, uneven, redone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ready: "Party-ready"
        case .needsBlending: "Needs blending"
        case .uneven: "Sides uneven"
        case .redone: "Wiped and redid"
        }
    }
    var isReady: Bool { self == .ready }
}

struct LookCheck: Codable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let area: LookArea
    let result: MirrorCheck
    let note: String?
}

struct LookRehearsal: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    var lookName: String
    var checks: [LookCheck]
    var readyCount: Int { checks.filter { $0.result.isReady }.count }
    var readyShare: Double? { checks.isEmpty ? nil : Double(readyCount) / Double(checks.count) }
    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }
    var displayName: String { lookName.nilIfBlank ?? "Untitled look" }
}

private struct RehearsalArchive: Codable {
    var active: LookRehearsal?
    var completed: [LookRehearsal] = []
}

@MainActor
final class LookRehearsalJournal: ObservableObject {
    @Published private var archive = RehearsalArchive()
    @Published private(set) var storageMessage: String?
    private let archiveURL: URL
    private var storageReadable = true
    var active: LookRehearsal? { archive.active }
    var completed: [LookRehearsal] { archive.completed }
    var available: Bool { storageReadable }

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookRehearsals", isDirectory: true)
        archiveURL = folder.appendingPathComponent("rehearsals.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                archive = try JSONDecoder().decode(RehearsalArchive.self, from: Data(contentsOf: archiveURL))
            }
        } catch {
            storageReadable = false
            storageMessage = "Rehearsal records could not be opened. Existing records are preserved."
        }
    }

    func begin(lookName: String) {
        guard active == nil else { return }
        var next = archive
        let name = String(lookName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        next.active = LookRehearsal(id: UUID(), startedAt: Date(), lookName: name, checks: [])
        commit(next)
    }

    func record(_ result: MirrorCheck, for area: LookArea, note: String?) -> Bool {
        guard var session = active else { return false }
        session.checks.append(LookCheck(id: UUID(), recordedAt: Date(), area: area, result: result, note: note?.nilIfBlank))
        var next = archive
        next.active = session
        return commit(next)
    }

    func undoLastCheck() {
        guard var session = active, !session.checks.isEmpty else { return }
        session.checks.removeLast()
        var next = archive
        next.active = session
        commit(next)
    }

    func finish() {
        guard var session = active else { return }
        var next = archive
        if !session.checks.isEmpty {
            session.finishedAt = Date()
            next.completed.insert(session, at: 0)
        }
        next.active = nil
        commit(next)
    }

    func remove(_ id: UUID) {
        var next = archive
        next.completed.removeAll { $0.id == id }
        commit(next)
    }

    func export(_ session: LookRehearsal) -> URL? {
        // Stable English column names for spreadsheet interoperability.
        let dates = ISO8601DateFormatter()
        var lines = ["recorded_at_utc,look_name,area,mirror_check,note"]
        let name = Self.csvField(session.lookName)
        lines += session.checks.map {
            "\(dates.string(from: $0.recordedAt)),\(name),\($0.area.rawValue),\($0.result.rawValue),\(Self.csvField($0.note ?? ""))"
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RehearsalExports", isDirectory: true)
        let url = folder.appendingPathComponent("look-rehearsal-\(session.id.uuidString).csv")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
            return url
        } catch { storageMessage = "The rehearsal export could not be created. Please try again."; return nil }
    }

    // Quote user text and neutralise spreadsheet formula prefixes.
    static func csvField(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let first = value.first, "=+-@\t".contains(first) { value = "'" + value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    @discardableResult
    private func commit(_ next: RehearsalArchive) -> Bool {
        guard storageReadable else { return false }
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: archiveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            archive = next
            storageMessage = nil
            return true
        } catch {
            storageMessage = "This change could not be saved. Please try again."
            return false
        }
    }
}
