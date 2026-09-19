import Foundation

// The data model of a plugin: what is stored on disk, what the editor edits and what the
// runtime loads. Nothing here touches the sandbox or the UI; the file compiles on its own
// with Foundation, which is how the preflight tests build it.

// Nothing here holds display text. Every string the plugin screens show is written at the
// call site in the UI module through `aorusL(ru, en)`, so it goes through the one table the
// release verifier walks and is present in all 32 further languages.

/// The glyphs a plugin may pick for its tile. SF Symbol names; a name the running iOS does
/// not know falls back to `fallback` at draw time, so the list can hold newer symbols.
public enum AorusPluginIcon {
    public static let all: [String] = [
        "puzzlepiece.extension", "bolt.fill", "sparkles", "message.fill", "shield.fill",
        "globe", "terminal.fill", "clock.fill", "wand.and.stars", "heart.fill", "star.fill",
        "bell.fill", "text.bubble.fill", "arrow.triangle.2.circlepath", "lock.fill",
        "paperplane.fill", "brain.head.profile", "camera.fill", "mic.fill", "play.fill",
        "music.note", "doc.fill", "folder.fill", "link", "bookmark.fill", "person.fill",
        "person.2.fill", "gearshape.fill", "slider.horizontal.3", "checkmark.circle.fill",
        "square.and.pencil", "command", "curlybraces", "network", "photo.fill", "calendar",
        "location.fill", "map.fill", "cart.fill", "creditcard.fill", "gamecontroller.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "lightbulb.fill", "flame.fill",
    ]
    public static let fallback = "puzzlepiece.extension"

    public static func normalized(_ value: String) -> String {
        return all.contains(value) ? value : fallback
    }
}

/// Tile colours, as "RRGGBB".
public enum AorusPluginAccent {
    public static let all: [String] = [
        "5B4DFF", "7C3AED", "BF5AF2", "FF2D92", "FF375F", "FF453A", "FF9F0A", "FFD60A",
        "30D158", "34C759", "00C7BE", "64D2FF", "0A84FF", "007AFF", "5E5CE6", "8E8E93",
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
    case customUI
    case settingsIntegration
    case contextMenu
    case inAppBrowser
    case artificialIntelligence

    public static func requestedBySource(_ source: String) -> Set<AorusPluginPermission> {
        let probes: [(AorusPluginPermission, [String])] = [
            (.network, ["aorus.http"]),
            (.sendMessages, ["aorus.messages.send"]),
            (.chatMetadata, ["aorus.chats.resolve", "aorus.chats.get"]),
            (.openChats, ["aorus.chats.open", "aorus.app.openChat"]),
            (.accountProfile, ["aorus.account.current", "aorus.app.currentAccount"]),
            (.dialogs, ["aorus.ui.alert", "aorus.ui.confirm", "aorus.ui.prompt", "aorus.ui.share", "aorus.app.share"]),
            (.clipboardRead, ["aorus.clipboard.read"]),
            (.clipboardWrite, ["aorus.clipboard.write"]),
            (.incomingMessages, ["aorus.on('message'", "aorus.on(\"message\"", "aorus.once('message'", "aorus.once(\"message\""]),
            (.outgoingMessages, ["aorus.on('send'", "aorus.on(\"send\"", "aorus.once('send'", "aorus.once(\"send\"", "aorus.commands.register"]),
            (.customUI, ["aorus.ui.definePages", "aorus.ui.createPage", "aorus.ui.openPage", "aorus.ui.presentPage"]),
            (.settingsIntegration, ["aorus.integrations.settings.register"]),
            (.contextMenu, ["aorus.integrations.contextMenu.register"]),
            (.inAppBrowser, [
                "aorus.browser.open", "aorus.ui.openURL", "aorus.app.openURL",
                "type: 'link'", "type: \"link\"", "\"type\":\"link\"",
                "url:", "url :", ".link({",
            ]),
            (.artificialIntelligence, ["aorus.ai."]),
        ]
        return Set(probes.compactMap { permission, needles in
            needles.contains(where: source.contains) ? permission : nil
        })
    }
}

/// Native plugin UI is declarative. JavaScript supplies this bounded data and the app owns
/// every view and interaction; no UIKit object or selector ever crosses the sandbox boundary.
public struct AorusPluginUIPage: Codable, Equatable {
    public struct Section: Codable, Equatable {
        public var title: String?
        public var footer: String?
        public var rows: [Row]

