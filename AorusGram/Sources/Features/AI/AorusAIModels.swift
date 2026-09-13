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
    /// The work the agent did on this turn, in the order it reported it: each phase
    /// label it announced and the files it touched under that phase. Kept on the
    /// message so the trail survives a reload of the conversation, and so the finished
    /// turn can collapse it behind one line.
    public var workPhases: [AorusAIWorkPhase] = []
    /// When the agent stopped working on this turn. Stored rather than derived: the
    /// folded trail reports how long the work took, and after a reload there is no
    /// other way to know when it ended.
    public var workFinishedAt: Date?
    public var errorCode: String?

    public init(id: UUID = UUID(), role: AorusAIMessageRole, rawText: String, createdAt: Date = Date(), state: AorusAIMessageState = .complete, telegramEntities: [AorusAITelegramEntity] = [], referencedMessage: AorusAIReferencedMessage? = nil, artifacts: [AorusAIArtifact] = [], statusLabel: String? = nil, workPhases: [AorusAIWorkPhase] = [], workFinishedAt: Date? = nil, errorCode: String? = nil) {
        self.id = id
        self.role = role
        self.rawText = rawText
        self.createdAt = createdAt
        self.state = state
        self.telegramEntities = telegramEntities
        self.referencedMessage = referencedMessage
        self.artifacts = artifacts
        self.statusLabel = statusLabel
        self.workPhases = workPhases
        self.workFinishedAt = workFinishedAt
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, rawText, createdAt, state, telegramEntities
        case referencedMessage, artifacts, statusLabel, workPhases, workFinishedAt, errorCode
    }

    /// Hand-written for the same reason the conversation's is.
    ///
    /// The synthesized decoder calls `decode` for every non-optional property and throws
    /// on a key that is absent — a default value does not save it — and `AorusAIStore.read`
    /// answers a decode failure by treating the file as corrupt and deleting it. Gaining
    /// `workPhases` would therefore have cost every reader their entire AI history on the
    /// first launch after the update. Every collection is read as optional-with-default, so
    /// this file survives gaining a field again.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(AorusAIMessageRole.self, forKey: .role)
        self.rawText = try container.decode(String.self, forKey: .rawText)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.state = try container.decode(AorusAIMessageState.self, forKey: .state)
        self.telegramEntities = try container.decodeIfPresent([AorusAITelegramEntity].self, forKey: .telegramEntities) ?? []
        self.referencedMessage = try container.decodeIfPresent(AorusAIReferencedMessage.self, forKey: .referencedMessage)
        self.artifacts = try container.decodeIfPresent([AorusAIArtifact].self, forKey: .artifacts) ?? []
        self.statusLabel = try container.decodeIfPresent(String.self, forKey: .statusLabel)
        self.workPhases = try container.decodeIfPresent([AorusAIWorkPhase].self, forKey: .workPhases) ?? []
        self.workFinishedAt = try container.decodeIfPresent(Date.self, forKey: .workFinishedAt)
        self.errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

/// The chat identity the backend uses to decide which file an edit applies to.
///
/// Client contract 2026-09-13 §3: one stable id per AorusAI chat, a new chat means a
/// new id, and the same chat keeps its id across restarts. It is generated here, and
/// is deliberately NOT the device hash, the licence, a Telegram chat id or an artifact
/// id — none of those isolates edits per chat, and the first two would hand the server
/// an identifier it already has in a field that does not need one.
public enum AorusAIThreadID {
    /// §3: 8-80 characters of `[A-Za-z0-9._:-]`.
    private static let minimumLength = 8
    private static let maximumLength = 80

    public static func generate() -> String {
        // A v4 UUID: 36 characters, inside the bound, and every character allowed.
        return UUID().uuidString
    }

    public static func isValid(_ value: String) -> Bool {
        guard value.count >= minimumLength, value.count <= maximumLength else { return false }
        for character in value {
            // ASCII first, so `isLetter` means A-Z/a-z and `isNumber` means 0-9 rather
            // than every letter and digit Unicode knows about — and so the length above
            // counts the same units the server counts.
            guard character.isASCII else { return false }
            if character.isLetter || character.isNumber { continue }
            guard character == "." || character == "_" || character == ":" || character == "-" else {
                return false
            }
        }
        return true
    }

