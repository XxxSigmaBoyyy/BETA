import Foundation

// The data model of a plugin: what is stored on disk, what the editor edits and what the
// runtime loads. Nothing here touches the sandbox or the UI; the file compiles on its own
// with Foundation, which is how the preflight tests build it.

/// A Russian/English pair for text the core module has to show or hand to the UI.
///
/// Deliberately not named like the UI module's translation helpers: the release verifier
/// scans `t(ru, en)` and `aorusL(ru, en)` and requires a translation in every language
/// for each. The plugin documentation and the starter templates are technical prose kept in
/// the two primary languages, and any other language reads the English.
public struct AorusPluginText: Equatable {
    public let ru: String
    public let en: String

    public init(ru: String, en: String) {
        self.ru = ru
        self.en = en
    }

    public func resolved(isRussian: Bool) -> String {
        return isRussian ? ru : en
    }
}

/// The glyphs a plugin may pick for its tile. SF Symbol names; a name the running iOS does
/// not know falls back to `fallback` at draw time, so the list can hold newer symbols.
public enum AorusPluginIcon {
    public static let all: [String] = [
        "puzzlepiece.extension", "bolt.fill", "sparkles", "message.fill", "shield.fill",
        "globe", "terminal.fill", "clock.fill", "wand.and.stars", "heart.fill", "star.fill",
        "bell.fill", "text.bubble.fill", "arrow.triangle.2.circlepath", "lock.fill",
        "paperplane.fill",
    ]
    public static let fallback = "puzzlepiece.extension"

    public static func normalized(_ value: String) -> String {
        return all.contains(value) ? value : fallback
    }
}

/// Tile colours, as "RRGGBB".
public enum AorusPluginAccent {
    public static let all: [String] = [
        "5B4DFF", "0A84FF", "30D158", "FF9F0A", "FF375F", "BF5AF2", "64D2FF", "FFD60A",
    ]
    public static let fallback = "5B4DFF"

    public static func normalized(_ value: String) -> String {
        return all.contains(value.uppercased()) ? value.uppercased() : fallback
    }
}

public struct AorusPluginManifest: Codable, Equatable {
    public static let currentApiVersion = 1

    public var id: String
    public var name: String
    public var summary: String
    public var version: String
    public var author: String
    public var icon: String
    public var accent: String
    public var isEnabled: Bool
    public var autostart: Bool
    public var apiVersion: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        summary: String = "",
        version: String = "1.0.0",
        author: String = "",
        icon: String = AorusPluginIcon.fallback,
        accent: String = AorusPluginAccent.fallback,
        isEnabled: Bool = false,
        autostart: Bool = true
    ) {
        let now = Date()
        self.id = UUID().uuidString
        self.name = name
        self.summary = summary
        self.version = version
        self.author = author
        self.icon = AorusPluginIcon.normalized(icon)
        self.accent = AorusPluginAccent.normalized(accent)
        self.isEnabled = isEnabled
        self.autostart = autostart
        self.apiVersion = AorusPluginManifest.currentApiVersion
        self.createdAt = now
        self.updatedAt = now
    }

    /// Decoding tolerates a manifest written by hand or by an older build: every field but
    /// the name has a default, and the icon and colour are brought back onto the known lists.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decode(String.self, forKey: .name)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        self.author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        self.icon = AorusPluginIcon.normalized(try container.decodeIfPresent(String.self, forKey: .icon) ?? AorusPluginIcon.fallback)
        self.accent = AorusPluginAccent.normalized(try container.decodeIfPresent(String.self, forKey: .accent) ?? AorusPluginAccent.fallback)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.autostart = try container.decodeIfPresent(Bool.self, forKey: .autostart) ?? true
        self.apiVersion = try container.decodeIfPresent(Int.self, forKey: .apiVersion) ?? AorusPluginManifest.currentApiVersion
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt
    }
}

/// A plugin as the editor and the runtime see it: its manifest and its one source file.
public struct AorusPluginRecord: Equatable {
    public var manifest: AorusPluginManifest
    public var source: String