        public init(title: String? = nil, footer: String? = nil, rows: [Row]) {
            self.title = title
            self.footer = footer
            self.rows = rows
        }
    }

    public struct Row: Codable, Equatable {
        public enum Kind: String, Codable {
            case text
            case button
            case toggle
            case input
            case multiline
            case number
            case select
            case link
            case slider
            case stepper
        }

        public var id: String
        public var kind: Kind
        public var title: String
        public var subtitle: String?
        public var icon: String?
        public var value: AorusPluginJSONValue?
        public var options: [AorusPluginSettingField.Option]?
        public var url: String?
        public var minimum: Double?
        public var maximum: Double?
        public var step: Double?
        public var destructive: Bool

        public init(id: String, kind: Kind, title: String, subtitle: String? = nil, icon: String? = nil, value: AorusPluginJSONValue? = nil, options: [AorusPluginSettingField.Option]? = nil, url: String? = nil, minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil, destructive: Bool = false) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.value = value
            self.options = options
            self.url = url
            self.minimum = minimum
            self.maximum = maximum
            self.step = step
            self.destructive = destructive
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case kind = "type"
            case title
            case subtitle
            case icon
            case value
            case options
            case url
            case minimum = "min"
            case maximum = "max"
            case step
            case destructive
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = try container.decode(Kind.self, forKey: .kind)
            title = try container.decode(String.self, forKey: .title)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            value = try container.decodeIfPresent(AorusPluginJSONValue.self, forKey: .value)
            options = try container.decodeIfPresent([AorusPluginSettingField.Option].self, forKey: .options)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
            maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
            step = try container.decodeIfPresent(Double.self, forKey: .step)
            destructive = try container.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        }
    }

    public var id: String
    public var title: String
    public var sections: [Section]

    public init(id: String, title: String, sections: [Section]) {
        self.id = id
        self.title = title
        self.sections = sections
    }

    public static func validated(from data: Data) -> [AorusPluginUIPage]? {
        guard data.count <= 128 * 1024,
              var pages = try? JSONDecoder().decode([AorusPluginUIPage].self, from: data),
              pages.count <= 12 else {
            return nil
        }
        let identifier = try? NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,64}$")
        var pageIds = Set<String>()
        for pageIndex in pages.indices {
            var page = pages[pageIndex]
            guard identifier?.firstMatch(in: page.id, range: NSRange(location: 0, length: page.id.utf16.count)) != nil,
                  pageIds.insert(page.id).inserted,
                  !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            page.title = String(page.title.prefix(80))
            page.sections = Array(page.sections.prefix(16))
            var rowIds = Set<String>()
            var rowCount = 0
            for sectionIndex in page.sections.indices {
                var section = page.sections[sectionIndex]
                section.title = section.title.map { String($0.prefix(80)) }
                section.footer = section.footer.map { String($0.prefix(500)) }
                section.rows = Array(section.rows.prefix(32))
                rowCount += section.rows.count
                guard rowCount <= 128 else { return nil }
                for rowIndex in section.rows.indices {
                    var row = section.rows[rowIndex]
                    guard identifier?.firstMatch(in: row.id, range: NSRange(location: 0, length: row.id.utf16.count)) != nil,
                          rowIds.insert(row.id).inserted,
                          !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    row.title = String(row.title.prefix(120))
                    row.subtitle = row.subtitle.map { String($0.prefix(300)) }
                    row.icon = row.icon.map { AorusPluginIcon.normalized($0) }
                    row.url = row.url.map { String($0.prefix(2_048)) }
                    row.options = row.options.map { Array($0.prefix(64)).map { option in
                        AorusPluginSettingField.Option(value: String(option.value.prefix(256)), title: String(option.title.prefix(120)))
                    } }
                    if case let .string(value)? = row.value {
                        row.value = .string(String(value.prefix(16_384)))
                    } else if case .array? = row.value {
                        return nil
                    } else if case .object? = row.value {
                        return nil
                    }
                    if row.kind == .link {
                        guard let value = row.url, let url = URL(string: value),
                              let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
                              url.host?.isEmpty == false else { return nil }
                    }
                    if row.kind == .slider || row.kind == .stepper {
                        let minimum = row.minimum ?? 0
                        let maximum = row.maximum ?? 100
                        let step = row.step ?? 1
                        guard minimum.isFinite, maximum.isFinite, step.isFinite,
                              abs(minimum) <= 1_000_000_000, abs(maximum) <= 1_000_000_000,
                              minimum < maximum, step > 0, step <= maximum - minimum else { return nil }
                        row.minimum = minimum
                        row.maximum = maximum
                        row.step = step
                        let current = row.value?.doubleValue ?? minimum
                        row.value = .number(min(maximum, max(minimum, current)))
                    }
                    section.rows[rowIndex] = row
                }
                page.sections[sectionIndex] = section
            }
            pages[pageIndex] = page
        }
        return pages
    }
}

