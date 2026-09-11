import Foundation

// License state machine. Raw values match the server `status` field.
public enum LicenseStatus: String {
    case notStarted   = "not_started"
    case trialActive  = "trial_active"
    case paidActive   = "paid_active"
    case expired      = "expired"
    case banned       = "banned"
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
        case .expired, .banned: return true
        default: return false
        }
    }
}

// Decoded license API response. Parsed leniently from JSON so an unexpected /
// extra field never breaks the client.
public struct LicenseResponse {
    public let status: LicenseStatus
    public let plan: String?
    public let trial: Bool?
    public let paid: Bool?
    public let activeUntil: Int64?
    public let serverNow: Int64?
    public let daysLeft: Int?
    public let errorCode: String?

    init(json: [String: Any]) {
        self.status = LicenseStatus.parse(json["status"] as? String)
        self.plan = json["plan"] as? String
        self.trial = json["trial"] as? Bool
        self.paid = json["paid"] as? Bool
        self.activeUntil = LicenseResponse.int64(json["active_until"])
        self.serverNow = LicenseResponse.int64(json["server_now"])
        self.daysLeft = LicenseResponse.int(json["days_left"])
        self.errorCode = (json["error"] as? String) ?? (json["error_code"] as? String)
    }

    private static func int64(_ any: Any?) -> Int64? {
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

public enum LicenseError: Error {
    case notProvisioned          // no HMAC key baked in — refuse to sign
    case network                 // transport failure / offline
    case http(Int)               // non-2xx without a known error code
    case decode                  // malformed response
    case server(String)          // server error code (e.g. code_already_used)
}
