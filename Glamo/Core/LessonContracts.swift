import Foundation

struct APIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: Value?
}

// The service returns some identifiers as either JSON numbers or strings.
struct ServiceID: Codable, Hashable {
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let string = try? box.decode(String.self) { value = string }
        else { value = String(try box.decode(Int64.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(value)
    }
}

struct VisitorSession: Codable {
    let accessToken: String
    let userId: ServiceID
    let domainId: ServiceID?
    let shortLink: String?
}

struct ReleaseConfiguration: Decodable {
    struct LandingLinks: Decodable { let us: [String]? }
    var NB01: Bool?
    var ios: IOSBillingConfiguration?
    var quotaConfig: QuotaConfiguration?
    var adList: [AdConfiguration]?
    var lcList: LandingLinks?
}
struct LessonFeedPage: Decodable {
    let feedId: String?
    let nextCursor: String?
    let hasMore: Bool
    let list: [RecommendedLesson]
    static let empty = LessonFeedPage(feedId: nil, nextCursor: nil, hasMore: false, list: [])
}
struct RecommendedLesson: Decodable {
    let videoId: ServiceID
    let shortLink: String?
    let m3u8Url: String
    let videoName: String?
    let coverUrl: String?
    var clip: LessonClip? {
        guard !videoId.value.isEmpty, let url = WebAddress.media(m3u8Url) else { return nil }
        return LessonClip(id: videoId.value, title: videoName?.nilIfBlank ?? "Untitled clip", playbackURL: url,
                    coverURL: WebAddress.media(coverUrl), shortLink: shortLink, channel: "", duration: nil)
    }
}
struct LessonClip: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    let playbackURL: URL
    let coverURL: URL?
    let shortLink: String?
    let channel: String
    let duration: Double?
    var isDirect: Bool? = nil
    var originalURL: URL? = nil
}
struct LessonLinkVisit: Codable, Identifiable {
    let id: UUID
    let link: String
    let title: String
    let date: Date
}
struct PracticeRecording: Codable, Identifiable, Hashable {
    let id: UUID
    let filename: String
    var title: String
    let date: Date
    let isExport: Bool
    var folderID: UUID? = nil
    var byteCount: Int64? = nil
    var duration: Double? = nil
    var viewing: FileViewingPosition? = nil
    var lastSharedAt: Date? = nil
    var isFavorite: Bool? = nil
    var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
    var isAudio: Bool { fileExtension == "m4a" }
    var displayName: String {
        guard !fileExtension.isEmpty, (title as NSString).pathExtension.lowercased() != fileExtension else { return title }
        return title + "." + fileExtension
    }
}
struct VideoFolder: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var parentID: UUID?
}
struct FileViewingPosition: Codable, Hashable {
    let date: Date
    let seconds: Double
    let duration: Double
}
struct LessonLibrarySnapshot: Codable {
    var favorites: [LessonClip] = []
    var history: [LessonLinkVisit] = []
    var movies: [PracticeRecording] = []
    var folders: [VideoFolder]? = nil
    // Optional additions preserve libraries written by previous app versions.
    var savedVideos: [SavedVideo]? = nil
    var remotePlayback: [RemotePlaybackRecord]? = nil
    var packageCollections: [DriveCollection]? = nil
    var playbackHistoryClearedAt: Date? = nil
}
// Separate scroll occurrence from video identity: a new recommendation round may
// repeat a lesson without sharing AVPlayer state or charging it again.
struct PlaybackQueueEntry: Identifiable, Equatable {
    let id: String
    let clip: LessonClip
}
enum WebAddress {
    static func media(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}
extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

struct IOSBillingConfiguration: Codable {
    let iosVerifyShareKey: String?
    let sandBoxTest: Bool?
    static let empty = IOSBillingConfiguration(iosVerifyShareKey: nil, sandBoxTest: nil)

