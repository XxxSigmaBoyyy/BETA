import Foundation

public enum AorusAIMessageRole: String, Codable {
    case user
    case assistant
    case notice
}

public enum AorusAIMessageState: String, Codable {
    case complete
    case streaming
    case failed
    case cancelled
}

public struct AorusAITelegramEntity: Codable, Equatable {
    public var peerId: Int64?
    public var username: String?
    public var displayName: String
    public var sourceText: String
    public var rangeLocation: Int
    public var rangeLength: Int

    public init(peerId: Int64?, username: String?, displayName: String, sourceText: String, rangeLocation: Int, rangeLength: Int) {
        self.peerId = peerId
        self.username = username
        self.displayName = displayName
        self.sourceText = sourceText
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
    }
}

public struct AorusAIReferencedMessage: Codable, Equatable {
    public var peerId: Int64
    public var messageNamespace: Int32
    public var messageId: Int32
    public var authorPeerId: Int64?
    public var authorName: String?
    public var text: String

    public init(peerId: Int64, messageNamespace: Int32, messageId: Int32, authorPeerId: Int64?, authorName: String?, text: String) {
        self.peerId = peerId
        self.messageNamespace = messageNamespace
        self.messageId = messageId
        self.authorPeerId = authorPeerId
        self.authorName = authorName
        self.text = text
    }
}

/// A file the backend produced for one assistant turn.
///
/// The public `artifact.ready` event carries no vault token, so this model has no
/// field for one: a token that ever appeared in a payload is dropped on decode and
/// can therefore neither be persisted nor displayed.
public struct AorusAIArtifact: Codable, Equatable, Identifiable {
    public var id: String { artifactId }
    public var artifactId: String
    public var filename: String
    public var mime: String
    public var size: Int64
    public var format: String
    public var downloadPath: String
    /// Lifetime of the artifact itself, as reported by the backend.
    public var expiresAt: Int64?
    /// Lifetime of the signed download link, which the backend reports separately
    /// and which usually ends earlier than the artifact's own expiry.
    public var downloadExpiresAt: Int64?

    public init(artifactId: String, filename: String, mime: String, size: Int64, format: String, downloadPath: String, expiresAt: Int64?, downloadExpiresAt: Int64? = nil) {
        self.artifactId = artifactId
        self.filename = filename
        self.mime = mime
        self.size = size
        self.format = format
        self.downloadPath = downloadPath
        self.expiresAt = expiresAt
        self.downloadExpiresAt = downloadExpiresAt
    }

    public var isExpired: Bool {
        return AorusAIArtifact.isPast(expiresAt)
    }

    /// True once the signed link is stale while the artifact itself is still alive.
    /// The card stays visible as a historical fact either way; only the tap action
    /// changes.
    public var isDownloadExpired: Bool {
        return AorusAIArtifact.isPast(downloadExpiresAt)
    }

    private static func isPast(_ value: Int64?) -> Bool {
        guard let value else { return false }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Int64(Date().timeIntervalSince1970) >= seconds
    }
}

public struct AorusAIMessage: Codable, Equatable, Identifiable {
    public var id: UUID
    public var role: AorusAIMessageRole
    public var rawText: String
    public var createdAt: Date
    public var state: AorusAIMessageState
    public var telegramEntities: [AorusAITelegramEntity]
    public var referencedMessage: AorusAIReferencedMessage?
    public var artifacts: [AorusAIArtifact]
    public var statusLabel: String?
    public var errorCode: String?

    public init(id: UUID = UUID(), role: AorusAIMessageRole, rawText: String, createdAt: Date = Date(), state: AorusAIMessageState = .complete, telegramEntities: [AorusAITelegramEntity] = [], referencedMessage: AorusAIReferencedMessage? = nil, artifacts: [AorusAIArtifact] = [], statusLabel: String? = nil, errorCode: String? = nil) {
        self.id = id
        self.role = role
        self.rawText = rawText
        self.createdAt = createdAt
        self.state = state
        self.telegramEntities = telegramEntities
        self.referencedMessage = referencedMessage
        self.artifacts = artifacts
        self.statusLabel = statusLabel
        self.errorCode = errorCode
    }
}

public struct AorusAIConversation: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [AorusAIMessage]
    public var draft: String
    /// Reset moment reported by the backend's quota event. Purely presentational:
    /// the client never invents it and never sends it back.
    public var quotaResetAt: Date?

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), messages: [AorusAIMessage] = [], draft: String = "", quotaResetAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.draft = draft
        self.quotaResetAt = quotaResetAt
    }
}

public enum AorusAIRequestLimits {
    /// Newest conversation turns that are replayed as context.
    public static let historyMessageCount = 40
    /// Per-message clamp applied to replayed context.
    public static let historyMessageCharacters = 6_000
    /// Total clamp applied to replayed context.
    public static let historyTotalCharacters = 60_000
    /// Clamp applied to the message the user is sending right now.
    public static let promptCharacters = 24_000
    /// Telegram messages the chat analysis workflow may hand over at once.
    public static let chatHistoryMessageCount = 200
    /// Per-Telegram-message clamp used by the chat analysis workflow.
    public static let chatHistoryMessageCharacters = 700
}