    /// The stored id when it is usable, otherwise something that is.
    ///
    /// A history file is only ever written by this client, so a malformed id means the
    /// file was edited or damaged. Refusing to send anything at all is the documented
    /// fallback (§3: the server then uses `thread_key = "_"`), but a chat that keeps
    /// its own identity is strictly better, so the conversation's own id is preferred.
    public static func sanitized(_ value: String?, fallback: String) -> String {
        if let value, isValid(value) { return value }
        return isValid(fallback) ? fallback : generate()
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
    /// Pinned conversations are listed above the recent ones. Local only.
    public var pinned: Bool
    /// This chat's identity for the backend's file-edit boundary (§3). Set once when
    /// the chat is created and never changed afterwards: changing it would strand the
    /// file the next "исправь заголовок" is meant to edit.
    public var threadId: String

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), messages: [AorusAIMessage] = [], draft: String = "", quotaResetAt: Date? = nil, pinned: Bool = false, threadId: String = AorusAIThreadID.generate()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.draft = draft
        self.quotaResetAt = quotaResetAt
        self.pinned = pinned
        self.threadId = threadId
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, draft, quotaResetAt, pinned, threadId
    }

    /// Hand-written because the history file has to survive gaining a field.
    ///
    /// The synthesized decoder throws on a key that is absent, even when the property
    /// has a default value — and `AorusAIStore.read` answers any decode failure by
    /// treating the file as corrupt and deleting it. A store written before pinning
    /// existed carries no `pinned` key, so it is decoded as "not pinned" instead of
    /// costing the user every conversation they had.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.messages = try container.decode([AorusAIMessage].self, forKey: .messages)
        self.draft = try container.decodeIfPresent(String.self, forKey: .draft) ?? ""
        self.quotaResetAt = try container.decodeIfPresent(Date.self, forKey: .quotaResetAt)
        self.pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        // A chat that predates the field falls back to its own local id rather than to a
        // fresh one. Both are v4 UUIDs the client generated, but only the local id is the
        // same on every launch — a fresh one would be a different chat to the backend
        // each time the history is read, which is exactly what §3 forbids.
        self.threadId = AorusAIThreadID.sanitized(
            try container.decodeIfPresent(String.self, forKey: .threadId),
            fallback: self.id.uuidString
        )
    }
}

