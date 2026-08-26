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

public struct AorusAIArtifact: Codable, Equatable, Identifiable {
    public var id: String { artifactId }
    public var artifactId: String
    public var filename: String
    public var mime: String
    public var size: Int64
    public var format: String
    public var downloadPath: String
    public var expiresAt: Int64?

    public init(artifactId: String, filename: String, mime: String, size: Int64, format: String, downloadPath: String, expiresAt: Int64?) {
        self.artifactId = artifactId
        self.filename = filename
        self.mime = mime
        self.size = size
        self.format = format
        self.downloadPath = downloadPath
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        let seconds = expiresAt > 10_000_000_000 ? expiresAt / 1000 : expiresAt
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
    public var serverContext: String?
    public var quotaResetAt: Date?

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), messages: [AorusAIMessage] = [], draft: String = "", serverContext: String? = nil, quotaResetAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.draft = draft
        self.serverContext = serverContext
        self.quotaResetAt = quotaResetAt
    }
}

public struct AorusAIAgentPayload: Encodable {
    public struct HistoryMessage: Encodable {
        public var role: String
        public var text: String
        public var telegramEntities: [AorusAITelegramEntity]
        public var referencedMessage: AorusAIReferencedMessage?

        enum CodingKeys: String, CodingKey {
            case role
            case text
            case telegramEntities = "telegram_entities"
            case referencedMessage = "referenced_message"
        }

        init(message: AorusAIMessage) {
            self.role = message.role == .assistant ? "assistant" : "user"
            self.text = message.rawText
            self.telegramEntities = message.telegramEntities
            self.referencedMessage = message.referencedMessage
        }
    }

    public struct Input: Encodable {
        public var text: String
        public var telegramEntities: [AorusAITelegramEntity]
        public var referencedMessage: AorusAIReferencedMessage?

        enum CodingKeys: String, CodingKey {
            case text
            case telegramEntities = "telegram_entities"
            case referencedMessage = "referenced_message"
        }
    }

    public var protocolVersion: String = "AORUS_AGENT_EVENTS_V1"
    public var conversationId: String
    public var input: Input
    public var history: [HistoryMessage]
    public var serverContext: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case conversationId = "conversation_id"
        case input
        case history
        case serverContext = "context"
    }

    public init(conversationId: String, text: String, entities: [AorusAITelegramEntity], referencedMessage: AorusAIReferencedMessage?, history: [AorusAIMessage], serverContext: String?) {
        self.conversationId = conversationId
        self.input = Input(text: text, telegramEntities: entities, referencedMessage: referencedMessage)
        self.history = history
            .filter { $0.role != .notice && !$0.rawText.isEmpty }
            .map(HistoryMessage.init(message:))
        self.serverContext = serverContext
    }
}

public struct AorusAIQuota: Equatable {
    public var resetAt: Date?
    public var label: String?

    public init(resetAt: Date?, label: String?) {
        self.resetAt = resetAt
        self.label = label
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
    case artifactExpired
    case cancelled
    case http(Int)
}
