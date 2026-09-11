import Foundation
import AVFoundation
import UIKit

public enum AorusBannerPublicationMode: Equatable {
    case publicOwner
    case candidate
    case localOnly
}

public enum AorusBannerServiceError: Error, Equatable {
    case notProvisioned
    case noAuthorizedAccount
    case invalidMedia
    case uploadTooLarge
    case telegramIdMismatch
    case licenseRequired
    case rateLimited
    case busy
    case network
    case invalidResponse
    case server(Int)

    public var allowsLocalFallback: Bool {
        switch self {
        case .telegramIdMismatch, .licenseRequired, .noAuthorizedAccount:
            return true
        default:
            return false
        }
    }
}

public struct AorusBannerAsset {
    public let telegramUserId: Int64
    public let bannerId: String
    public let version: Int
    public let mediaURL: URL
    public let posterURL: URL?
    public let width: Int
    public let height: Int
    public let duration: TimeInterval
}

/// Signed client and disk cache for public animated profile backgrounds.
///
/// The server remains authoritative for ownership. A caller id is persisted only
/// after the banner service accepts a signed request for that id. This prevents a
/// secondary Telegram account on the same device from publishing over the account
/// that owns the license while still allowing that secondary account to use a
/// local-only background.
public final class AorusBannerService {
    public static let shared = AorusBannerService()
    public static let changedNotification = Notification.Name("aorusgram.publicBannerChanged")