/// A JSON value the client hands to the backend inside a tool result.
///
/// The backend does `JSON.stringify(item.result ?? {})` and passes the text to the
/// model as data, so there is no fixed schema to satisfy — but there is also no
/// place for `Any`: every value that leaves the device is built explicitly here, so
/// the HMAC can be taken over exact bytes and the payload stays reviewable.
public indirect enum AorusAIJSONValue: Equatable, Encodable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case array([AorusAIJSONValue])
    case object([String: AorusAIJSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .int64(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    /// Drops empty strings and empty containers so the model never receives a field
    /// that only says "the client had nothing here".
    public static func object(fields: [(String, AorusAIJSONValue?)]) -> AorusAIJSONValue {
        var result: [String: AorusAIJSONValue] = [:]
        for (key, value) in fields {
            guard let value else { continue }
            if case let .string(text) = value, text.isEmpty { continue }
            if case let .array(items) = value, items.isEmpty { continue }
            if case let .object(fields) = value, fields.isEmpty { continue }
            result[key] = value
        }
        return .object(result)
    }
}

/// Tool names the backend advertises in `agent.start.capabilities` and asks for in
/// `tool.request` / `permission.request`.
public enum AorusAITool {
    public static let profileGet = "telegram.profile.get"
    public static let chatHistory = "telegram.chat.history"
}

/// `done.state` values that are successful intermediate states, not failures.
public enum AorusAIAgentState {
    public static let awaitingTool = "awaiting_tool"
    public static let awaitingPermission = "awaiting_permission"
}

/// `event: tool.request` — the backend asks the device to run one Telegram tool.
///
/// `requiresUserApproval` mirrors the server field of the same name: for
/// `telegram.profile.get` it is `false`, and the client must then run the tool
/// without showing any additional dialog.
public struct AorusAIToolRequest: Equatable {
    public var requestId: String
    public var tool: String
    public var label: String?
    public var username: String?
    public var limit: Int?
    public var requiresUserApproval: Bool

    public init(requestId: String, tool: String, label: String?, username: String?, limit: Int?, requiresUserApproval: Bool) {
        self.requestId = requestId
        self.tool = tool
        self.label = label
        self.username = username
        self.limit = limit
        self.requiresUserApproval = requiresUserApproval
    }
}

/// One button of a server-supplied `permission.request`.
///
/// Either it carries a `limit` (that many newest messages) or `mode == "period"`,
/// which asks for a date range instead. The client never invents options.
public struct AorusAIPermissionOption: Equatable {
    public static let periodMode = "period"

    public var id: String
    public var label: String
    public var limit: Int?
    public var mode: String?

    public init(id: String, label: String, limit: Int?, mode: String?) {
        self.id = id
        self.label = label
        self.limit = limit
        self.mode = mode
    }

    public var isPeriod: Bool {
        return mode == AorusAIPermissionOption.periodMode
    }
}

/// `event: permission.request` — the backend asks the user, through the device, for
/// permission to read something. The options come from the payload.
public struct AorusAIPermissionRequest: Equatable {
    public var requestId: String
    public var tool: String
    public var title: String?
    public var text: String?
    public var username: String?
    public var options: [AorusAIPermissionOption]
    public var allowCancel: Bool

    public init(requestId: String, tool: String, title: String?, text: String?, username: String?, options: [AorusAIPermissionOption], allowCancel: Bool) {
        self.requestId = requestId
        self.tool = tool
        self.title = title
        self.text = text
        self.username = username
        self.options = options
        self.allowCancel = allowCancel
    }
}

/// One element of `aorus_tool_results`, exactly as the backend reads it.
public struct AorusAIToolResult: Equatable, Encodable {
    public struct Arguments: Equatable, Encodable {
        public var username: String?
        public var limit: Int?
        public var fromDate: Int64?
        public var toDate: Int64?

        public init(username: String? = nil, limit: Int? = nil, fromDate: Int64? = nil, toDate: Int64? = nil) {
            self.username = username
            self.limit = limit
            self.fromDate = fromDate
            self.toDate = toDate
        }

        private enum CodingKeys: String, CodingKey {
            case username
            case limit
            case fromDate = "from_date"
            case toDate = "to_date"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(username, forKey: .username)
            try container.encodeIfPresent(limit, forKey: .limit)
            try container.encodeIfPresent(fromDate, forKey: .fromDate)
            try container.encodeIfPresent(toDate, forKey: .toDate)
        }
    }

    public var tool: String
    public var requestId: String?
    public var ok: Bool
    public var denied: Bool
    public var arguments: Arguments
    public var result: AorusAIJSONValue?

    public init(tool: String, requestId: String?, ok: Bool, denied: Bool, arguments: Arguments, result: AorusAIJSONValue?) {
        self.tool = tool
        self.requestId = requestId
        self.ok = ok
        self.denied = denied
        self.arguments = arguments
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case tool
        case requestId = "request_id"
        case ok
        case denied
        case arguments
        case result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encode(ok, forKey: .ok)
        try container.encode(denied, forKey: .denied)
        try container.encode(arguments, forKey: .arguments)
        try container.encodeIfPresent(result, forKey: .result)
    }

    /// The user refused: a real, expected answer, never an error.
    public static func denied(tool: String, requestId: String?, username: String?) -> AorusAIToolResult {
        return AorusAIToolResult(
            tool: tool,
            requestId: requestId,
            ok: false,
            denied: true,
            arguments: Arguments(username: username),
            result: nil
        )
    }

    /// The tool ran but could not produce data — a failed username resolution, for
    /// instance. The backend is told the truth so the model does not invent facts.
    public static func failure(tool: String, requestId: String?, username: String?, reason: String) -> AorusAIToolResult {
        return AorusAIToolResult(
            tool: tool,
            requestId: requestId,
            ok: false,
            denied: false,
            arguments: Arguments(username: username),
            result: .object(fields: [("error", .string(reason))])
        )
    }

    /// `telegram.chat.history` result in the shape the backend reads: it takes
    /// `result.messages`, keeps the last 100 and reads `sender_name` / `text`.
    public static func history(
        requestId: String?,
        username: String?,
        limit: Int?,
        fromDate: Int64? = nil,
        toDate: Int64? = nil,
        messages: [(sender: String, text: String, caption: String?)]
    ) -> AorusAIToolResult {
        let clamped = messages.suffix(AorusAIRequestLimits.chatHistoryMessageCount).map { message in
            // `text` and `caption` are both dropped when empty by `object(fields:)`, so a
            // voice message travels as `{ "sender_name": …, "caption": "голосовое 0:12" }`
            // and a photo with a caption carries both.
            AorusAIJSONValue.object(fields: [
                ("sender_name", .string(String(message.sender.prefix(96)))),
                ("text", .string(String(message.text.prefix(AorusAIRequestLimits.chatHistoryMessageCharacters)))),
                ("caption", message.caption.map { .string(String($0.prefix(96))) })
            ])
        }
        // `messages` stays even when it is empty: "the chat has nothing to read" is a
        // fact the model needs, unlike an absent field.
        var fields: [String: AorusAIJSONValue] = ["messages": .array(clamped)]
        if let limit {
            fields["requested_limit"] = .int(limit)
        }
        return AorusAIToolResult(
            tool: AorusAITool.chatHistory,
            requestId: requestId,
            ok: true,
            denied: false,
            arguments: Arguments(username: username, limit: limit, fromDate: fromDate, toDate: toDate),
            result: .object(fields)
        )
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
    /// The most an answer may grow to while it streams. No real answer approaches it; a
    /// server that never stopped sending deltas would otherwise grow the message, the
    /// encrypted history file and every attributed string built from it without limit.
    public static let responseCharacters = 200_000
    /// Files one turn may attach. `artifact.ready` is server-driven and repeats are
    /// already ignored, but distinct ids are not bounded by anything else.
    public static let responseArtifactCount = 24
    /// Choices a permission sheet may offer. Each one is a row of real views built on the
    /// main thread, and the payload that carries them is allowed to be megabytes.
    public static let permissionOptionCount = 8
    /// Clamp on every string inside one of those choices.
    public static let permissionOptionCharacters = 120
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
    /// Results of the Telegram tools the backend asked for, accumulated across every
    /// continuation of one logical request (§14: dropping the profile result makes the
    /// server ask for the profile again).
    public var toolResults: [AorusAIToolResult]
    /// The chat this turn belongs to, so "добавь слайд про цены" edits the file this
    /// chat produced and not the one another chat produced (artifact-edit contract §3).
    ///
    /// This is the ONLY field that contract adds. `artifact_session_id` is deliberately
    /// absent: the server resolves its own session from `(device_hash, thread_key)`, and
    /// §8 says not to send one "на всякий случай".
    public var threadId: String?

    public init(model: String = "AorusAI", stream: Bool = true, messages: [Message], toolResults: [AorusAIToolResult] = [], threadId: String? = nil) {
        self.model = model
        self.stream = stream
        self.messages = messages
        self.toolResults = toolResults
        self.threadId = threadId
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case stream
        case messages
        case toolResults = "aorus_tool_results"
        case threadId = "aorus_thread_id"
    }

    /// `aorus_tool_results` is written only when there is something to report, so a
    /// plain chat request keeps the exact body it has always had.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(stream, forKey: .stream)
        try container.encode(messages, forKey: .messages)
        if !toolResults.isEmpty {
            try container.encode(toolResults, forKey: .toolResults)
        }
        // An id that does not satisfy §3 is left out rather than sent malformed. That is
        // the documented degraded mode — the server falls back to `thread_key = "_"` and
        // edits the device's own most recent file — and it is what every build before
        // this one already does, so nothing breaks.
        if let threadId, AorusAIThreadID.isValid(threadId) {
            try container.encode(threadId, forKey: .threadId)
        }
    }

    /// Builds the payload from the locally stored conversation.
    ///
    /// `history` must be the turns that precede the new request. Notices, empty
    /// and failed turns are dropped, the newest turns win when the character
    /// budget is exhausted, and chronological order is preserved.
    public init(history: [AorusAIMessage], text: String, toolResults: [AorusAIToolResult] = [], threadId: String? = nil) {
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
        self.init(messages: messages, toolResults: toolResults, threadId: threadId)
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

public struct AorusAIProfileSummaryFields: Equatable {
    public var displayName: String
    public var username: String?
    public var kind: String
    public var about: String?
    public var participantCount: Int?
    public var isVerified: Bool
    public var isPremium: Bool
    public var isScam: Bool

    public init(displayName: String, username: String?, kind: String, about: String?, participantCount: Int?, isVerified: Bool, isPremium: Bool, isScam: Bool) {
        self.displayName = displayName
        self.username = username
        self.kind = kind
        self.about = about
        self.participantCount = participantCount
        self.isVerified = isVerified
        self.isPremium = isPremium
        self.isScam = isScam
    }

    /// `telegram.profile.get` result: only fields the device actually has, clamped,
    /// no avatar bytes, nothing invented (§20).
    public func toolResult(requestId: String?, username argumentUsername: String?) -> AorusAIToolResult {
        var fields: [(String, AorusAIJSONValue?)] = [
            ("display_name", .string(String(displayName.prefix(160)))),
            ("username", username.map { .string($0) }),
            ("kind", .string(kind)),
            ("about", about.map { .string(String($0.prefix(700))) })
        ]
        if let participantCount, participantCount > 0 {
            fields.append(("participant_count", .int(participantCount)))
        }
        if isVerified {
            fields.append(("verified", .bool(true)))
        }
        if isPremium {
            fields.append(("premium", .bool(true)))
        }
        if isScam {
            fields.append(("scam", .bool(true)))
        }
        return AorusAIToolResult(
            tool: AorusAITool.profileGet,
            requestId: requestId,
            ok: true,
            denied: false,
            arguments: AorusAIToolResult.Arguments(username: argumentUsername ?? username),
            result: .object(fields: fields)
        )
    }
}

/// One file the agent touched while it worked.
///
/// `added` and `removed` are line counts and are rendered as the document specifies:
/// `+125` in green, `-20` in red, a plus always with its plus and a minus always with its
/// minus. The screen shows the basename only; the full path stays in the payload.
public struct AorusAIFileChange: Codable, Equatable {
    public enum Kind: String, Codable, Equatable {
        case created
        case edited
        case deleted
    }

    public let kind: Kind
    public let path: String
    public let added: Int
    public let removed: Int
    public let attempt: Int

    public init(kind: Kind, path: String, added: Int, removed: Int, attempt: Int) {
        self.kind = kind
        self.path = path
        self.added = added
        self.removed = removed
        self.attempt = attempt
    }

    /// What the row is titled with. The document is explicit that the full path is not
    /// shown here.
    public var displayName: String {
        return (path as NSString).lastPathComponent
    }

    /// An edit that neither added nor removed anything is not shown at all.
    public var isRenderable: Bool {
        switch kind {
        case .created: return added > 0
        case .deleted: return removed > 0
        case .edited: return added > 0 || removed > 0
        }
    }
}

/// One stretch of the agent's work: the label it announced, and the files it touched
/// while that label was current.
///
/// A new phase starts whenever the agent announces a new label, so "Проектирую
/// структуру…" and the files under it are one phase and "Собираю…" is the next.
public struct AorusAIWorkPhase: Codable, Equatable, Identifiable {
    public var id: UUID
    public var label: String
    public var startedAt: Date
    public var files: [AorusAIFileChange]

    public init(id: UUID = UUID(), label: String, startedAt: Date = Date(), files: [AorusAIFileChange] = []) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.files = files
    }
}

public enum AorusAIEvent: Equatable {
    case agentStarted(turnId: String, context: String?)
    case status(label: String, progress: Double?)
    /// A build/repair/diagnose/finalize phase. Only `label` is ever shown; `phase` is the
    /// backend's own name for it and stays out of the chat.
    case buildPhase(phase: String, label: String, attempt: Int)
    /// A file the agent created, edited or deleted during the turn.
    case fileChange(AorusAIFileChange)
    case reasoningSummary(String)
    case responseStarted
    case responseDelta(String)
    case artifactReady(AorusAIArtifact)
    /// A whole chat-completion answer: the turn's text and the files it produced. The
    /// production answer for an artifact turn is this, not a stream of `artifact.ready`.
    case completion(text: String?, artifacts: [AorusAIArtifact])
    case toolRequest(AorusAIToolRequest)
    case toolResult(tool: String, ok: Bool, label: String?)
    case permissionRequest(AorusAIPermissionRequest)
    case responseDone
    case quota(AorusAIQuota)
    /// `state` carries the backend's `done.state`. `awaiting_tool` and
    /// `awaiting_permission` are successful intermediate states (§1, §17).
    case done(ok: Bool, state: String?)
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
    /// The client itself refused the file, and this names which guard did it.
    ///
    /// Every one of these used to be `.malformedResponse`, so a download that failed for
    /// six different reasons produced one sentence and nothing to act on. The reason is a
    /// short fixed token from the list in `AorusAIClient` — never anything the server
    /// wrote — so showing it leaks nothing while making a report say what happened.
    case artifactRejected(String)
    case cancelled
    case http(Int)
}