    public init(manifest: AorusPluginManifest, source: String) {
        self.manifest = manifest
        self.source = source
    }
}

/// Capabilities which cross the boundary between an isolated JavaScript context and the app.
/// A grant is stored by the installation, never inside an exported plugin bundle.
public enum AorusPluginPermission: String, Codable, CaseIterable, Hashable {
    case network
    case sendMessages
    case chatMetadata
    case openChats
    case accountProfile
    case dialogs
    case clipboardRead
    case clipboardWrite
    case incomingMessages
    case outgoingMessages

    public static func requestedBySource(_ source: String) -> Set<AorusPluginPermission> {
        let probes: [(AorusPluginPermission, [String])] = [
            (.network, ["aorus.http"]),
            (.sendMessages, ["aorus.messages.send"]),
            (.chatMetadata, ["aorus.chats.resolve", "aorus.chats.get"]),
            (.openChats, ["aorus.chats.open"]),
            (.accountProfile, ["aorus.account.current"]),
            (.dialogs, ["aorus.ui.alert", "aorus.ui.confirm", "aorus.ui.prompt"]),
            (.clipboardRead, ["aorus.clipboard.read"]),
            (.clipboardWrite, ["aorus.clipboard.write"]),
            (.incomingMessages, ["aorus.on('message'", "aorus.on(\"message\"", "aorus.once('message'", "aorus.once(\"message\""]),
            (.outgoingMessages, ["aorus.on('send'", "aorus.on(\"send\"", "aorus.once('send'", "aorus.once(\"send\"", "aorus.commands.register"]),
        ]
        return Set(probes.compactMap { permission, needles in
            needles.contains(where: source.contains) ? permission : nil
        })
    }
}

public struct AorusPluginPermissionState: Codable, Equatable {
    public var sourceDigest: String
    public var granted: Set<AorusPluginPermission>

    public init(sourceDigest: String = "", granted: Set<AorusPluginPermission> = []) {
        self.sourceDigest = sourceDigest
        self.granted = granted
    }
}

/// Any JSON value. The plugin storage, the plugin settings and the export bundle are all
/// JSON, and a typed representation keeps `Any` out of Codable paths.
public enum AorusPluginJSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AorusPluginJSONValue])
    case object([String: AorusPluginJSONValue])

    /// From a Foundation JSON object (`JSONSerialization` output or a JavaScriptCore
    /// `toObject()`), or nil when a value is not representable in JSON.
    public init?(any value: Any?) {
        guard let value = value else {
            self = .null
            return
        }
        if value is NSNull {
            self = .null
        } else if let string = value as? String {
            self = .string(string)
        } else if let number = value as? NSNumber {
            // A JSON boolean comes back as an NSNumber whose ObjC type is the boolean
            // encoding; every other numeric encoding is a number.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        } else if let bool = value as? Bool {
            self = .bool(bool)
        } else if let array = value as? [Any] {
            var items: [AorusPluginJSONValue] = []
            items.reserveCapacity(array.count)
            for item in array {
                guard let converted = AorusPluginJSONValue(any: item) else { return nil }
                items.append(converted)
            }
            self = .array(items)
        } else if let dictionary = value as? [String: Any] {
            var items: [String: AorusPluginJSONValue] = [:]
            for (key, item) in dictionary {
                guard let converted = AorusPluginJSONValue(any: item) else { return nil }
                items[key] = converted
            }
            self = .object(items)
        } else {
            return nil
        }
    }

    /// Back to a Foundation JSON object.
    public var anyValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return NSNumber(value: value)
        case let .bool(value): return NSNumber(value: value)
        case .null: return NSNull()
        case let .array(items): return items.map { $0.anyValue }
        case let .object(items):
            var result: [String: Any] = [:]
            for (key, item) in items {
                result[key] = item.anyValue
            }
            return result
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Serialised as compact JSON. A top-level string or number is written as a JSON
    /// fragment, which `JSONSerialization` accepts on both sides.
    public func serialized() -> Data {
        let object = anyValue
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) {
            return data
        }
        return Data("null".utf8)
    }

    public static func parse(_ data: Data) -> AorusPluginJSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return AorusPluginJSONValue(any: object)
    }
}