    var verificationFields: [String: Any] {
        var fields: [String: Any] = ["sandBoxTest": sandBoxTest ?? false]
        if let key = iosVerifyShareKey?.nilIfBlank { fields["iosVerifyShareKey"] = key }
        return fields
    }
}
struct QuotaConfiguration: Decodable {
    let dailyWatchLimit: Int?
    let firstAdRewardWatchCount: Int?
    let secondAdRewardWatchCount: Int?
    let thirdAdRewardWatchCount: Int?
    let favoriteBaseLimit: Int?
    let unlimitedAfterAdCount: Int?

    private enum CodingKeys: String, CodingKey {
        case dailyWatchLimit, firstAdRewardWatchCount, secondAdRewardWatchCount, thirdAdRewardWatchCount
        case favoriteBaseLimit, unlimitedAfterAdCount
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) throws -> Int? {
            guard let value = try box.decodeMediaNumber(forKey: key) else { return nil }
            guard value >= 0, value < Double(Int.max), value.rounded(.towardZero) == value else {
                throw DecodingError.dataCorruptedError(forKey: key, in: box, debugDescription: "Expected a nonnegative quota.")
            }
            return Int(value)
        }
        dailyWatchLimit = try number(.dailyWatchLimit)
        firstAdRewardWatchCount = try number(.firstAdRewardWatchCount)
        secondAdRewardWatchCount = try number(.secondAdRewardWatchCount)
        thirdAdRewardWatchCount = try number(.thirdAdRewardWatchCount)
        favoriteBaseLimit = try number(.favoriteBaseLimit)
        unlimitedAfterAdCount = try number(.unlimitedAfterAdCount)
    }
}
struct AdConfiguration: Decodable {
    let adType: Int
    let advertiser: String?
    let config: AdUnitConfiguration
    let displayInterval: Double?

    private enum CodingKeys: String, CodingKey { case adType, advertiser, config, displayInterval }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        adType = try values.decode(Int.self, forKey: .adType)
        advertiser = try values.decodeIfPresent(String.self, forKey: .advertiser)
        config = try values.decode(AdUnitConfiguration.self, forKey: .config)
        displayInterval = try values.decodeMediaNumber(forKey: .displayInterval)
    }
}

private extension KeyedDecodingContainer {
    // The ad service sends the interval as a JSON number or a numeric string.
    func decodeMediaNumber(forKey key: Key) throws -> Double? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return value }
        let text = try decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected a finite media number.")
        }
        return value
    }
}

enum AppOpenTiming {
    // Server interval is in minutes. Missing/negative configuration is not permission to show.
    static func isDue(intervalMinutes: Double?, lastShown: Date?, now: Date = Date()) -> Bool {
        guard let minutes = intervalMinutes, minutes.isFinite, minutes >= 0,
              (minutes * 60).isFinite else { return false }
        guard let lastShown else { return true }
        return now.timeIntervalSince(lastShown) >= minutes * 60
    }
}
struct AdUnitConfiguration: Decodable { let appId: String?; let adUnitId: String? }