/// The production body of `POST /v1/aorus/agent`.
///
/// The backend accepts a plain chat-completions shaped payload and detects the
/// workflow (chat, presentation, document, build) from the natural language
/// request itself, so there is deliberately no client side `kind`, no protocol
/// envelope and no separate conversation identifier here.
public struct AorusAIAgentPayload: Encodable {
    public struct Message: Encodable, Equatable {
        public var role: String
        public var content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public var model: String
    public var stream: Bool
    public var messages: [Message]

    public init(model: String = "AorusAI", stream: Bool = true, messages: [Message]) {
        self.model = model
        self.stream = stream
        self.messages = messages
    }

    /// Builds the payload from the locally stored conversation.
    ///
    /// `history` must be the turns that precede the new request. Notices, empty
    /// and failed turns are dropped, the newest turns win when the character
    /// budget is exhausted, and chronological order is preserved.
    public init(history: [AorusAIMessage], text: String) {
        var context: [Message] = []
        var budget = AorusAIRequestLimits.historyTotalCharacters
        for message in history.suffix(AorusAIRequestLimits.historyMessageCount).reversed() {
            guard message.role != .notice, message.state != .failed else { continue }
            let content = AorusAIAgentPayload.clamp(message.rawText, to: AorusAIRequestLimits.historyMessageCharacters)
            guard !content.isEmpty, content.count <= budget else { continue }
            budget -= content.count
            context.append(Message(role: message.role == .assistant ? "assistant" : "user", content: content))
        }
        var messages = Array(context.reversed())
        messages.append(Message(role: "user", content: AorusAIAgentPayload.clamp(text, to: AorusAIRequestLimits.promptCharacters)))
        self.init(messages: messages)
    }

    private static func clamp(_ value: String, to limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

public struct AorusAIQuota: Equatable {
    public var resetAt: Date?
    public var label: String?
    /// True when the backend reported a countdown rather than an absolute time,
    /// so the UI can say "Обновится через 42 мин." instead of a wall clock time.
    public var isRelative: Bool

    public init(resetAt: Date?, label: String?, isRelative: Bool = false) {
        self.resetAt = resetAt
        self.label = label
        self.isRelative = isRelative
    }
}

/// Facts about a Telegram peer the user mentioned, resolved on the device and sent
/// with the request so the model actually knows who `@name` is.
///
/// Only data the user can already see in the app is included, it is clamped, and it
/// is built here — in a plain, testable value — instead of inside the view layer.
public struct AorusAIProfileSummary: Equatable {
    public var title: String
    public var username: String?
    public var kind: String
    public var bio: String?
    public var participantCount: Int?

    public init(title: String, username: String?, kind: String, bio: String?, participantCount: Int?) {
        self.title = title
        self.username = username
        self.kind = kind
        self.bio = bio
        self.participantCount = participantCount
    }

    /// One compact block per profile. `header` and `labels` come from the caller so
    /// this stays free of any localization dependency.
    public func transportBlock(labels: AorusAIProfileLabels) -> String {
        var lines: [String] = []
        var head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let username, !username.isEmpty {
            head += " (@\(username))"
        }
        lines.append("\(labels.profile): \(String(head.prefix(160)))")
        let type = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        if !type.isEmpty {
            lines.append("\(labels.kind): \(type)")
        }
        if let participantCount, participantCount > 0 {
            lines.append("\(labels.participants): \(participantCount)")
        }
        if let bio = bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
            lines.append("\(labels.about): \(String(bio.prefix(700)))")
        }
        return lines.joined(separator: "\n")
    }
}

public struct AorusAIProfileLabels: Equatable {
    public var profile: String
    public var kind: String
    public var participants: String
    public var about: String

    public init(profile: String, kind: String, participants: String, about: String) {
        self.profile = profile
        self.kind = kind
        self.participants = participants
        self.about = about
    }
}

public struct AorusAIPermissionRequest: Equatable {
    public var requestId: String
    public var kind: String
    public var peerId: Int64?
    public var count: Int?
    public var previewText: String?

    public init(requestId: String, kind: String, peerId: Int64?, count: Int?, previewText: String?) {
        self.requestId = requestId
        self.kind = kind
        self.peerId = peerId
        self.count = count
        self.previewText = previewText
    }
}

public enum AorusAIEvent: Equatable {
    case agentStarted(turnId: String, context: String?)
    case status(label: String, progress: Double?)
    case reasoningSummary(String)
    case responseStarted
    case responseDelta(String)
    case artifactReady(AorusAIArtifact)
    case permissionRequest(AorusAIPermissionRequest)
    case responseDone
    case quota(AorusAIQuota)
    case done(ok: Bool)
    case unknown(name: String)
}

public enum AorusAIClientError: Error, Equatable {
    case notProvisioned
    case offline
    case timeout
    case authorization
    case quota(AorusAIQuota)
    case serverUnavailable
    case malformedResponse
    /// The stored lifetime of the file or of its signed link has passed (HTTP 410).
    case artifactExpired
    /// The vault refused the file for this device (HTTP 403 `artifact_not_owned`).
    case artifactNotOwned
    /// The file is no longer stored at all (HTTP 404).
    case artifactGone
    /// The transfer itself failed: no connection, a dropped socket, a bad payload.
    case artifactDownloadFailed
    case cancelled
    case http(Int)
}