extension AorusPluginJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AorusPluginJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AorusPluginJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(items): try container.encode(items)
        case let .object(items): try container.encode(items)
        }
    }
}

/// One field of the settings form a plugin declares with `aorus.settings.define`.
public struct AorusPluginSettingField: Codable, Equatable {
    public enum Kind: String, Codable {
        case toggle
        case text
        case multiline
        case number
        case select
    }

    public struct Option: Codable, Equatable {
        public var value: String
        public var title: String

        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public var key: String
    public var kind: Kind
    public var title: String
    public var summary: String?
    public var defaultValue: AorusPluginJSONValue?
    public var options: [Option]?
    public var minimum: Double?
    public var maximum: Double?
    public var placeholder: String?

    public init(key: String, kind: Kind, title: String, summary: String? = nil, defaultValue: AorusPluginJSONValue? = nil, options: [Option]? = nil, minimum: Double? = nil, maximum: Double? = nil, placeholder: String? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.summary = summary
        self.defaultValue = defaultValue
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.placeholder = placeholder
    }

    /// From the object a plugin passes to `aorus.settings.define`. The JavaScript side
    /// spells the keys `type`, `description`, `default`, `min`, `max`; anything malformed
    /// is dropped rather than failing the whole schema.
    public init?(definition: [String: Any]) {
        guard let key = definition["key"] as? String, !key.isEmpty,
              let rawKind = definition["type"] as? String,
              let kind = Kind(rawValue: rawKind) else {
            return nil
        }
        self.key = key
        self.kind = kind
        self.title = (definition["title"] as? String) ?? key
        self.summary = definition["description"] as? String
        self.defaultValue = AorusPluginJSONValue(any: definition["default"])
        if let rawOptions = definition["options"] as? [[String: Any]] {
            self.options = rawOptions.compactMap { raw in
                guard let value = raw["value"] else { return nil }
                let valueText: String
                if let string = value as? String {
                    valueText = string
                } else if let number = value as? NSNumber {
                    valueText = number.stringValue
                } else {
                    return nil
                }
                return Option(value: valueText, title: (raw["title"] as? String) ?? valueText)
            }
        } else {
            self.options = nil
        }
        self.minimum = (definition["min"] as? NSNumber)?.doubleValue
        self.maximum = (definition["max"] as? NSNumber)?.doubleValue
        self.placeholder = definition["placeholder"] as? String
    }

    public static func schema(from definitions: [Any]) -> [AorusPluginSettingField] {
        var seen = Set<String>()
        var fields: [AorusPluginSettingField] = []
        let allowedKey = try? NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,64}$")
        for raw in definitions.prefix(64) {
            guard let dictionary = raw as? [String: Any], var field = AorusPluginSettingField(definition: dictionary),
                  allowedKey?.firstMatch(in: field.key, range: NSRange(location: 0, length: field.key.utf16.count)) != nil else {
                continue
            }
            field.title = String(field.title.prefix(120))
            field.summary = field.summary.map { String($0.prefix(300)) }
            field.placeholder = field.placeholder.map { String($0.prefix(200)) }
            field.options = field.options.map { options in
                options.prefix(100).map { Option(value: String($0.value.prefix(256)), title: String($0.title.prefix(120))) }
            }
            if seen.insert(field.key).inserted {
                fields.append(field)
            }
        }
        return fields
    }
}

public struct AorusPluginLogEntry: Equatable {
    public enum Level: String, Codable {
        case debug
        case info
        case warn
        case error
    }

    public var date: Date
    public var level: Level
    public var text: String

    public init(date: Date = Date(), level: Level, text: String) {
        self.date = date
        self.level = level
        self.text = text
    }
}

public struct AorusPluginDiagnostic: Equatable {
    public enum Severity: Equatable {
        case error
        case warning
    }