struct GoogleAdPlacement {
    let appID: String
    let unitID: String
    let isOfficialDemo: Bool
}
enum GoogleDemoAds {
    static let appID = "ca-app-pub-3940256099942544~1458002511"
    static let appOpenUnit = "ca-app-pub-3940256099942544/5575463023"
    static let rewardedUnit = "ca-app-pub-3940256099942544/1712485313"
    // Build-configured test mode (GLAMO_ADS_TEST_MODE). Only honoured together with
    // the exact Google demo App ID packaged in GADApplicationIdentifier.
    static func isEnabled(packagedAppID: String?) -> Bool {
        (Bundle.main.object(forInfoDictionaryKey: "GlamoAdsTestMode") as? String) == "YES"
            && packagedAppID == appID
    }
    static func unit(for type: Int) -> String? {
        switch type { case 1: appOpenUnit; case 5: rewardedUnit; default: nil }
    }
}
extension ReleaseConfiguration {
    // Production: App ID comes from getV2 and must agree with the SDK's packaged identity.
    // Never substitute a sample ad unit for a missing or invalid server value.
    // Test builds: both ad types request Google's official demo units; getV2 is still requested.
    func googlePlacement(for type: Int, packagedAppID: String?) -> GoogleAdPlacement? {
        if GoogleDemoAds.isEnabled(packagedAppID: packagedAppID) {
            guard let unit = GoogleDemoAds.unit(for: type) else { return nil }
            return GoogleAdPlacement(appID: GoogleDemoAds.appID, unitID: unit, isOfficialDemo: true)
        }
        let matches = (adList ?? []).filter {
            $0.adType == type && $0.advertiser?.lowercased() == "google"
        }
        guard matches.count == 1, let unit = matches.first,
              let appID = unit.config.appId?.nilIfBlank,
              let unitID = unit.config.adUnitId?.nilIfBlank,
              appID == packagedAppID,
              appID.range(of: #"^ca-app-pub-[0-9]{16}~[0-9]{10}$"#, options: .regularExpression) != nil,
              unitID.range(of: #"^ca-app-pub-[0-9]{16}/[0-9]{10}$"#, options: .regularExpression) != nil,
              appID.split(separator: "~").first == unitID.split(separator: "/").first else { return nil }
        let demoApp = appID == GoogleDemoAds.appID
        let demoUnit = GoogleDemoAds.unit(for: type) == unitID
        if demoApp && !demoUnit { return nil }
        return GoogleAdPlacement(appID: appID, unitID: unitID, isOfficialDemo: demoApp && demoUnit)
    }
    // App-open interval in minutes. Test mode uses the backend value when present, otherwise 0.
    // Production: missing or negative values mean "do not show".
    func appOpenInterval(packagedAppID: String?) -> Double? {
        let configured = adList?.first { $0.adType == 1 && $0.advertiser?.lowercased() == "google" }?.displayInterval
        if GoogleDemoAds.isEnabled(packagedAppID: packagedAppID) {
            if let configured, configured.isFinite, configured < 0 { return nil }
            return configured ?? 0
        }
        return configured
    }
}

struct UserRights: Decodable {
    let rightExpireTime: ServiceID?
    var expiration: Date? {
        guard let raw = rightExpireTime?.value else { return nil }
        if let number = Double(raw), number.isFinite {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: raw) { return date }
        let localFormat = DateFormatter()
        localFormat.locale = Locale(identifier: "en_US_POSIX")
        localFormat.timeZone = .current
        localFormat.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return localFormat.date(from: raw)
    }
}
struct CommerceConfiguration: Decodable {
    struct Product: Decodable, Identifiable {
        enum BillingPeriod: String, Decodable { case month, year }
        let id: String
        let usdPrice: String // Fixed USD plan value (999 / 9999); send unchanged, no currency conversion.
        let label: String
        // Reference display values are separate from the backend's usdPrice contract.
        let displayPriceUSD: String
        let period: BillingPeriod
    }
    let products: [Product]
    let rewardedAdType: Int
    let unlimitedAfterCompletedAds: Int
    let dailyWatchLimit: Int
    let watchRewards: [Int]
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "Commerce", withExtension: "json") else { throw GlamoError.configuration }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

enum GlamoError: LocalizedError {
    case configuration, invalidResponse, unauthorized, service(String), storage, unsupportedMedia
    var errorDescription: String? {
        switch self {
        case .configuration: return "Vifol’s online service is not configured yet. Local editing is available."
        case .invalidResponse: return "The service returned an unreadable response. Please try again."
        case .unauthorized: return "Your session has expired. Please sign in again."
        case .service(let message): return message
        case .storage: return "Your changes could not be saved on this device. Please try again."
        case .unsupportedMedia: return "This video cannot be edited. Import a local video file to continue."
        }
    }
    static func connectionFailure(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return GlamoError.service("A secure connection to Vifol could not be established. Check your network or VPN, then try again. If it continues, the service may be temporarily unavailable.")
        case .notConnectedToInternet, .networkConnectionLost:
            return GlamoError.service("Your internet connection was interrupted. Reconnect and try again.")
        case .timedOut:
            return GlamoError.service("The service took too long to respond. Please try again.")
        default: return error
        }
    }
}