    private static let baseURLString = "https://banner.aorusgram.com"
    private static let ownerDefaultsKey = "aorusgram_banner_authorized_owner_v1"
    private static let maximumUploadBytes = 6 * 1024 * 1024
    private static let maximumDownloadBytes = 4 * 1024 * 1024
    private static let maximumCacheBytes = 64 * 1024 * 1024

    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "com.aorusgram.banner-service.state", qos: .userInitiated)
    private let mediaQueue = DispatchQueue(label: "com.aorusgram.banner-service.media", qos: .utility)
    private var lookupCompletions: [Int64: [(Result<AorusBannerAsset?, AorusBannerServiceError>) -> Void]] = [:]
    private var rejectedCandidates = Set<Int64>()
    private var mutatingAccounts = Set<Int64>()
    private var memoryCache: [Int64: AorusBannerAsset] = [:]
    private var lookupFreshness: [Int64: (time: TimeInterval, exists: Bool)] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Uploading an animated banner sends the whole body and then waits while the
        // server transcodes it. The idle (request) timeout counts the gap with no bytes
        // flowing, so once the body is in, server-side processing that runs longer than
        // this would fire it — the server stores the banner but the client reports a
        // network failure ("sync error"). Give processing room; a genuinely dead request
        // still fails at the resource ceiling.
        configuration.timeoutIntervalForRequest = 60.0
        configuration.timeoutIntervalForResource = 180.0
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(
            configuration: configuration,
            delegate: AorusPinnedSessionDelegate.shared,
            delegateQueue: nil
        )
    }

    public func publicationMode(for accountId: Int64) -> AorusBannerPublicationMode {
        guard accountId != 0,
              AorusLicenseAccess.isAllowed else {
            return .localOnly
        }
        if let ownerId = self.authorizedOwnerId() {
            return ownerId == accountId ? .publicOwner : .localOnly
        }
        let rejected = self.stateQueue.sync { self.rejectedCandidates.contains(accountId) }
        return rejected ? .localOnly : .candidate
    }

    public func authorizedOwnerId() -> Int64? {
        guard let value = UserDefaults.standard.object(forKey: Self.ownerDefaultsKey) as? NSNumber else {
            return nil
        }
        let id = value.int64Value
        return id == 0 ? nil : id
    }

    public func cachedBanner(for targetId: Int64) -> AorusBannerAsset? {
        guard targetId != 0 else { return nil }
        return self.stateQueue.sync {
            return self.cachedAssetLocked(targetId: targetId)
        }
    }

    public func resolveBanner(
        targetId: Int64,
        preferredCallerId: Int64,
        forceRefresh: Bool = false,
        completion: @escaping (Result<AorusBannerAsset?, AorusBannerServiceError>) -> Void
    ) {
        guard targetId != 0 else {
            Self.completeOnMain(completion, with: .success(nil))
            return
        }
        guard let callerId = self.callerId(preferred: preferredCallerId) else {
            if let cached = self.cachedBanner(for: targetId) {
                Self.completeOnMain(completion, with: .success(cached))
            } else {
                Self.completeOnMain(completion, with: .failure(.noAuthorizedAccount))
            }
            return
        }

        self.stateQueue.async {
            if !forceRefresh,
               let freshness = self.lookupFreshness[targetId],
               Date().timeIntervalSinceReferenceDate - freshness.time < 60.0 {
                if !freshness.exists {
                    Self.completeOnMain(completion, with: .success(nil))
                    return
                } else if let cached = self.cachedAssetLocked(targetId: targetId) {
                    Self.completeOnMain(completion, with: .success(cached))
                    return
                }
            }
            if self.lookupCompletions[targetId] != nil {
                self.lookupCompletions[targetId]?.append(completion)
                return
            }
            self.lookupCompletions[targetId] = [completion]
            self.performMetadataLookup(targetId: targetId, callerId: callerId)
        }
    }

    public func uploadBanner(
        fileURL: URL,
        accountId: Int64,
        completion: @escaping (Result<Void, AorusBannerServiceError>) -> Void
    ) {
        let mode = self.publicationMode(for: accountId)
        guard mode != .localOnly else {
            Self.completeOnMain(completion, with: .failure(.noAuthorizedAccount))
            return
        }
        guard self.beginMutation(accountId: accountId) else {
            Self.completeOnMain(completion, with: .failure(.busy))
            return
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber else {
            self.endMutation(accountId: accountId)
            Self.completeOnMain(completion, with: .failure(.invalidMedia))
            return
        }
        guard size.intValue <= Self.maximumUploadBytes else {
            self.endMutation(accountId: accountId)
            Self.completeOnMain(completion, with: .failure(.uploadTooLarge))
            return
        }

        self.mediaQueue.async {
            guard let body = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                  !body.isEmpty else {
                self.endMutation(accountId: accountId)
                Self.completeOnMain(completion, with: .failure(.invalidMedia))
                return
            }
            self.performSignedRequest(
                method: "PUT",
                path: "/v1/banner/self",
                body: body,
                contentType: "video/mp4",
                callerId: accountId
            ) { result in
                switch result {
                case let .success((data, _)):
                    guard let metadata = self.decodeMetadata(data: data),
                          metadata.exists,
                          metadata.telegramUserId == accountId else {
                        self.endMutation(accountId: accountId)
                        Self.completeOnMain(completion, with: .failure(.invalidResponse))
                        return
                    }
                    self.acceptAuthorizedCaller(accountId)
                    self.mediaQueue.async {
                        _ = try? self.installCacheCopy(sourceURL: fileURL, metadata: metadata)
                        self.markLookupFresh(targetId: accountId, exists: true)
                        self.postChanged(targetId: accountId)
                        self.endMutation(accountId: accountId)
                        Self.completeOnMain(completion, with: .success(()))
                    }
                case let .failure(error):
                    if error == .telegramIdMismatch {
                        self.stateQueue.async {
                            self.rejectedCandidates.insert(accountId)
                        }
                    }
                    self.endMutation(accountId: accountId)
                    Self.completeOnMain(completion, with: .failure(error))
                }
            }
        }
    }

    public func deleteBanner(
        accountId: Int64,
        completion: @escaping (Result<Void, AorusBannerServiceError>) -> Void
    ) {
        let mode = self.publicationMode(for: accountId)
        guard mode != .localOnly else {
            Self.completeOnMain(completion, with: .failure(.noAuthorizedAccount))
            return
        }
        guard self.beginMutation(accountId: accountId) else {
            Self.completeOnMain(completion, with: .failure(.busy))
            return
        }
        self.performSignedRequest(
            method: "DELETE",
            path: "/v1/banner/self",
            body: Data(),
            contentType: nil,
            callerId: accountId
        ) { result in
            switch result {
            case .success:
                self.acceptAuthorizedCaller(accountId)
                self.stateQueue.async {
                    self.removeCachedBanner(targetId: accountId)
                    self.lookupFreshness[accountId] = (
                        Date().timeIntervalSinceReferenceDate,
                        false
                    )
                    self.postChanged(targetId: accountId)
                    self.endMutation(accountId: accountId)
                    Self.completeOnMain(completion, with: .success(()))
                }
            case let .failure(error):
                if error == .telegramIdMismatch {
                    self.stateQueue.async {
                        self.rejectedCandidates.insert(accountId)
                    }
                }
                self.endMutation(accountId: accountId)
                Self.completeOnMain(completion, with: .failure(error))
            }
        }
    }

    public func prewarm(accountId: Int64) {
        self.resolveBanner(targetId: accountId, preferredCallerId: accountId) { _ in }
    }

    // MARK: - Signed transport

    private func performMetadataLookup(targetId: Int64, callerId: Int64) {
        self.performSignedRequest(
            method: "GET",
            path: "/v1/banner/\(targetId)",
            body: Data(),
            contentType: nil,
            callerId: callerId
        ) { result in
            switch result {
            case let .success((data, _)):
                self.acceptAuthorizedCaller(callerId)
                guard let metadata = self.decodeMetadata(data: data),
                      metadata.telegramUserId == targetId else {
                    self.finishLookup(targetId: targetId, result: .failure(.invalidResponse))
                    return
                }
                guard metadata.exists else {
                    self.stateQueue.async {
                        self.removeCachedBanner(targetId: targetId)
                        self.lookupFreshness[targetId] = (
                            Date().timeIntervalSinceReferenceDate,
                            false
                        )
                        self.postChanged(targetId: targetId)
                        self.finishLookup(targetId: targetId, result: .success(nil))
                    }
                    return
                }
                if let cached = self.stateQueue.sync(execute: { self.cachedAssetLocked(targetId: targetId) }),
                   cached.bannerId == metadata.bannerId,
                   cached.version == metadata.version {
                    self.markLookupFresh(targetId: targetId, exists: true)
                    self.finishLookup(targetId: targetId, result: .success(cached))
                    return
                }
                guard let mediaURL = metadata.signedURL else {
                    self.finishLookup(targetId: targetId, result: .failure(.invalidResponse))
                    return
                }
                self.downloadBanner(metadata: metadata, from: mediaURL) { downloadResult in
                    switch downloadResult {
                    case let .success(asset):
                        self.markLookupFresh(targetId: targetId, exists: true)
                        self.postChanged(targetId: targetId)
                        self.finishLookup(targetId: targetId, result: .success(asset))
                    case let .failure(error):
                        if let stale = self.cachedBanner(for: targetId) {
                            self.finishLookup(targetId: targetId, result: .success(stale))
                        } else {
                            self.finishLookup(targetId: targetId, result: .failure(error))
                        }
                    }
                }
            case let .failure(error):
                if error == .telegramIdMismatch {
                    self.stateQueue.async {
                        self.rejectedCandidates.insert(callerId)
                    }
                }
                if let stale = self.cachedBanner(for: targetId) {
                    self.finishLookup(targetId: targetId, result: .success(stale))
                } else {
                    self.finishLookup(targetId: targetId, result: .failure(error))
                }
            }
        }
    }

    private func performSignedRequest(
        method: String,
        path: String,
        body: Data,
        contentType: String?,
        callerId: Int64,
        completion: @escaping (Result<(Data, HTTPURLResponse), AorusBannerServiceError>) -> Void
    ) {
        guard AorusLicenseAccess.isAllowed else {
            completion(.failure(.notProvisioned))
            return
        }
        guard let url = URL(string: Self.baseURLString + path) else {
            completion(.failure(.invalidResponse))
            return
        }

        let timestamp = String(Int64(Date().timeIntervalSince1970))
        let nonce = LicenseCrypto.randomHex(byteCount: 16)
        let device = DeviceFingerprint.deviceHash().lowercased()
        let keyVersion = LicenseKeyProvider.keyVersion
        let bodyHash = LicenseCrypto.sha256Hex(body).lowercased()
        let message = "\(timestamp)\n\(nonce)\n\(device)\n\(keyVersion)\n\(callerId)\n\(bodyHash)"
        guard let signature = LicenseKeyProvider.withLicenseHmacKey({ keyBytes in
            LicenseCrypto.hmacSHA256Hex(
                message: Data(message.utf8),
                keyBytes: keyBytes
            ).lowercased()
        }) else {
            completion(.failure(.notProvisioned))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "PUT" {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue(SubscriptionConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(timestamp, forHTTPHeaderField: "X-Aorus-Ts")
        request.setValue(nonce, forHTTPHeaderField: "X-Aorus-Nonce")
        request.setValue(device, forHTTPHeaderField: "X-Aorus-Device")
        request.setValue(keyVersion, forHTTPHeaderField: "X-Aorus-Kv")
        request.setValue(String(callerId), forHTTPHeaderField: "X-Aorus-Telegram-Id")
        request.setValue(bodyHash, forHTTPHeaderField: "X-Aorus-Body-Sha256")
        request.setValue(signature, forHTTPHeaderField: "X-Aorus-Sign")

        self.session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion(.failure(.network))
                return
            }
            let responseData = data ?? Data()
            guard (200 ..< 300).contains(http.statusCode) else {
                completion(.failure(self.mapError(statusCode: http.statusCode, data: responseData)))
                return
            }
            completion(.success((responseData, http)))
        }.resume()
    }

    private func mapError(statusCode: Int, data: Data) -> AorusBannerServiceError {
        let code: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            code = object["error"] as? String
        } else {
            code = nil
        }
        switch code {
        case "telegram_id_mismatch", "telegram_account_not_linked":
            return .telegramIdMismatch
        case "license_required", "license_expired", "device_banned":
            return .licenseRequired
        case "rate_limited":
            return .rateLimited
        case "upload_too_large", "processed_banner_too_large":
            return .uploadTooLarge
        default:
            if statusCode == 429 { return .rateLimited }
            if statusCode == 413 { return .uploadTooLarge }
            if statusCode >= 500 { return .network }
            return .server(statusCode)
        }
    }

    // MARK: - Metadata and cache

    private struct BannerMetadata {
        let exists: Bool
        let telegramUserId: Int64
        let bannerId: String
        let version: Int
        let width: Int
        let height: Int
        let durationMs: Int
        let signedURL: URL?
    }

    private struct CachedRecord: Codable {
        let telegramUserId: Int64
        let bannerId: String
        let version: Int
        let mediaFilename: String
        let posterFilename: String?
        let width: Int
        let height: Int
        let durationMs: Int
    }

    private func decodeMetadata(data: Data) -> BannerMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exists = object["exists"] as? Bool,
              let telegramId = (object["telegram_user_id"] as? NSNumber)?.int64Value else {
            return nil
        }
        if !exists {
            return BannerMetadata(
                exists: false,
                telegramUserId: telegramId,
                bannerId: "",
                version: 0,
                width: 0,
                height: 0,
                durationMs: 0,
                signedURL: nil
            )
        }
        guard let bannerId = object["banner_id"] as? String,
              !bannerId.isEmpty,
              let version = (object["version"] as? NSNumber)?.intValue,
              let width = (object["width"] as? NSNumber)?.intValue,
              let height = (object["height"] as? NSNumber)?.intValue,
              let durationMs = (object["duration_ms"] as? NSNumber)?.intValue,
              let urlString = object["url"] as? String,
              let signedURL = URL(string: urlString),
              signedURL.scheme?.lowercased() == "https",
              signedURL.host?.lowercased() == "banner.aorusgram.com" else {
            return nil
        }
        return BannerMetadata(
            exists: true,
            telegramUserId: telegramId,
            bannerId: bannerId,
            version: version,
            width: width,
            height: height,
            durationMs: durationMs,
            signedURL: signedURL
        )
    }

    private func downloadBanner(
        metadata: BannerMetadata,
        from url: URL,
        completion: @escaping (Result<AorusBannerAsset, AorusBannerServiceError>) -> Void
    ) {
        self.session.downloadTask(with: url) { temporaryURL, response, error in
            guard error == nil,
                  let temporaryURL,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.mimeType?.lowercased() == "video/mp4" else {
                completion(.failure(.network))
                return
            }
            if http.expectedContentLength > Int64(Self.maximumDownloadBytes) {
                completion(.failure(.invalidMedia))
                return
            }

            // URLSession owns temporaryURL and may remove it as soon as this
            // completion handler returns. Retain a private copy synchronously
            // before handing validation and poster generation to mediaQueue.
            let retainedURL: URL
            do {
                let directory = try self.cacheDirectoryURL()
                retainedURL = directory.appendingPathComponent(".download-\(UUID().uuidString).mp4")
                try FileManager.default.copyItem(at: temporaryURL, to: retainedURL)
            } catch {
                completion(.failure(.invalidMedia))
                return
            }
            self.mediaQueue.async {
                defer {
                    try? FileManager.default.removeItem(at: retainedURL)
                }
                do {
                    let asset = try self.installCacheCopy(sourceURL: retainedURL, metadata: metadata)
                    completion(.success(asset))
                } catch {
                    completion(.failure(.invalidMedia))
                }
            }
        }.resume()
    }

    private func installCacheCopy(sourceURL: URL, metadata: BannerMetadata) throws -> AorusBannerAsset {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumDownloadBytes else {
            throw AorusBannerServiceError.invalidMedia
        }
        let validation = try self.validateVideo(at: sourceURL)
        let directory = try self.cacheDirectoryURL()
        let token = self.safeToken(metadata.bannerId)
        let baseName = "\(self.idSuffix(metadata.telegramUserId))_\(token)_v\(metadata.version)"
        let mediaFilename = baseName + ".mp4"
        let posterFilename = baseName + ".jpg"
        let mediaURL = directory.appendingPathComponent(mediaFilename)
        let posterURL = directory.appendingPathComponent(posterFilename)
        let stagingMediaURL = directory.appendingPathComponent(".\(UUID().uuidString).mp4")
        let stagingPosterURL = directory.appendingPathComponent(".\(UUID().uuidString).jpg")

        try FileManager.default.copyItem(at: sourceURL, to: stagingMediaURL)
        do {
            try self.writePoster(videoURL: stagingMediaURL, destinationURL: stagingPosterURL)
            try self.replaceAtomically(stagingURL: stagingMediaURL, destinationURL: mediaURL)
            try self.replaceAtomically(stagingURL: stagingPosterURL, destinationURL: posterURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingMediaURL)
            try? FileManager.default.removeItem(at: stagingPosterURL)
            throw error
        }

        let record = CachedRecord(
            telegramUserId: metadata.telegramUserId,
            bannerId: metadata.bannerId,
            version: metadata.version,
            mediaFilename: mediaFilename,
            posterFilename: posterFilename,
            width: validation.width,
            height: validation.height,
            durationMs: Int((validation.duration * 1000.0).rounded())
        )
        try self.writeRecord(record, targetId: metadata.telegramUserId)
        self.removeObsoleteMedia(
            targetId: metadata.telegramUserId,
            keeping: Set([mediaFilename, posterFilename])
        )
        let installedAsset = self.asset(from: record, directory: directory)
        self.stateQueue.sync {
            self.memoryCache[metadata.telegramUserId] = installedAsset
        }
        self.pruneCache(keepingTargetId: metadata.telegramUserId)
        return installedAsset
    }

    private func validateVideo(at url: URL) throws -> (width: Int, height: Int, duration: TimeInterval) {
        let asset = AVURLAsset(url: url)
        guard asset.tracks(withMediaType: .audio).isEmpty,
              let track = asset.tracks(withMediaType: .video).first else {
            throw AorusBannerServiceError.invalidMedia
        }
        let duration = CMTimeGetSeconds(asset.duration)
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        guard duration.isFinite,
              duration > 0.0,
              duration <= 30.05,
              width > 0,
              height > 0,
              width <= 1280,
              height <= 1280 else {
            throw AorusBannerServiceError.invalidMedia
        }
        return (width, height, duration)
    }

    private func writePoster(videoURL: URL, destinationURL: URL) throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280.0, height: 720.0)
        let requestedTime = CMTime(seconds: 0.05, preferredTimescale: 600)
        let cgImage: CGImage
        if let image = try? generator.copyCGImage(at: requestedTime, actualTime: nil) {
            cgImage = image
        } else {
            cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.86) else {
            throw AorusBannerServiceError.invalidMedia
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    private func loadCachedAsset(targetId: Int64) -> AorusBannerAsset? {
        guard let directory = try? self.cacheDirectoryURL(),
              let data = try? Data(contentsOf: self.recordURL(targetId: targetId, directory: directory)),
              let record = try? JSONDecoder().decode(CachedRecord.self, from: data),
              record.telegramUserId == targetId else {
            return nil
        }
        let asset = self.asset(from: record, directory: directory)
        guard FileManager.default.fileExists(atPath: asset.mediaURL.path) else {
            return nil
        }
        return asset
    }

    private func cachedAssetLocked(targetId: Int64) -> AorusBannerAsset? {
        if let asset = self.memoryCache[targetId],
           FileManager.default.fileExists(atPath: asset.mediaURL.path) {
            return asset
        }
        let asset = self.loadCachedAsset(targetId: targetId)
        self.memoryCache[targetId] = asset
        return asset
    }

    private func asset(from record: CachedRecord, directory: URL) -> AorusBannerAsset {
        let posterURL = record.posterFilename.map { directory.appendingPathComponent($0) }
        return AorusBannerAsset(
            telegramUserId: record.telegramUserId,
            bannerId: record.bannerId,
            version: record.version,
            mediaURL: directory.appendingPathComponent(record.mediaFilename),
            posterURL: posterURL,
            width: record.width,
            height: record.height,
            duration: Double(record.durationMs) / 1000.0
        )
    }

    private func writeRecord(_ record: CachedRecord, targetId: Int64) throws {
        let directory = try self.cacheDirectoryURL()
        let data = try JSONEncoder().encode(record)
        try data.write(to: self.recordURL(targetId: targetId, directory: directory), options: .atomic)
    }

    private func removeCachedBanner(targetId: Int64) {
        self.memoryCache.removeValue(forKey: targetId)
        guard let directory = try? self.cacheDirectoryURL() else { return }
        if let data = try? Data(contentsOf: self.recordURL(targetId: targetId, directory: directory)),
           let record = try? JSONDecoder().decode(CachedRecord.self, from: data) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.mediaFilename))
            if let posterFilename = record.posterFilename {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(posterFilename))
            }
        }
        try? FileManager.default.removeItem(at: self.recordURL(targetId: targetId, directory: directory))
        self.removeObsoleteMedia(targetId: targetId, keeping: [])
    }

    private func removeObsoleteMedia(targetId: Int64, keeping filenames: Set<String>) {
        guard let directory = try? self.cacheDirectoryURL(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let prefix = self.idSuffix(targetId) + "_"
        for filename in files where filename.hasPrefix(prefix) && !filenames.contains(filename) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        }
    }

    private func pruneCache(keepingTargetId: Int64) {
        guard let directory = try? self.cacheDirectoryURL(),
              let filenames = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        var entries: [(record: CachedRecord, recordURL: URL, size: Int64, date: Date)] = []
        var totalSize: Int64 = 0
        for filename in filenames where filename.hasPrefix("target-") && filename.hasSuffix(".json") {
            let recordURL = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(CachedRecord.self, from: data) else {
                continue
            }
            let mediaURL = directory.appendingPathComponent(record.mediaFilename)
            let posterURL = record.posterFilename.map { directory.appendingPathComponent($0) }
            var entrySize: Int64 = 0
            if let value = (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size]) as? NSNumber {
                entrySize += value.int64Value
            }
            if let posterURL,
               let value = (try? FileManager.default.attributesOfItem(atPath: posterURL.path)[.size]) as? NSNumber {
                entrySize += value.int64Value
            }
            let date = ((try? FileManager.default.attributesOfItem(atPath: recordURL.path)[.modificationDate]) as? Date) ?? .distantPast
            totalSize += entrySize
            entries.append((record, recordURL, entrySize, date))
        }
        guard totalSize > Int64(Self.maximumCacheBytes) else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard totalSize > Int64(Self.maximumCacheBytes),
                  entry.record.telegramUserId != keepingTargetId else {
                continue
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.record.mediaFilename))
            if let posterFilename = entry.record.posterFilename {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(posterFilename))
            }
            try? FileManager.default.removeItem(at: entry.recordURL)
            totalSize -= entry.size
            self.stateQueue.sync {
                self.memoryCache[entry.record.telegramUserId] = nil
            }
        }
    }

    private func cacheDirectoryURL() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = root.appendingPathComponent("AorusGram/PublicBanners", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
        return directory
    }

    private func recordURL(targetId: Int64, directory: URL) -> URL {
        return directory.appendingPathComponent("target-\(self.idSuffix(targetId)).json")
    }

    private func replaceAtomically(stagingURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    private func safeToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return String(value.prefix(64))
        }
        return String(LicenseCrypto.sha256Hex(Data(value.utf8)).prefix(32))
    }

    private func idSuffix(_ id: Int64) -> String {
        return String(id).replacingOccurrences(of: "-", with: "m")
    }

    // MARK: - State helpers

    private func callerId(preferred: Int64) -> Int64? {
        if let owner = self.authorizedOwnerId() {
            return owner
        }
        if preferred != 0 {
            return preferred
        }
        return LicenseStore.shared.telegramUserId
    }

    private func beginMutation(accountId: Int64) -> Bool {
        return self.stateQueue.sync {
            if self.mutatingAccounts.contains(accountId) {
                return false
            }
            self.mutatingAccounts.insert(accountId)
            return true
        }
    }

    private func markLookupFresh(targetId: Int64, exists: Bool) {
        self.stateQueue.async {
            self.lookupFreshness[targetId] = (
                Date().timeIntervalSinceReferenceDate,
                exists
            )
        }
    }

    private func endMutation(accountId: Int64) {
        self.stateQueue.async {
            self.mutatingAccounts.remove(accountId)
        }
    }

    private func acceptAuthorizedCaller(_ id: Int64) {
        guard id != 0 else { return }
        UserDefaults.standard.set(NSNumber(value: id), forKey: Self.ownerDefaultsKey)
        self.stateQueue.async {
            self.rejectedCandidates.remove(id)
        }
    }

    private func finishLookup(
        targetId: Int64,
        result: Result<AorusBannerAsset?, AorusBannerServiceError>
    ) {
        self.stateQueue.async {
            let completions = self.lookupCompletions.removeValue(forKey: targetId) ?? []
            for completion in completions {
                Self.completeOnMain(completion, with: result)
            }
        }
    }

    private func postChanged(targetId: Int64) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.changedNotification,
                object: nil,
                userInfo: ["targetId": targetId]
            )
        }
    }

    private static func completeOnMain<T>(
        _ completion: @escaping (Result<T, AorusBannerServiceError>) -> Void,
        with result: Result<T, AorusBannerServiceError>
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
