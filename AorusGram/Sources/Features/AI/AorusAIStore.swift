import Foundation
import CryptoKit
import Security

public final class AorusAIStore {
    public static let shared = AorusAIStore()
    public static let changedNotification = Notification.Name("aorusgram.ai.storeChanged")

    private let queue = DispatchQueue(label: "com.aorusgram.ai.store", qos: .utility)
    private let keyService = "com.aorusgram.ai.history"
    private let keyAccountPrefix = "conversation-store-key-v1"

    private enum ReadResult {
        case missing
        case conversations([AorusAIConversation])
        case corrupt
    }

    private init() {}

    public func load(accountId: Int64, completion: @escaping ([AorusAIConversation]) -> Void) {
        queue.async {
            let result: [AorusAIConversation]
            switch self.read(accountId: accountId) {
            case .missing, .corrupt:
                result = []
            case let .conversations(conversations):
                result = conversations
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func save(_ conversations: [AorusAIConversation], accountId: Int64, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            if case .corrupt = self.read(accountId: accountId) {
                self.discardUnreadable(accountId: accountId)
            }
            let result = self.write(conversations, accountId: accountId)
            DispatchQueue.main.async {
                if result {
                    NotificationCenter.default.post(name: Self.changedNotification, object: NSNumber(value: accountId))
                }
                completion?(result)
            }
        }
    }

    public func upsert(_ conversation: AorusAIConversation, accountId: Int64, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            var conversations: [AorusAIConversation]
            switch self.read(accountId: accountId) {
            case .missing:
                conversations = []
            case let .conversations(value):
                conversations = value
            case .corrupt:
                // An unreadable store (lost keychain item, interrupted write)
                // must not brick history forever: drop it and start a new one.
                self.discardUnreadable(accountId: accountId)
                conversations = []
            }
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index] = conversation
            } else {
                conversations.append(conversation)
            }
            conversations.sort { $0.updatedAt > $1.updatedAt }
            let result = self.write(conversations, accountId: accountId)
            DispatchQueue.main.async {
                if result {
                    NotificationCenter.default.post(name: Self.changedNotification, object: NSNumber(value: accountId))
                }
                completion?(result)
            }
        }
    }

    public func delete(conversationId: UUID, accountId: Int64, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let conversations: [AorusAIConversation]
            switch self.read(accountId: accountId) {
            case .missing:
                DispatchQueue.main.async { completion?(true) }
                return
            case let .conversations(value):
                conversations = value.filter { $0.id != conversationId }
            case .corrupt:
                self.discardUnreadable(accountId: accountId)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.changedNotification, object: NSNumber(value: accountId))
                    completion?(true)
                }
                return
            }
            let result = self.write(conversations, accountId: accountId)
            DispatchQueue.main.async {
                if result {
                    NotificationCenter.default.post(name: Self.changedNotification, object: NSNumber(value: accountId))
                }
                completion?(result)
            }
        }
    }

    private func discardUnreadable(accountId: Int64) {
        try? FileManager.default.removeItem(at: fileURL(accountId: accountId))
    }

    private func read(accountId: Int64) -> ReadResult {
        let url = fileURL(accountId: accountId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let sealed = try? Data(contentsOf: url),
              let keyData = encryptionKey(accountId: accountId, createIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let clear = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
              let conversations = try? JSONDecoder.aorusAI.decode([AorusAIConversation].self, from: clear) else {
            return .corrupt
        }
        return .conversations(conversations.sorted { $0.updatedAt > $1.updatedAt })
    }

    private func write(_ conversations: [AorusAIConversation], accountId: Int64) -> Bool {
        guard let keyData = encryptionKey(accountId: accountId, createIfMissing: true),
              let clear = try? JSONEncoder.aorusAI.encode(conversations),
              let sealed = try? AES.GCM.seal(clear, using: SymmetricKey(data: keyData)).combined else {
            return false
        }
        let url = fileURL(accountId: accountId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var directoryURL = url.deletingLastPathComponent()
            try? directoryURL.setResourceValues(directoryValues)
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var fileURL = url
            try? fileURL.setResourceValues(fileValues)
            return true
        } catch {
            return false
        }
    }

    private func fileURL(accountId: Int64) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AorusAI", isDirectory: true).appendingPathComponent("history-\(accountId).bin")
    }

    private func encryptionKey(accountId: Int64, createIfMissing: Bool) -> Data? {
        let keyAccount = "\(keyAccountPrefix)-\(accountId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, data.count == 32 {
            return data
        }
        guard createIfMissing else { return nil }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, baseAddress)
        }
        guard status == errSecSuccess else { return nil }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return key }
        if addStatus == errSecDuplicateItem {
            var existing: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess,
                  let data = existing as? Data,
                  data.count == 32 else {
                return nil
            }
            return data
        }
        return nil
    }
}

private extension JSONEncoder {
    static var aorusAI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var aorusAI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