public struct AorusPluginSettingsShortcut: Codable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var pageId: String?
    public var url: String?

    public init(id: String, title: String, subtitle: String? = nil, icon: String? = nil, pageId: String? = nil, url: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.pageId = pageId
        self.url = url
    }

    public static func validated(from data: Data) -> [AorusPluginSettingsShortcut]? {
        guard data.count <= 64 * 1024,
              var items = try? JSONDecoder().decode([AorusPluginSettingsShortcut].self, from: data),
              items.count <= 24 else { return nil }
        let identifier = try? NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,64}$")
        var ids = Set<String>()
        for index in items.indices {
            var item = items[index]
            guard identifier?.firstMatch(in: item.id, range: NSRange(location: 0, length: item.id.utf16.count)) != nil,
                  ids.insert(item.id).inserted,
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (item.pageId != nil) != (item.url != nil) else { return nil }
            if let pageId = item.pageId,
               identifier?.firstMatch(in: pageId, range: NSRange(location: 0, length: pageId.utf16.count)) == nil { return nil }
            item.title = String(item.title.prefix(120))
            item.subtitle = item.subtitle.map { String($0.prefix(240)) }
            item.icon = item.icon.map { AorusPluginIcon.normalized($0) }
            item.url = item.url.map { String($0.prefix(2_048)) }
            if let value = item.url {
                guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"), url.host?.isEmpty == false else { return nil }
            }
            items[index] = item
        }
        return items
    }
}

public struct AorusPluginContextAction: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?

    public init(id: String, title: String, icon: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
    }

    public static func validated(from data: Data) -> [AorusPluginContextAction]? {
        guard data.count <= 32 * 1024,
              var items = try? JSONDecoder().decode([AorusPluginContextAction].self, from: data),
              items.count <= 8 else { return nil }
        let identifier = try? NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,64}$")
        var ids = Set<String>()
        for index in items.indices {
            var item = items[index]
            guard identifier?.firstMatch(in: item.id, range: NSRange(location: 0, length: item.id.utf16.count)) != nil,
                  ids.insert(item.id).inserted,
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            item.title = String(item.title.prefix(80))
            item.icon = item.icon.map { AorusPluginIcon.normalized($0) }
            items[index] = item
        }
        return items
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

/// A settings schema belongs to the exact source revision that declared it. Keeping the
/// digest beside the fields prevents a stale form from surviving a source edit.
public struct AorusPluginSchemaState: Codable, Equatable {
    public var sourceDigest: String
    public var fields: [AorusPluginSettingField]

    public init(sourceDigest: String, fields: [AorusPluginSettingField]) {
        self.sourceDigest = sourceDigest
        self.fields = Array(fields.prefix(64))
    }
}

/// Any JSON value. Plugin storage and settings are JSON, and a typed representation keeps
/// `Any` out of Codable paths. Export decoding retains the field for compatibility, but new
/// exports deliberately leave installation-owned settings empty.
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

// What a plugin reaches for is read off its source by `AorusPluginPermission.requestedBySource`
// and shown on the permission sheet. An earlier, coarser scanner lived here as well; it was
// never called, and keeping a second list of needles next to the one the consent sheet uses
// is how a later edit ends up asking for less than the plugin actually does.