    /// 1-based.
    public var line: Int
    /// 1-based, when the parser reports one.
    public var column: Int?
    public var message: String
    public var severity: Severity

    public init(line: Int, column: Int? = nil, message: String, severity: Severity = .error) {
        self.line = max(1, line)
        self.column = column
        self.message = message
        self.severity = severity
    }
}

/// The `.aorusplugin` bundle: a plugin as a single JSON document that can be shared and
/// imported on another device. The identity, the switches and the dates are not part of it,
/// because they belong to the installation, not to the plugin.
public struct AorusPluginExport: Codable, Equatable {
    public static let format = "aorusgram-plugin"
    public static let formatVersion = 1

    public var format: String
    public var version: Int
    public var name: String
    public var summary: String
    public var pluginVersion: String
    public var author: String
    public var icon: String
    public var accent: String
    public var source: String
    public var settings: [String: AorusPluginJSONValue]

    public init(record: AorusPluginRecord, settings: [String: AorusPluginJSONValue]) {
        self.format = AorusPluginExport.format
        self.version = AorusPluginExport.formatVersion
        self.name = record.manifest.name
        self.summary = record.manifest.summary
        self.pluginVersion = record.manifest.version
        self.author = record.manifest.author
        self.icon = record.manifest.icon
        self.accent = record.manifest.accent
        self.source = record.source
        self.settings = settings
    }

    public func makeManifest() -> AorusPluginManifest {
        return AorusPluginManifest(name: name, summary: summary, version: pluginVersion, author: author, icon: icon, accent: accent)
    }
}

/// What a plugin reaches for, read off its source without running it. Shown on the plugin's
/// card so the person installing something they did not write can see what it does before
/// switching it on.
public struct AorusPluginCapability: Equatable {
    public let id: String
    public let title: AorusPluginText

    public static let network = AorusPluginCapability(id: "network", title: AorusPluginText(ru: "Сеть", en: "Network"))
    public static let sendsMessages = AorusPluginCapability(id: "send", title: AorusPluginText(ru: "Отправка сообщений", en: "Sends messages"))
    public static let clipboard = AorusPluginCapability(id: "clipboard", title: AorusPluginText(ru: "Буфер обмена", en: "Clipboard"))
    public static let opensChats = AorusPluginCapability(id: "openChats", title: AorusPluginText(ru: "Открытие чатов", en: "Opens chats"))
    public static let dialogs = AorusPluginCapability(id: "ui", title: AorusPluginText(ru: "Диалоги и уведомления", en: "Alerts and toasts"))
    public static let storage = AorusPluginCapability(id: "storage", title: AorusPluginText(ru: "Хранилище", en: "Storage"))
    public static let commands = AorusPluginCapability(id: "commands", title: AorusPluginText(ru: "Команды в чате", en: "Chat commands"))
    public static let outgoing = AorusPluginCapability(id: "outgoing", title: AorusPluginText(ru: "Исходящие сообщения", en: "Outgoing messages"))
    public static let incoming = AorusPluginCapability(id: "incoming", title: AorusPluginText(ru: "Входящие сообщения", en: "Incoming messages"))

    private static let probes: [(AorusPluginCapability, [String])] = [
        (.network, ["aorus.http"]),
        (.sendsMessages, ["aorus.messages.send"]),
        (.clipboard, ["aorus.clipboard"]),
        (.opensChats, ["aorus.chats.open"]),
        (.dialogs, ["aorus.ui"]),
        (.storage, ["aorus.storage"]),
        (.commands, ["aorus.commands.register"]),
        (.outgoing, ["aorus.on('send'", "aorus.on(\"send\"", "aorus.once('send'", "aorus.once(\"send\""]),
        (.incoming, ["aorus.on('message'", "aorus.on(\"message\"", "aorus.once('message'", "aorus.once(\"message\""]),
    ]

    public static func scan(_ source: String) -> [AorusPluginCapability] {
        var found: [AorusPluginCapability] = []
        for (capability, needles) in probes {
            if needles.contains(where: { source.contains($0) }) {
                found.append(capability)
            }
        }
        return found
    }
}
