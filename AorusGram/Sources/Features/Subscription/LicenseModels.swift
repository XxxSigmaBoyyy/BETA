import Foundation

// License state machine. Raw values match the server `status` field.
public enum LicenseStatus: String {
    case notStarted   = "not_started"
    case trialActive  = "trial_active"
    case paidActive   = "paid_active"
    case expired      = "expired"
    case banned       = "banned"
    case clientOutdated = "client_outdated"
    case networkError = "network_error"

    // Unknown / missing status maps to networkError (never silently "active").
    static func parse(_ raw: String?) -> LicenseStatus {
        guard let raw = raw, let value = LicenseStatus(rawValue: raw) else {
            return .networkError
        }
        return value
    }

    // The only two states that grant access to the Telegram UI.
    public var allowsAppAccess: Bool {
        switch self {
        case .trialActive, .paidActive: return true
        default: return false
        }
    }

    // Hard-lock states (root-swap to the expired screen).
    public var isLocked: Bool {
        switch self {
        case .expired, .banned, .clientOutdated: return true
        default: return false
        }
    }
}

// Decoded license API response. Parsed leniently from JSON so an unexpected /
// extra field never breaks the client.
public struct LicenseResponse {
    public struct Badge: Equatable {
        public enum Identifier: String {
            case dev
            case meme
            case verified
        }

        public let id: Identifier
        public let until: Int64?
    }

    public let status: LicenseStatus
    public let plan: String?
    public let trial: Bool?
    public let paid: Bool?
    public let activeUntil: Int64?
    public let serverNow: Int64?
    public let daysLeft: Int?
    public let errorCode: String?
    public let badges: [Badge]

    init(json: [String: Any]) {
        let errorCode = (json["error"] as? String)
            ?? (json["error_code"] as? String)
            ?? (json["detail"] as? String)
        self.status = errorCode == LicenseStatus.clientOutdated.rawValue
            ? .clientOutdated
            : LicenseStatus.parse(json["status"] as? String)
        self.plan = json["plan"] as? String
        self.trial = json["trial"] as? Bool
        self.paid = json["paid"] as? Bool
        self.activeUntil = LicenseResponse.int64(json["active_until"])
        self.serverNow = LicenseResponse.int64(json["server_now"])
        self.daysLeft = LicenseResponse.int(json["days_left"])
        self.errorCode = errorCode
        self.badges = (json["badges"] as? [[String: Any]] ?? []).compactMap(Self.badge)
    }

    fileprivate static func badge(_ item: [String: Any]) -> Badge? {
        guard var rawId = item["id"] as? String else { return nil }
        if rawId == "head_admin_cat" { rawId = "meme" }
        guard let id = Badge.Identifier(rawValue: rawId) else { return nil }

        let until: Int64?
        if let rawUntil = item["until"], !(rawUntil is NSNull) {
            guard let parsed = int64(rawUntil) else { return nil }
            until = parsed
        } else {
            until = nil
        }
        return Badge(id: id, until: until)
    }

    fileprivate static func int64(_ any: Any?) -> Int64? {
        if let number = any as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? Double {
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
            return Int64(value)
        }
        if let value = any as? NSNumber {
            let number = value.doubleValue
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= Double(Int64.min), number < Double(Int64.max) else { return nil }
            return value.int64Value
        }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let number = any as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if let value = any as? Int { return value }
        if let value = any as? Double {
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return Int(value)
        }
        if let value = any as? NSNumber {
            let number = value.doubleValue
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= Double(Int.min), number < Double(Int.max) else { return nil }
            return value.intValue
        }
        return nil
    }
}

// Complete server-owned badge roster. The payload is intentionally bounded before
// it reaches UI state: a malformed or unexpectedly large signed response fails as a
// whole instead of consuming unbounded memory on every peer row.
struct BadgeSnapshotResponse: Equatable {
    static let maximumPeerCount = 20_000
    static let maximumBadgesPerPeer = 8

    let serverNow: Int64
    let revision: Int64
    let badges: [Int64: [LicenseResponse.Badge]]

    init?(json: [String: Any]) {
        guard let serverNow = LicenseResponse.int64(json["server_now"]), serverNow > 0,
              let revision = LicenseResponse.int64(json["revision"]), revision >= 0 else {
            return nil
        }

        // One shape, the one the server actually serves: `badges` is an OBJECT keyed
        // by Telegram id, each value an array of {id, until}. The flat array of
        // {peer_id, kind} from the earlier design plan is explicitly not to be parsed —
        // it does not exist on the server, and accepting it is surface with nothing
        // behind it.
        guard let rawBadges = json["badges"] as? [String: Any],
              rawBadges.count <= Self.maximumPeerCount else {
            return nil
        }
        var parsed: [Int64: [LicenseResponse.Badge]] = [:]
        parsed.reserveCapacity(rawBadges.count)
        for (rawPeerId, value) in rawBadges {
            guard let peerId = Int64(rawPeerId), peerId > 0,
                  let rawItems = value as? [[String: Any]],
                  rawItems.count <= Self.maximumBadgesPerPeer else {
                return nil
            }
            let items = rawItems.compactMap(LicenseResponse.badge)
            if !items.isEmpty {
                parsed[peerId] = items
            }
        }

        self.serverNow = serverNow
        self.revision = revision
        self.badges = parsed
    }
}

public enum LicenseError: Error {
    case notProvisioned          // no HMAC key baked in — refuse to sign
    case network                 // transport failure / offline
    case http(Int)               // non-2xx without a known error code
    case decode                  // malformed response
    case server(String)          // server error code (e.g. code_already_used)
}
