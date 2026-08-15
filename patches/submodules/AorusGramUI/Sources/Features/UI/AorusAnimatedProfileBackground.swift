import Foundation
import UIKit
import AVFoundation
import Photos
import ImageIO
import ComponentFlow
import TelegramPresentationData
import Display
import AorusGram

// MARK: - Persistent state

public enum AorusAnimatedProfileBackgroundStore {
    public static let changedNotification = Notification.Name("aorusgram.animatedProfileBackgroundChanged")

    private static let enabledPrefix = "aorusgram_profile_background_enabled_"
    private static let transparencyPrefix = "aorusgram_profile_background_transparency_"
    private static let revisionPrefix = "aorusgram_profile_background_revision_"
    private static let stateLock = NSLock()
    private static var transientTransparency: [Int64: CGFloat] = [:]

    private static func suffix(_ accountId: Int64) -> String {
        return String(accountId).replacingOccurrences(of: "-", with: "m")
    }

    private static func key(_ prefix: String, accountId: Int64) -> String {
        return prefix + suffix(accountId)
    }

    private static func directoryURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("AorusGram/ProfileBackgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func mediaURL(accountId: Int64) -> URL? {
        guard let directory = try? directoryURL() else {
            return nil
        }
        return directory.appendingPathComponent("profile-\(suffix(accountId)).mp4")
    }

    public static func posterURL(accountId: Int64) -> URL? {
        guard let directory = try? directoryURL() else {
            return nil
        }
        return directory.appendingPathComponent("profile-\(suffix(accountId)).jpg")
    }

    public static func hasMedia(accountId: Int64) -> Bool {
        guard let url = mediaURL(accountId: accountId) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func isEnabled(accountId: Int64) -> Bool {
        if UserDefaults.standard.bool(forKey: key(enabledPrefix, accountId: accountId)) {
            return true
        }
        return AorusBannerService.shared.publicationMode(for: accountId) == .publicOwner
            && AorusBannerService.shared.cachedBanner(for: accountId) != nil
    }

    public static func isEffectivelyEnabled(accountId: Int64) -> Bool {
        return !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04")
            && UserDefaults.standard.bool(forKey: key(enabledPrefix, accountId: accountId))
            && hasMedia(accountId: accountId)
    }

    public static func transparency(accountId: Int64) -> CGFloat {
        stateLock.lock()
        let transientValue = transientTransparency[accountId]
        stateLock.unlock()
        if let transientValue {
            return transientValue
        }

        let storageKey = key(transparencyPrefix, accountId: accountId)
        guard UserDefaults.standard.object(forKey: storageKey) != nil else {
            return 0.25
        }
        return min(1.0, max(0.0, CGFloat(UserDefaults.standard.double(forKey: storageKey))))
    }

    public static func revision(accountId: Int64) -> Int {
        return UserDefaults.standard.integer(forKey: key(revisionPrefix, accountId: accountId))
    }

    public static func setEnabled(
        _ enabled: Bool,
        accountId: Int64,
        completion: @escaping (Result<Void, AorusBannerServiceError>) -> Void
    ) {
        guard enabled != isEnabled(accountId: accountId) else {
            completion(.success(()))
            return
        }

        if enabled && !hasMedia(accountId: accountId) {
            setEnabledLocally(true, accountId: accountId)
            completion(.success(()))
            return
        }

        let mode = AorusBannerService.shared.publicationMode(for: accountId)
        guard mode != .localOnly else {
            setEnabledLocally(enabled, accountId: accountId)
            completion(.success(()))
            return
        }

        if enabled {
            guard let mediaURL = mediaURL(accountId: accountId) else {
                completion(.failure(.invalidMedia))
                return
            }
            AorusBannerService.shared.uploadBanner(fileURL: mediaURL, accountId: accountId) { result in
                switch result {
                case .success:
                    setEnabledLocally(true, accountId: accountId)
                    completion(.success(()))
                case let .failure(error) where error.allowsLocalFallback:
                    setEnabledLocally(true, accountId: accountId)
                    completion(.success(()))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        } else {
            AorusBannerService.shared.deleteBanner(accountId: accountId) { result in
                switch result {
                case .success:
                    setEnabledLocally(false, accountId: accountId)
                    completion(.success(()))
                case let .failure(error) where error.allowsLocalFallback:
                    setEnabledLocally(false, accountId: accountId)
                    completion(.success(()))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    public static func setTransparency(_ value: CGFloat, accountId: Int64, persist: Bool) {
        let clamped = min(1.0, max(0.0, value))
        stateLock.lock()
        transientTransparency[accountId] = clamped
        stateLock.unlock()
        if persist {
            UserDefaults.standard.set(Double(clamped), forKey: key(transparencyPrefix, accountId: accountId))
        }
        postChanged(accountId: accountId)
    }

    public static func reset(
        accountId: Int64,
        completion: @escaping (Result<Void, AorusBannerServiceError>) -> Void
    ) {
        let finishLocalReset = {
            resetLocally(accountId: accountId)
            completion(.success(()))
        }
        let mode = AorusBannerService.shared.publicationMode(for: accountId)
        guard mode != .localOnly else {
            finishLocalReset()
            return
        }
        AorusBannerService.shared.deleteBanner(accountId: accountId) { result in
            switch result {
            case .success:
                finishLocalReset()
            case let .failure(error) where error.allowsLocalFallback:
                finishLocalReset()
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    private static func resetLocally(accountId: Int64) {
        // Reset removes the selected media, not the user's feature preference.
        // Keeping the switch enabled leaves the picker available immediately.
        UserDefaults.standard.set(true, forKey: key(enabledPrefix, accountId: accountId))
        UserDefaults.standard.removeObject(forKey: key(transparencyPrefix, accountId: accountId))
        stateLock.lock()
        transientTransparency.removeValue(forKey: accountId)
        stateLock.unlock()
        if let url = mediaURL(accountId: accountId) {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = posterURL(accountId: accountId) {
            try? FileManager.default.removeItem(at: url)
        }
        bumpRevision(accountId: accountId)
        postChanged(accountId: accountId)
    }

    fileprivate static func installProcessedFile(
        _ temporaryURL: URL,
        posterTemporaryURL: URL,
        accountId: Int64
    ) throws {
        guard let destinationURL = mediaURL(accountId: accountId),
              let destinationPosterURL = posterURL(accountId: accountId),
              let directory = try? directoryURL() else {
            throw AorusAnimatedProfileMediaError.storage
        }
        let fileManager = FileManager.default
        let stagedMedia = directory.appendingPathComponent(".\(UUID().uuidString).mp4")
        let stagedPoster = directory.appendingPathComponent(".\(UUID().uuidString).jpg")
        do {
            try fileManager.copyItem(at: temporaryURL, to: stagedMedia)
            try fileManager.copyItem(at: posterTemporaryURL, to: stagedPoster)
            try replaceItem(stagedURL: stagedPoster, destinationURL: destinationPosterURL)
            try replaceItem(stagedURL: stagedMedia, destinationURL: destinationURL)
        } catch {
            try? fileManager.removeItem(at: stagedMedia)
            try? fileManager.removeItem(at: stagedPoster)
            throw error
        }
        UserDefaults.standard.set(true, forKey: key(enabledPrefix, accountId: accountId))
        bumpRevision(accountId: accountId)
        postChanged(accountId: accountId)
    }

    fileprivate static func installSelectedMedia(
        mediaURL: URL,
        posterURL: URL,
        accountId: Int64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let installLocally = {
            do {
                try installProcessedFile(mediaURL, posterTemporaryURL: posterURL, accountId: accountId)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        let mode = AorusBannerService.shared.publicationMode(for: accountId)
        guard mode != .localOnly else {
            installLocally()
            return
        }
        AorusBannerService.shared.uploadBanner(fileURL: mediaURL, accountId: accountId) { result in
            switch result {
            case .success:
                installLocally()
            case let .failure(error) where error.allowsLocalFallback:
                installLocally()
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    private static func setEnabledLocally(_ enabled: Bool, accountId: Int64) {
        UserDefaults.standard.set(enabled, forKey: key(enabledPrefix, accountId: accountId))
        bumpRevision(accountId: accountId)
        postChanged(accountId: accountId)
    }

    private static func replaceItem(stagedURL: URL, destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private static func bumpRevision(accountId: Int64) {
        let revisionKey = key(revisionPrefix, accountId: accountId)
        let next = UserDefaults.standard.integer(forKey: revisionKey) &+ 1
        UserDefaults.standard.set(next, forKey: revisionKey)
    }

    private static func postChanged(accountId: Int64) {
        let post = {
            NotificationCenter.default.post(
                name: changedNotification,
                object: nil,
                userInfo: ["accountId": accountId]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}

public enum AorusAnimatedProfileBackgroundFeedback {
    public static func presentOperationError(
        from controller: UIViewController,
        languageCode: String?,
        error: Error
    ) {
        let l10n = AorusL10n(languageCode)
        let message: String
        if let serviceError = error as? AorusBannerServiceError {
            switch serviceError {
            case .rateLimited:
                message = l10n.animatedProfileRateLimited
            case .uploadTooLarge:
                message = l10n.animatedProfileUploadTooLarge
            default:
                message = l10n.animatedProfileSyncFailed
            }
        } else {
            message = l10n.animatedProfileSyncFailed
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
}

// MARK: - Video-only playback

private final class AorusVideoOnlyLoopRenderer {
    let layer = AVSampleBufferDisplayLayer()
    var firstFrameEnqueued: (() -> Void)?

    private let queue = DispatchQueue(label: "com.aorusgram.profile-background.renderer", qos: .userInitiated)
    private var generation = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var timebase: CMTimebase?
    private var duration = 0.0
    private var wantsPlayback = false
    private var firstFrameDelivered = false
    private var url: URL?

    init() {
        self.layer.videoGravity = .resizeAspectFill
        self.layer.backgroundColor = UIColor.clear.cgColor
    }

    func load(url: URL) {
        self.queue.async {
            self.url = url
            self.generation &+= 1
            let generation = self.generation
            self.firstFrameDelivered = false
            self.startCycle(url: url, generation: generation)
        }
    }

    // Re-arm the read/enqueue pump after a lifecycle pause. iOS stops calling the
    // requestMediaDataWhenReady handler while the app is suspended, and an
    // AVSampleBufferDisplayLayer can fall into a .failed state after a long
    // background — leaving the last frame frozen (and the stretched overscroll
    // backdrop showing through) even once playback rate is restored. Rebuilding
    // the cycle re-creates the reader + timebase and re-arms the pump. startCycle
    // uses flush() (not flushAndRemoveImage), so the last displayed frame stays
    // visible during the rebuild — no black flash. firstFrameDelivered is left as
    // is so the poster fade does not re-trigger.
    func recover() {
        self.queue.async {
            guard let url = self.url else { return }
            self.generation &+= 1
            let generation = self.generation
            self.startCycle(url: url, generation: generation)
        }
    }

    func setPlaying(_ playing: Bool) {
        self.queue.async {
            self.wantsPlayback = playing
            if let timebase = self.timebase {
                CMTimebaseSetRate(timebase, rate: playing ? 1.0 : 0.0)
            }
        }
    }

    func invalidate() {
        self.queue.async {
            self.generation &+= 1
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
            self.timebase = nil
            self.layer.stopRequestingMediaData()
            self.layer.flushAndRemoveImage()
        }
    }

    private func startCycle(url: URL, generation: Int) {
        guard generation == self.generation else { return }
        self.reader?.cancelReading()
        self.layer.stopRequestingMediaData()
        self.layer.flush()

        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        var createdTimebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &createdTimebase
        ) == noErr, let timebase = createdTimebase else {
            reader.cancelReading()
            return
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: self.wantsPlayback ? 1.0 : 0.0)
        self.layer.controlTimebase = timebase
        self.reader = reader
        self.output = output
        self.timebase = timebase
        self.duration = max(0.05, CMTimeGetSeconds(asset.duration))

        self.layer.requestMediaDataWhenReady(on: self.queue) { [weak self] in
            guard let self, generation == self.generation else { return }
            while self.layer.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    self.layer.enqueue(sample)
                    if !self.firstFrameDelivered {
                        self.firstFrameDelivered = true
                        DispatchQueue.main.async { [weak self] in
                            self?.firstFrameEnqueued?()
                        }
                    }
                } else {
                    self.layer.stopRequestingMediaData()
                    self.waitForCycleEnd(url: url, generation: generation)
                    break
                }
            }
        }
    }

    private func waitForCycleEnd(url: URL, generation: Int) {
        guard generation == self.generation, let timebase = self.timebase else { return }
        let current = max(0.0, CMTimeGetSeconds(CMTimebaseGetTime(timebase)))
        let remaining = max(0.03, self.duration - current)
        self.queue.asyncAfter(deadline: .now() + min(remaining, 0.25)) {
            guard generation == self.generation else { return }
            guard self.wantsPlayback else {
                self.waitForCycleEnd(url: url, generation: generation)
                return
            }
            guard let timebase = self.timebase else { return }
            let current = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if current + 0.025 >= self.duration {
                self.startCycle(url: url, generation: generation)
            } else {
                self.waitForCycleEnd(url: url, generation: generation)
            }
        }
    }
}

// MARK: - Animated background view

public final class AorusAnimatedProfileBackgroundView: UIView {
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()

    /// The Telegram header uses a 2000 pt clipped backing view and moves its
    /// visible cover inside that view while the user pulls the profile. Keep
    /// our outer view full-size, but render the media in Telegram's cover
    /// viewport so aggressive overscroll can never expose the stock cover.
    public var contentFrame: CGRect? {
        didSet {
            self.setNeedsLayout()
        }
    }

    private let backdropView = UIImageView()
    private let contentView = UIView()
    private let posterView = UIImageView()
    private var renderer: AorusVideoOnlyLoopRenderer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var viewerAccountId: Int64?
    private var targetId: Int64?
    private var requestedVisible = false
    private var representedAssetKey: String?
    private var representedTargetId: Int64?
    private var rendererHasDisplayedFrame = false
    private var lastPlaybackRequest: Bool?
    private var lastLookupTargetId: Int64?
    private var lastLookupTime: TimeInterval = 0.0
    private var remoteRefreshTimer: Timer?
    private var stableMediaViewportWidth: CGFloat?
    private var stableMediaViewportHeight: CGFloat?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.backgroundColor = .clear

        self.backdropView.contentMode = .scaleToFill
        self.backdropView.clipsToBounds = true
        self.backdropView.backgroundColor = .clear
        self.addSubview(self.backdropView)

        self.contentView.clipsToBounds = true
        self.contentView.backgroundColor = .clear
        self.addSubview(self.contentView)

        self.posterView.contentMode = .scaleAspectFill
        self.posterView.clipsToBounds = true
        self.posterView.backgroundColor = .clear
        self.contentView.addSubview(self.posterView)

        let center = NotificationCenter.default
        self.notificationTokens.append(center.addObserver(
            forName: AorusAnimatedProfileBackgroundStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let changedAccountId = notification.userInfo?["accountId"] as? Int64,
               let targetId = self.targetId,
               changedAccountId != targetId {
                return
            }
            self.reload(force: false, requestRemote: false)
        })
        self.notificationTokens.append(center.addObserver(
            forName: AorusBannerService.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let changedTargetId = notification.userInfo?["targetId"] as? Int64,
               let targetId = self.targetId,
               changedTargetId != targetId {
                return
            }
            self.reload(force: true, requestRemote: false)
        })
        self.notificationTokens.append(center.addObserver(
            forName: Notification.Name("aorusgram.licenseLockChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload(force: true, requestRemote: true)
        })
        self.notificationTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reload(force: false, requestRemote: false)
            self.requestCurrentRemoteBanner(force: true)
            self.resumeAfterLifecyclePause()
            self.updateRemoteRefreshTimer()
        })
        self.notificationTokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.remoteRefreshTimer?.invalidate()
            self?.remoteRefreshTimer = nil
            self?.prepareForLifecyclePause()
        })
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.remoteRefreshTimer?.invalidate()
        for token in self.notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        self.teardownRenderer()
    }

    public func configure(viewerAccountId: Int64, targetId: Int64?, visible: Bool) {
        let identityChanged = self.viewerAccountId != viewerAccountId || self.targetId != targetId
        let visibilityChanged = self.requestedVisible != visible
        self.viewerAccountId = viewerAccountId
        self.targetId = targetId
        self.requestedVisible = visible
        if identityChanged {
            self.lastLookupTargetId = nil
            self.lastLookupTime = 0.0
            self.stableMediaViewportWidth = nil
            self.stableMediaViewportHeight = nil
        }
        self.reload(force: identityChanged || visibilityChanged, requestRemote: true)
        self.updateRemoteRefreshTimer()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updatePlayback()
        if self.window != nil {
            // A profile controller can be reused for the same peer. Always
            // validate the server version when its header becomes visible;
            // otherwise the service's normal TTL can survive profile re-entry.
            self.requestCurrentRemoteBanner(force: true)
        }
        self.updateRemoteRefreshTimer()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.backdropView.frame = self.bounds
        let viewportFrame = self.contentFrame ?? self.bounds
        self.contentView.transform = .identity
        self.contentView.frame = viewportFrame

        // Telegram expands the native cover viewport during pull-to-stretch. Do
        // not feed that transient height into AVSampleBufferDisplayLayer: doing
        // so continuously changes aspect-fill scale and makes the banner appear
        // to stretch under aggressive swipes. Capture the resting viewport once
        // per profile/width and keep the media bottom-anchored inside the dynamic
        // clipped viewport. The full 2000 pt backdrop remains behind it, so the
        // stock Telegram cover is never exposed during extreme overscroll.
        let viewportWidth = max(1.0, viewportFrame.width)
        if let stableWidth = self.stableMediaViewportWidth,
           abs(stableWidth - viewportWidth) > 1.0 {
            self.stableMediaViewportWidth = nil
            self.stableMediaViewportHeight = nil
        }
        if self.stableMediaViewportHeight == nil,
           viewportFrame.height > 1.0 {
            self.stableMediaViewportWidth = viewportWidth
            self.stableMediaViewportHeight = viewportFrame.height
        }
        let mediaHeight = max(1.0, self.stableMediaViewportHeight ?? viewportFrame.height)
        let mediaFrame = CGRect(
            x: 0.0,
            y: viewportFrame.height - mediaHeight,
            width: viewportWidth,
            height: mediaHeight
        )
        self.posterView.frame = mediaFrame
        self.renderer?.layer.frame = mediaFrame
        // The view is created before Telegram assigns its final header frame.
        // Re-evaluate playback after layout, but updatePlayback de-duplicates
        // the request so profile scrolling does not flood the renderer queue.
        self.updatePlayback()
    }

    private func reload(force: Bool, requestRemote: Bool) {
        guard let viewerAccountId,
              let targetId,
              targetId != 0,
              self.requestedVisible,
              !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04") else {
            self.isHidden = true
            self.teardownRenderer()
            self.updateRemoteRefreshTimer()
            return
        }

        if targetId == viewerAccountId,
           AorusAnimatedProfileBackgroundStore.isEffectivelyEnabled(accountId: viewerAccountId),
           let mediaURL = AorusAnimatedProfileBackgroundStore.mediaURL(accountId: viewerAccountId) {
            let revision = AorusAnimatedProfileBackgroundStore.revision(accountId: viewerAccountId)
            self.displayAsset(
                mediaURL: mediaURL,
                posterURL: AorusAnimatedProfileBackgroundStore.posterURL(accountId: viewerAccountId),
                key: "local:\(viewerAccountId):\(revision)",
                opacity: 1.0 - AorusAnimatedProfileBackgroundStore.transparency(accountId: viewerAccountId),
                force: force
            )
        } else if let asset = AorusBannerService.shared.cachedBanner(for: targetId) {
            self.displayAsset(
                mediaURL: asset.mediaURL,
                posterURL: asset.posterURL,
                key: "public:\(targetId):\(asset.bannerId):\(asset.version)",
                opacity: 1.0,
                force: force
            )
        } else {
            self.isHidden = true
            self.teardownRenderer()
        }

        if requestRemote {
            self.requestRemoteBanner(targetId: targetId, viewerAccountId: viewerAccountId, force: force)
        }
    }

    private func requestRemoteBanner(targetId: Int64, viewerAccountId: Int64, force: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        if !force,
           self.lastLookupTargetId == targetId,
           now - self.lastLookupTime < 60.0 {
            return
        }
        self.lastLookupTargetId = targetId
        self.lastLookupTime = now
        AorusBannerService.shared.resolveBanner(
            targetId: targetId,
            preferredCallerId: viewerAccountId,
            forceRefresh: force
        ) { [weak self] _ in
            guard let self,
                  self.targetId == targetId,
                  self.viewerAccountId == viewerAccountId else { return }
            self.reload(force: true, requestRemote: false)
        }
    }

    private func requestCurrentRemoteBanner(force: Bool) {
        guard let viewerAccountId,
              let targetId,
              targetId != 0,
              targetId != viewerAccountId,
              self.requestedVisible,
              self.window != nil,
              UIApplication.shared.applicationState == .active,
              !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04") else {
            return
        }
        self.requestRemoteBanner(targetId: targetId, viewerAccountId: viewerAccountId, force: force)
    }

    private func updateRemoteRefreshTimer() {
        let shouldPoll = self.viewerAccountId != nil
            && self.targetId != nil
            && self.targetId != self.viewerAccountId
            && self.targetId != 0
            && self.requestedVisible
            && self.window != nil
            && UIApplication.shared.applicationState == .active
            && !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04")
        guard shouldPoll else {
            self.remoteRefreshTimer?.invalidate()
            self.remoteRefreshTimer = nil
            return
        }
        guard self.remoteRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.requestCurrentRemoteBanner(force: true)
        }
        timer.tolerance = 3.0
        RunLoop.main.add(timer, forMode: .common)
        self.remoteRefreshTimer = timer
    }

    private func displayAsset(
        mediaURL: URL,
        posterURL: URL?,
        key: String,
        opacity: CGFloat,
        force _: Bool
    ) {
        let resolvedOpacity = min(1.0, max(0.0, opacity))
        self.alpha = resolvedOpacity
        // A remote refresh can confirm the same banner while it is already on
        // screen. Keep the current layer alive instead of briefly exposing the
        // Telegram cover during an unnecessary teardown/rebuild.
        if self.representedAssetKey == key, self.renderer != nil {
            self.isHidden = false
            self.updatePlayback()
            return
        }
        let canPreserveCurrentVisual = self.representedTargetId == self.targetId
            && (self.backdropView.image != nil || self.posterView.image != nil)
        self.representedAssetKey = key
        self.representedTargetId = self.targetId
        self.isHidden = !canPreserveCurrentVisual
        self.teardownRenderer(clearVisuals: !canPreserveCurrentVisual)

        if let posterURL,
           let image = UIImage(contentsOfFile: posterURL.path) {
            Self.thumbnailCache.setObject(image, forKey: key as NSString)
            self.setupRenderer(mediaURL: mediaURL, poster: image, key: key)
        } else if let image = Self.thumbnailCache.object(forKey: key as NSString) {
            self.setupRenderer(mediaURL: mediaURL, poster: image, key: key)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = Self.makePoster(url: mediaURL)
                if let image {
                    Self.thumbnailCache.setObject(image, forKey: key as NSString)
                    if let posterURL,
                       let data = image.jpegData(compressionQuality: 0.86) {
                        try? data.write(to: posterURL, options: .atomic)
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.representedAssetKey == key, let image else { return }
                    self.setupRenderer(mediaURL: mediaURL, poster: image, key: key)
                }
            }
        }
    }

    private func setupRenderer(mediaURL: URL, poster: UIImage, key: String) {
        guard self.representedAssetKey == key else { return }
        self.backdropView.image = Self.makeOverscrollBackdrop(from: poster)
        self.posterView.image = poster
        self.posterView.alpha = 1.0
        let renderer = AorusVideoOnlyLoopRenderer()
        self.rendererHasDisplayedFrame = false
        self.lastPlaybackRequest = nil
        renderer.layer.frame = self.contentView.bounds
        renderer.firstFrameEnqueued = { [weak self, weak renderer] in
            guard let self,
                  let renderer,
                  self.renderer === renderer,
                  self.representedAssetKey == key else { return }
            self.rendererHasDisplayedFrame = true
            UIView.animate(withDuration: 0.16, delay: 0.05, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.posterView.alpha = 0.0
            }
        }
        self.contentView.layer.insertSublayer(renderer.layer, at: 0)
        self.renderer = renderer
        renderer.load(url: mediaURL)
        self.isHidden = false
        self.updatePlayback()
    }

    private func updatePlayback() {
        guard let renderer = self.renderer else {
            self.lastPlaybackRequest = nil
            return
        }
        let shouldPlay: Bool
        if !self.isHidden,
           self.alpha > 0.001,
           let window = self.window,
           !self.bounds.isEmpty,
           self.convert(self.bounds, to: window).intersects(window.bounds),
           UIApplication.shared.applicationState == .active {
            shouldPlay = true
        } else {
            shouldPlay = false
        }
        guard self.lastPlaybackRequest != shouldPlay else { return }
        self.lastPlaybackRequest = shouldPlay
        renderer.setPlaying(shouldPlay)
    }

    private func prepareForLifecyclePause() {
        self.posterView.layer.removeAllAnimations()
        if self.posterView.image != nil {
            self.posterView.alpha = 1.0
        }
        // Keep the de-duplicated playback state in sync with the direct pause.
        // Otherwise didBecomeActive considers playback already requested and
        // leaves the display layer's timebase paused after Control Center.
        self.lastPlaybackRequest = false
        self.renderer?.setPlaying(false)
    }

    private func resumeAfterLifecyclePause() {
        self.updatePlayback()
        // A long suspension leaves the reader pump stopped / the display layer
        // failed, so restoring the playback rate alone keeps the frame frozen.
        // Re-arm the read cycle so the loop actually moves again.
        self.renderer?.recover()
        guard self.rendererHasDisplayedFrame,
              self.posterView.image != nil,
              !self.isHidden else {
            return
        }
        UIView.animate(
            withDuration: 0.18,
            delay: 0.08,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.posterView.alpha = 0.0
        }
    }

    private func teardownRenderer(clearVisuals: Bool = true) {
        self.renderer?.invalidate()
        self.renderer?.layer.removeFromSuperlayer()
        self.renderer = nil
        self.rendererHasDisplayedFrame = false
        self.lastPlaybackRequest = nil
        if clearVisuals {
            self.backdropView.image = nil
            self.posterView.image = nil
            self.posterView.alpha = 1.0
        } else if self.posterView.image != nil {
            // The video layer is about to be replaced. Bring its matching
            // poster back immediately so the preserved visual is exact, not
            // the stretched overscroll guard underneath it.
            self.posterView.layer.removeAllAnimations()
            self.posterView.alpha = 1.0
        }
    }

    private static func makeOverscrollBackdrop(from image: UIImage) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        guard width > 4.0, height > 4.0 else {
            return image
        }
        // This image is only the 2000 pt safety guard behind the real media.
        // Stretching a one-pixel center cap preserved sharp details as long
        // vertical bands during extreme pull gestures. A tiny downsample keeps
        // the banner's colour field while removing geometry that could visibly
        // deform. The actual poster/video above remains full-resolution.
        let guardSize = CGSize(width: 8.0, height: 24.0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: guardSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: guardSize))
            image.draw(in: CGRect(origin: .zero, size: guardSize))
            context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.08).cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: guardSize))
        }
    }

    private static func makePoster(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280.0, height: 720.0)
        let time = CMTime(seconds: 0.05, preferredTimescale: 600)
        guard let cgImage = (try? generator.copyCGImage(at: time, actualTime: nil))
            ?? (try? generator.copyCGImage(at: .zero, actualTime: nil)) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Native opacity row

public final class AorusAnimatedProfileOpacityComponent: Component {
    public typealias EnvironmentType = Empty

    public let theme: PresentationTheme
    public let title: String
    public let transparency: CGFloat
    public let valueUpdated: (CGFloat, Bool) -> Void

    public init(
        theme: PresentationTheme,
        title: String,
        transparency: CGFloat,
        valueUpdated: @escaping (CGFloat, Bool) -> Void
    ) {
        self.theme = theme
        self.title = title
        self.transparency = transparency
        self.valueUpdated = valueUpdated
    }

    public static func == (lhs: AorusAnimatedProfileOpacityComponent, rhs: AorusAnimatedProfileOpacityComponent) -> Bool {
        return lhs.theme === rhs.theme
            && lhs.title == rhs.title
            && abs(lhs.transparency - rhs.transparency) < 0.001
    }

    public final class View: UIView {
        private let titleLabel = UILabel()
        private let valueLabel = UILabel()
        private let slider = UISlider()
        private var component: AorusAnimatedProfileOpacityComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.addSubview(self.titleLabel)
            self.addSubview(self.valueLabel)
            self.addSubview(self.slider)
            self.slider.minimumValue = 0.0
            self.slider.maximumValue = 1.0
            self.slider.isContinuous = true
            self.slider.addTarget(self, action: #selector(self.sliderChanged), for: .valueChanged)
            self.slider.addTarget(self, action: #selector(self.sliderFinished), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            component: AorusAnimatedProfileOpacityComponent,
            availableSize: CGSize,
            transition: ComponentTransition
        ) -> CGSize {
            self.component = component
            // Under Interface 2.0 the enclosing ListSectionComponent already draws one glass pane
            // for the whole section, so an opaque card here would punch a grey rectangle through it.
            self.backgroundColor = AorusInterfaceV2.isEnabled ? UIColor.clear : component.theme.list.itemBlocksBackgroundColor

            self.titleLabel.text = component.title
            self.titleLabel.font = Font.regular(17.0)
            self.titleLabel.textColor = component.theme.list.itemPrimaryTextColor

            self.valueLabel.font = Font.regular(15.0)
            self.valueLabel.textColor = component.theme.list.itemSecondaryTextColor
            self.valueLabel.textAlignment = .right
            self.updateValueLabel(component.transparency)

            self.slider.minimumTrackTintColor = component.theme.list.itemAccentColor
            self.slider.maximumTrackTintColor = component.theme.list.controlSecondaryColor
            if !self.slider.isTracking {
                self.slider.setValue(Float(component.transparency), animated: false)
            }

            let size = CGSize(width: availableSize.width, height: 78.0)
            let sideInset: CGFloat = 16.0
            self.titleLabel.frame = CGRect(x: sideInset, y: 9.0, width: size.width - sideInset * 2.0 - 62.0, height: 23.0)
            self.valueLabel.frame = CGRect(x: size.width - sideInset - 58.0, y: 10.0, width: 58.0, height: 22.0)
            self.slider.frame = CGRect(x: sideInset - 2.0, y: 34.0, width: size.width - sideInset * 2.0 + 4.0, height: 34.0)
            return size
        }

        @objc private func sliderChanged() {
            let value = CGFloat(self.slider.value)
            self.updateValueLabel(value)
            self.component?.valueUpdated(value, false)
        }

        @objc private func sliderFinished() {
            let value = CGFloat(self.slider.value)
            self.updateValueLabel(value)
            self.component?.valueUpdated(value, true)
        }

        private func updateValueLabel(_ value: CGFloat) {
            self.valueLabel.text = "\(Int((value * 100.0).rounded()))%"
        }
    }

    public func makeView() -> View {
        return View(frame: .zero)
    }

    public func update(
        view: View,
        availableSize: CGSize,
        state: EmptyComponentState,
        environment: Environment<Empty>,
        transition: ComponentTransition
    ) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}

// MARK: - Media import

private enum AorusAnimatedProfileMediaKind {
    case video
    case gif
}

private struct AorusAnimatedProfileCrop {
    static let aspectRatio: CGFloat = 16.0 / 9.0
    static let outputSize = CGSize(width: 1280.0, height: 720.0)

    let normalizedRect: CGRect

    var clampedRect: CGRect {
        let width = min(1.0, max(0.001, self.normalizedRect.width))
        let height = min(1.0, max(0.001, self.normalizedRect.height))
        return CGRect(
            x: min(1.0 - width, max(0.0, self.normalizedRect.minX)),
            y: min(1.0 - height, max(0.0, self.normalizedRect.minY)),
            width: width,
            height: height
        )
    }
}

private enum AorusAnimatedProfileMediaError: Error {
    case cancelled
    case unsupported
    case tooLong
    case unreadable
    case conversion
    case storage
}

private struct AorusProcessedProfileMedia {
    let mediaURL: URL
    let posterURL: URL
}

private enum AorusAnimatedProfileMediaProcessor {
    // Leave headroom for the API envelope and container metadata below the
    // server's 6 MiB input limit. Short clips keep the highest useful preset;
    // longer clips fall back only when the encoded result is still too large.
    private static let maximumEncodedBytes = 5_750_000

    static func process(
        sourceURL: URL,
        kind: AorusAnimatedProfileMediaKind,
        crop: AorusAnimatedProfileCrop,
        completion: @escaping (Result<AorusProcessedProfileMedia, Error>) -> Void
    ) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorus-profile-\(UUID().uuidString).mp4")
        switch kind {
        case .video:
            processVideo(sourceURL: sourceURL, outputURL: outputURL, crop: crop) { result in
                finish(result: result, outputURL: outputURL, completion: completion)
            }
        case .gif:
            DispatchQueue.global(qos: .userInitiated).async {
                let result = convertGif(sourceURL: sourceURL, outputURL: outputURL, crop: crop)
                finish(result: result, outputURL: outputURL, completion: completion)
            }
        }
    }

    private static func finish(
        result: Result<Void, Error>,
        outputURL: URL,
        completion: @escaping (Result<AorusProcessedProfileMedia, Error>) -> Void
    ) {
        switch result {
        case .success:
            guard let fileSize = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.intValue,
                  fileSize > 0,
                  fileSize <= maximumEncodedBytes else {
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async { completion(.failure(AorusBannerServiceError.uploadTooLarge)) }
                return
            }
            let posterURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("aorus-profile-poster-\(UUID().uuidString).jpg")
            guard createPoster(videoURL: outputURL, destinationURL: posterURL) else {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: posterURL)
                DispatchQueue.main.async { completion(.failure(AorusAnimatedProfileMediaError.conversion)) }
                return
            }
            let media = AorusProcessedProfileMedia(mediaURL: outputURL, posterURL: posterURL)
            DispatchQueue.main.async { completion(.success(media)) }
        case let .failure(error):
            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private static func createPoster(videoURL: URL, destinationURL: URL) -> Bool {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280.0, height: 720.0)
        let preferredTime = CMTime(seconds: 0.05, preferredTimescale: 600)
        let cgImage = (try? generator.copyCGImage(at: preferredTime, actualTime: nil))
            ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
        guard let cgImage,
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.86) else {
            return false
        }
        do {
            try data.write(to: destinationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func processVideo(
        sourceURL: URL,
        outputURL: URL,
        crop: AorusAnimatedProfileCrop,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: sourceURL)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard seconds.isFinite, seconds > 0.0 else {
                completion(.failure(AorusAnimatedProfileMediaError.unreadable))
                return
            }
            guard seconds <= 30.0 else {
                completion(.failure(AorusAnimatedProfileMediaError.tooLong))
                return
            }
            guard let sourceTrack = asset.tracks(withMediaType: .video).first else {
                completion(.failure(AorusAnimatedProfileMediaError.unsupported))
                return
            }

            let composition = AVMutableComposition()
            guard let targetTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(.failure(AorusAnimatedProfileMediaError.conversion))
                return
            }
            do {
                try targetTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: asset.duration),
                    of: sourceTrack,
                    at: .zero
                )
                targetTrack.preferredTransform = .identity
            } catch {
                completion(.failure(error))
                return
            }

            let transformedBounds = CGRect(origin: .zero, size: sourceTrack.naturalSize)
                .applying(sourceTrack.preferredTransform)
            let orientedSize = CGSize(
                width: abs(transformedBounds.width),
                height: abs(transformedBounds.height)
            )
            guard orientedSize.width > 1.0, orientedSize.height > 1.0 else {
                completion(.failure(AorusAnimatedProfileMediaError.unreadable))
                return
            }
            let cropRect = crop.clampedRect
            let sourceCrop = CGRect(
                x: cropRect.minX * orientedSize.width,
                y: cropRect.minY * orientedSize.height,
                width: cropRect.width * orientedSize.width,
                height: cropRect.height * orientedSize.height
            )
            let outputSize = AorusAnimatedProfileCrop.outputSize
            let scale = max(outputSize.width / sourceCrop.width, outputSize.height / sourceCrop.height)
            var transform = sourceTrack.preferredTransform
            transform = transform.concatenating(CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            ))
            transform = transform.concatenating(CGAffineTransform(
                translationX: -sourceCrop.minX,
                y: -sourceCrop.minY
            ))
            transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: targetTrack)
            layerInstruction.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layerInstruction]
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = outputSize
            let sourceFPS = sourceTrack.nominalFrameRate
            let frameRate = min(30, max(15, Int32(sourceFPS.rounded())))
            videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
            videoComposition.instructions = [instruction]

            let byteBudgetBitRate = Double(maximumEncodedBytes * 8) / seconds
            let presets: [String]
            if byteBudgetBitRate >= 3_000_000.0 {
                presets = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
            } else if byteBudgetBitRate >= 1_800_000.0 {
                presets = [AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
            } else {
                presets = [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
            }
            exportVideo(
                composition: composition,
                videoComposition: videoComposition,
                outputURL: outputURL,
                presets: presets[...],
                completion: completion
            )
        }
    }

    private static func exportVideo(
        composition: AVComposition,
        videoComposition: AVVideoComposition,
        outputURL: URL,
        presets: ArraySlice<String>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let preset = presets.first else {
            completion(.failure(AorusBannerServiceError.uploadTooLarge))
            return
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset),
              exporter.supportedFileTypes.contains(.mp4) else {
            exportVideo(
                composition: composition,
                videoComposition: videoComposition,
                outputURL: outputURL,
                presets: presets.dropFirst(),
                completion: completion
            )
            return
        }

        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        exporter.exportAsynchronously {
            guard exporter.status == .completed else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(exporter.error ?? AorusAnimatedProfileMediaError.conversion))
                return
            }
            let fileSize = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.intValue ?? 0
            if fileSize > 0, fileSize <= maximumEncodedBytes {
                completion(.success(()))
            } else {
                exportVideo(
                    composition: composition,
                    videoComposition: videoComposition,
                    outputURL: outputURL,
                    presets: presets.dropFirst(),
                    completion: completion
                )
            }
        }
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        if let value = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, value > 0.0 {
            return max(0.02, value)
        }
        if let value = gif[kCGImagePropertyGIFDelayTime] as? Double, value > 0.0 {
            return max(0.02, value)
        }
        return 0.1
    }

    private static func convertGif(
        sourceURL: URL,
        outputURL: URL,
        crop: AorusAnimatedProfileCrop
    ) -> Result<Void, Error> {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return .failure(AorusAnimatedProfileMediaError.unreadable)
        }
        guard let sourceType = CGImageSourceGetType(source),
              sourceType as String == "com.compuserve.gif" else {
            return .failure(AorusAnimatedProfileMediaError.unsupported)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0,
              let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(AorusAnimatedProfileMediaError.unreadable)
        }

        var delays: [Double] = []
        delays.reserveCapacity(frameCount)
        var totalDuration = 0.0
        for index in 0 ..< frameCount {
            let delay = frameDelay(source: source, index: index)
            delays.append(delay)
            totalDuration += delay
        }
        guard totalDuration <= 30.0 else {
            return .failure(AorusAnimatedProfileMediaError.tooLong)
        }

        let width = Int(AorusAnimatedProfileCrop.outputSize.width)
        let height = Int(AorusAnimatedProfileCrop.outputSize.height)
        guard width >= 2, height >= 2 else {
            return .failure(AorusAnimatedProfileMediaError.unreadable)
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return .failure(AorusAnimatedProfileMediaError.conversion)
        }
        let pixels = width * height
        let sizeBudgetBitRate = Int((Double(maximumEncodedBytes * 8) / max(0.1, totalDuration)) * 0.92)
        let averageBitRate = min(4_000_000, max(350_000, min(pixels * 4, sizeBudgetBitRate)))
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else {
            return .failure(AorusAnimatedProfileMediaError.conversion)
        }
        writer.add(input)
        guard writer.startWriting() else {
            return .failure(writer.error ?? AorusAnimatedProfileMediaError.conversion)
        }
        writer.startSession(atSourceTime: .zero)

        let semaphore = DispatchSemaphore(value: 0)
        let writingQueue = DispatchQueue(label: "aorus.profile-background.gif-writer")
        var frameIndex = 0
        var currentTime = CMTime.zero
        var appendFailed = false
        input.requestMediaDataWhenReady(on: writingQueue) {
            while input.isReadyForMoreMediaData {
                if frameIndex > frameCount {
                    input.markAsFinished()
                    writer.finishWriting {
                        semaphore.signal()
                    }
                    return
                }

                let sourceIndex = min(frameIndex, frameCount - 1)
                guard let frame = CGImageSourceCreateImageAtIndex(source, sourceIndex, nil),
                      let pixelBuffer = makePixelBuffer(
                        image: frame,
                        width: width,
                        height: height,
                        crop: crop,
                        pool: adaptor.pixelBufferPool
                      ),
                      adaptor.append(pixelBuffer, withPresentationTime: currentTime) else {
                    appendFailed = true
                    input.markAsFinished()
                    writer.cancelWriting()
                    semaphore.signal()
                    return
                }

                if frameIndex < frameCount {
                    currentTime = CMTimeAdd(
                        currentTime,
                        CMTime(seconds: delays[frameIndex], preferredTimescale: 600)
                    )
                }
                frameIndex += 1
            }
        }
        semaphore.wait()

        guard !appendFailed, writer.status == .completed else {
            return .failure(writer.error ?? AorusAnimatedProfileMediaError.conversion)
        }
        return .success(())
    }

    private static func makePixelBuffer(
        image: CGImage,
        width: Int,
        height: Int,
        crop: AorusAnimatedProfileCrop,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            )
        }
        guard let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.setFillColor(UIColor.black.cgColor)
        let outputRect = CGRect(x: 0.0, y: 0.0, width: CGFloat(width), height: CGFloat(height))
        context.fill(outputRect)
        let normalizedCrop = crop.clampedRect
        let imageSize = CGSize(width: image.width, height: image.height)
        let sourceCrop = CGRect(
            x: normalizedCrop.minX * imageSize.width,
            y: normalizedCrop.minY * imageSize.height,
            width: normalizedCrop.width * imageSize.width,
            height: normalizedCrop.height * imageSize.height
        ).integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard sourceCrop.width > 1.0,
              sourceCrop.height > 1.0,
              let croppedImage = image.cropping(to: sourceCrop) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(croppedImage, in: outputRect)
        return pixelBuffer
    }
}

// MARK: - Gallery picker

public enum AorusAnimatedProfileBackgroundPicker {
    private static var coordinator: AorusAnimatedProfileBackgroundPickerCoordinator?

    public static func present(
        from controller: UIViewController,
        accountId: Int64,
        languageCode: String?,
        completion: @escaping (Bool) -> Void
    ) {
        let coordinator = AorusAnimatedProfileBackgroundPickerCoordinator(
            controller: controller,
            accountId: accountId,
            l10n: AorusL10n(languageCode),
            completion: completion
        ) {
            Self.coordinator = nil
        }
        Self.coordinator = coordinator
        coordinator.present()
    }
}

private final class AorusAnimatedProfileImportHUD: UIView {
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let activity = UIActivityIndicatorView(style: .large)
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        self.backgroundColor = UIColor.black.withAlphaComponent(0.24)
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        self.blurView.layer.cornerRadius = 18.0
        self.blurView.clipsToBounds = true
        self.blurView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.blurView)

        self.activity.color = .white
        self.activity.startAnimating()
        self.activity.translatesAutoresizingMaskIntoConstraints = false
        self.blurView.contentView.addSubview(self.activity)

        self.label.text = text
        self.label.textColor = .white
        self.label.font = .systemFont(ofSize: 15.0, weight: .semibold)
        self.label.textAlignment = .center
        self.label.numberOfLines = 2
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.blurView.contentView.addSubview(self.label)

        NSLayoutConstraint.activate([
            self.blurView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.blurView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.blurView.widthAnchor.constraint(equalToConstant: 210.0),
            self.blurView.heightAnchor.constraint(equalToConstant: 128.0),
            self.activity.centerXAnchor.constraint(equalTo: self.blurView.contentView.centerXAnchor),
            self.activity.topAnchor.constraint(equalTo: self.blurView.contentView.topAnchor, constant: 19.0),
            self.label.leadingAnchor.constraint(equalTo: self.blurView.contentView.leadingAnchor, constant: 14.0),
            self.label.trailingAnchor.constraint(equalTo: self.blurView.contentView.trailingAnchor, constant: -14.0),
            self.label.bottomAnchor.constraint(equalTo: self.blurView.contentView.bottomAnchor, constant: -18.0)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AorusAnimatedProfileBackgroundPickerCoordinator: NSObject {
    private weak var controller: UIViewController?
    private let accountId: Int64
    private let l10n: AorusL10n
    private let completion: (Bool) -> Void
    private let finished: () -> Void
    private var hud: AorusAnimatedProfileImportHUD?

    init(
        controller: UIViewController,
        accountId: Int64,
        l10n: AorusL10n,
        completion: @escaping (Bool) -> Void,
        finished: @escaping () -> Void
    ) {
        self.controller = controller
        self.accountId = accountId
        self.l10n = l10n
        self.completion = completion
        self.finished = finished
    }

    func present() {
        guard let controller else {
            self.finished()
            return
        }
        self.requestGalleryAccess(from: controller)
    }

    private func requestGalleryAccess(from controller: UIViewController) {
        let presentAuthorized = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.showHUD()
            self.loadGalleryItems { [weak self, weak controller] items in
                guard let self, let controller else {
                    self?.finish(cancelled: true)
                    return
                }
                self.hideHUD()
                let gallery = AorusAnimatedProfileMediaGalleryController(
                    items: items,
                    l10n: self.l10n,
                    selected: { [weak self] asset, kind, gallery in
                        self?.load(asset: asset, kind: kind, from: gallery)
                    },
                    cancelled: { [weak self] gallery in
                        gallery.dismiss(animated: true) {
                            self?.finish(cancelled: true)
                        }
                    }
                )
                let navigation = UINavigationController(rootViewController: gallery)
                navigation.modalPresentationStyle = .fullScreen
                controller.present(navigation, animated: true)
            }
        }

        let status = PHPhotoLibrary.authorizationStatus()
        let isAuthorized: Bool
        if status == .authorized {
            isAuthorized = true
        } else if #available(iOS 14.0, *) {
            isAuthorized = status == .limited
        } else {
            isAuthorized = false
        }
        if isAuthorized {
            presentAuthorized()
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    let authorized: Bool
                    if status == .authorized {
                        authorized = true
                    } else if #available(iOS 14.0, *) {
                        authorized = status == .limited
                    } else {
                        authorized = false
                    }
                    if authorized {
                        presentAuthorized()
                    } else {
                        self.finish(error: AorusAnimatedProfileMediaError.unsupported)
                    }
                }
            }
        } else {
            let alert = UIAlertController(
                title: nil,
                message: self.l10n.animatedProfileGalleryAccessDenied,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.finish(cancelled: true)
            })
            controller.present(alert, animated: true)
        }
    }

    private func loadGalleryItems(completion: @escaping ([AorusAnimatedProfileGalleryItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let videoOptions = PHFetchOptions()
            videoOptions.sortDescriptors = sortDescriptors
            var items: [AorusAnimatedProfileGalleryItem] = []

            let videos = PHAsset.fetchAssets(with: .video, options: videoOptions)
            videos.enumerateObjects { asset, _, _ in
                if asset.duration > 0.0, asset.duration <= 30.0 {
                    items.append(AorusAnimatedProfileGalleryItem(asset: asset, kind: .video))
                }
            }

            let animatedCollections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .smartAlbumAnimated,
                options: nil
            )
            animatedCollections.enumerateObjects { collection, _, _ in
                let gifOptions = PHFetchOptions()
                gifOptions.sortDescriptors = sortDescriptors
                let animatedImages = PHAsset.fetchAssets(in: collection, options: gifOptions)
                animatedImages.enumerateObjects { asset, _, _ in
                    items.append(AorusAnimatedProfileGalleryItem(asset: asset, kind: .gif))
                }
            }
            items.sort { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
            DispatchQueue.main.async { completion(items) }
        }
    }

    private func load(
        asset: PHAsset,
        kind: AorusAnimatedProfileMediaKind,
        from gallery: UIViewController
    ) {
        gallery.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.showHUD()
            switch kind {
            case .video:
                let options = PHVideoRequestOptions()
                options.version = .original
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { [weak self] avAsset, _, _ in
                    guard let self, let avAsset else {
                        DispatchQueue.main.async { self?.finish(error: AorusAnimatedProfileMediaError.unreadable) }
                        return
                    }
                    self.copyVideoAsset(avAsset)
                }
            case .gif:
                guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
                    $0.uniformTypeIdentifier.lowercased().contains("gif")
                        || $0.originalFilename.lowercased().hasSuffix(".gif")
                }) else {
                    self.finish(error: AorusAnimatedProfileMediaError.unreadable)
                    return
                }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aorus-profile-source-\(UUID().uuidString).gif")
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { [weak self] error in
                    DispatchQueue.main.async {
                        if let error {
                            self?.finish(error: error)
                        } else {
                            self?.presentCrop(url: destination, kind: .gif)
                        }
                    }
                }
            }
        }
    }

    private func copyVideoAsset(_ asset: AVAsset) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorus-profile-source-\(UUID().uuidString).mov")
        if let urlAsset = asset as? AVURLAsset {
            do {
                try FileManager.default.copyItem(at: urlAsset.url, to: destination)
                DispatchQueue.main.async { [weak self] in self?.presentCrop(url: destination, kind: .video) }
                return
            } catch {
                // Some iCloud-backed Photos assets expose a URL that cannot be
                // copied directly. Exporting the AVAsset is the reliable path.
            }
        }
        self.exportVideoAsset(asset, to: destination)
    }

    private func exportVideoAsset(_ asset: AVAsset, to destination: URL) {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            DispatchQueue.main.async { [weak self] in self?.finish(error: AorusAnimatedProfileMediaError.conversion) }
            return
        }
        try? FileManager.default.removeItem(at: destination)
        exporter.outputURL = destination
        exporter.outputFileType = exporter.supportedFileTypes.contains(.mov) ? .mov : exporter.supportedFileTypes.first
        exporter.shouldOptimizeForNetworkUse = true
        exporter.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard exporter.status == .completed else {
                    self?.finish(error: exporter.error ?? AorusAnimatedProfileMediaError.conversion)
                    return
                }
                self?.presentCrop(url: destination, kind: .video)
            }
        }
    }

    private func presentCrop(url: URL, kind: AorusAnimatedProfileMediaKind) {
        guard let controller = self.controller,
              let preview = AorusAnimatedProfileCropController.previewImage(url: url, kind: kind) else {
            try? FileManager.default.removeItem(at: url)
            self.finish(error: AorusAnimatedProfileMediaError.unreadable)
            return
        }
        self.hud?.removeFromSuperview()
        self.hud = nil
        let cropController = AorusAnimatedProfileCropController(
            sourceURL: url,
            kind: kind,
            preview: preview,
            l10n: self.l10n
        ) { [weak self] crop in
            guard let self else { return }
            guard let crop else {
                try? FileManager.default.removeItem(at: url)
                self.finish(cancelled: true)
                return
            }
            self.showHUD()
            self.process(url: url, kind: kind, crop: crop)
        }
        controller.present(cropController, animated: true)
    }

    private func process(
        url: URL,
        kind: AorusAnimatedProfileMediaKind,
        crop: AorusAnimatedProfileCrop
    ) {
        AorusAnimatedProfileMediaProcessor.process(
            sourceURL: url,
            kind: kind,
            crop: crop
        ) { [weak self] result in
            try? FileManager.default.removeItem(at: url)
            guard let self else { return }
            switch result {
            case let .success(media):
                AorusAnimatedProfileBackgroundStore.installSelectedMedia(
                    mediaURL: media.mediaURL,
                    posterURL: media.posterURL,
                    accountId: self.accountId
                ) { [weak self] installationResult in
                    try? FileManager.default.removeItem(at: media.mediaURL)
                    try? FileManager.default.removeItem(at: media.posterURL)
                    guard let self else { return }
                    switch installationResult {
                    case .success:
                        self.hud?.removeFromSuperview()
                        self.hud = nil
                        self.completion(true)
                        self.finished()
                    case let .failure(error):
                        self.finish(error: error)
                    }
                }
            case let .failure(error):
                self.finish(error: error)
            }
        }
    }

    private func showHUD() {
        guard let hostView = self.controller?.view.window ?? self.controller?.view else { return }
        self.hud?.removeFromSuperview()
        let hud = AorusAnimatedProfileImportHUD(
            text: self.l10n.preparingAnimatedProfileBackground
        )
        hud.frame = hostView.bounds
        hostView.addSubview(hud)
        self.hud = hud
    }

    private func hideHUD() {
        self.hud?.removeFromSuperview()
        self.hud = nil
    }

    private func finish(cancelled: Bool) {
        self.hud?.removeFromSuperview()
        self.hud = nil
        if !cancelled {
            self.completion(false)
        }
        self.finished()
    }

    private func finish(error: Error) {
        self.hud?.removeFromSuperview()
        self.hud = nil
        self.completion(false)

        let message: String
        if let error = error as? AorusAnimatedProfileMediaError {
            switch error {
            case .tooLong:
                message = self.l10n.animatedProfileMediaTooLong
            case .unsupported:
                message = self.l10n.animatedProfileMediaUnsupported
            default:
                message = self.l10n.animatedProfileMediaFailed
            }
        } else if let error = error as? AorusBannerServiceError {
            switch error {
            case .rateLimited:
                message = self.l10n.animatedProfileRateLimited
            case .uploadTooLarge:
                message = self.l10n.animatedProfileUploadTooLarge
            default:
                message = self.l10n.animatedProfileSyncFailed
            }
        } else {
            message = self.l10n.animatedProfileMediaFailed
        }

        if let controller = self.controller {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(alert, animated: true)
        }
        self.finished()
    }
}

// MARK: - Filtered media gallery

private struct AorusAnimatedProfileGalleryItem {
    let asset: PHAsset
    let kind: AorusAnimatedProfileMediaKind
}

private final class AorusAnimatedProfileGalleryCell: UICollectionViewCell {
    static let reuseIdentifier = "AorusAnimatedProfileGalleryCell"

    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private let kindView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    var representedIdentifier: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.layer.cornerRadius = 4.0
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.clipsToBounds = true
        self.contentView.addSubview(self.imageView)

        self.kindView.clipsToBounds = true
        self.kindView.layer.cornerRadius = 9.0
        self.contentView.addSubview(self.kindView)
        self.durationLabel.textColor = .white
        self.durationLabel.font = .monospacedDigitSystemFont(ofSize: 11.0, weight: .semibold)
        self.durationLabel.textAlignment = .center
        self.kindView.contentView.addSubview(self.durationLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.representedIdentifier = nil
        self.imageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.imageView.frame = self.contentView.bounds
        let size = self.durationLabel.sizeThatFits(CGSize(width: 90.0, height: 18.0))
        let width = max(28.0, size.width + 10.0)
        self.kindView.frame = CGRect(
            x: self.contentView.bounds.width - width - 6.0,
            y: self.contentView.bounds.height - 24.0,
            width: width,
            height: 18.0
        )
        self.durationLabel.frame = self.kindView.bounds
    }

    func update(image: UIImage?, label: String) {
        self.imageView.image = image
        self.durationLabel.text = label
        self.setNeedsLayout()
    }
}

private final class AorusAnimatedProfileMediaGalleryController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout {
    private let items: [AorusAnimatedProfileGalleryItem]
    private let l10n: AorusL10n
    private let selected: (PHAsset, AorusAnimatedProfileMediaKind, UIViewController) -> Void
    private let cancelled: (UIViewController) -> Void
    private let imageManager = PHCachingImageManager()
    private let collectionView: UICollectionView
    private let emptyLabel = UILabel()

    init(
        items: [AorusAnimatedProfileGalleryItem],
        l10n: AorusL10n,
        selected: @escaping (PHAsset, AorusAnimatedProfileMediaKind, UIViewController) -> Void,
        cancelled: @escaping (UIViewController) -> Void
    ) {
        self.items = items
        self.l10n = l10n
        self.selected = selected
        self.cancelled = cancelled
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 2.0
        layout.minimumInteritemSpacing = 2.0
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.title = self.l10n.animatedProfileGalleryTitle
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(self.cancelPressed)
        )
        self.collectionView.backgroundColor = .systemBackground
        self.collectionView.alwaysBounceVertical = true
        self.collectionView.dataSource = self
        self.collectionView.delegate = self
        self.collectionView.register(
            AorusAnimatedProfileGalleryCell.self,
            forCellWithReuseIdentifier: AorusAnimatedProfileGalleryCell.reuseIdentifier
        )
        self.view.addSubview(self.collectionView)

        self.emptyLabel.text = self.l10n.animatedProfileGalleryEmpty
        self.emptyLabel.textColor = .secondaryLabel
        self.emptyLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.numberOfLines = 2
        self.emptyLabel.isHidden = !self.items.isEmpty
        self.view.addSubview(self.emptyLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.collectionView.frame = self.view.bounds
        self.emptyLabel.frame = self.view.bounds.insetBy(dx: 32.0, dy: 120.0)
    }

    @objc private func cancelPressed() {
        self.cancelled(self)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: AorusAnimatedProfileGalleryCell.reuseIdentifier,
            for: indexPath
        ) as? AorusAnimatedProfileGalleryCell else {
            return UICollectionViewCell()
        }
        let item = self.items[indexPath.item]
        let identifier = item.asset.localIdentifier
        cell.representedIdentifier = identifier
        let label: String
        switch item.kind {
        case .video:
            let total = max(0, Int(item.asset.duration.rounded()))
            label = String(format: "%d:%02d", total / 60, total % 60)
        case .gif:
            label = "GIF"
        }
        cell.update(image: nil, label: label)
        let scale = UIScreen.main.scale
        let side = max(120.0, cell.bounds.width * scale)
        self.imageManager.requestImage(
            for: item.asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: nil
        ) { image, _ in
            guard cell.representedIdentifier == identifier else { return }
            cell.update(image: image, label: label)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let side = floor((collectionView.bounds.width - 4.0) / 3.0)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.isUserInteractionEnabled = false
        let item = self.items[indexPath.item]
        self.selected(item.asset, item.kind, self)
    }
}

// MARK: - Banner crop editor

private final class AorusAnimatedProfileCropController: UIViewController, UIScrollViewDelegate {
    private let sourceURL: URL
    private let kind: AorusAnimatedProfileMediaKind
    private let preview: UIImage
    private let l10n: AorusL10n
    private let completion: (AorusAnimatedProfileCrop?) -> Void
    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let mediaView = UIView()
    private let imageView = UIImageView()
    private let borderView = UIView()
    private let hintLabel = UILabel()
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerObserver: NSObjectProtocol?
    private var mediaBaseSize = CGSize.zero
    private var didConfigureViewport = false

    init(
        sourceURL: URL,
        kind: AorusAnimatedProfileMediaKind,
        preview: UIImage,
        l10n: AorusL10n,
        completion: @escaping (AorusAnimatedProfileCrop?) -> Void
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.preview = preview
        self.l10n = l10n
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let playerObserver {
            NotificationCenter.default.removeObserver(playerObserver)
        }
    }

    static func previewImage(url: URL, kind: AorusAnimatedProfileMediaKind) -> UIImage? {
        switch kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600.0, height: 1600.0)
            let image = (try? generator.copyCGImage(at: CMTime(seconds: 0.05, preferredTimescale: 600), actualTime: nil))
                ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
            return image.map(UIImage.init(cgImage:))
        case .gif:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            return UIImage(cgImage: image)
        }
    }

    private static func videoOnlyPreviewAsset(url: URL) -> AVAsset? {
        let sourceAsset = AVURLAsset(url: url)
        guard let sourceTrack = sourceAsset.tracks(withMediaType: .video).first else {
            return nil
        }
        let composition = AVMutableComposition()
        guard let targetTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        do {
            try targetTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: sourceAsset.duration),
                of: sourceTrack,
                at: .zero
            )
            targetTrack.preferredTransform = sourceTrack.preferredTransform
            return composition
        } catch {
            return nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor(white: 0.04, alpha: 1.0)

        self.titleLabel.text = self.l10n.animatedProfileCropTitle
        self.titleLabel.textColor = .white
        self.titleLabel.font = .systemFont(ofSize: 17.0, weight: .semibold)
        self.titleLabel.textAlignment = .center
        self.view.addSubview(self.titleLabel)

        self.cancelButton.setTitle(self.l10n.cancel, for: .normal)
        self.cancelButton.setTitleColor(.white, for: .normal)
        self.cancelButton.titleLabel?.font = .systemFont(ofSize: 17.0)
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        self.view.addSubview(self.cancelButton)

        self.applyButton.setTitle(self.l10n.animatedProfileCropApply, for: .normal)
        self.applyButton.setTitleColor(UIColor(red: 0.67, green: 0.31, blue: 1.0, alpha: 1.0), for: .normal)
        self.applyButton.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
        self.applyButton.addTarget(self, action: #selector(self.applyPressed), for: .touchUpInside)
        self.view.addSubview(self.applyButton)

        self.scrollView.delegate = self
        self.scrollView.clipsToBounds = true
        self.scrollView.backgroundColor = .black
        self.scrollView.bounces = true
        self.scrollView.bouncesZoom = true
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.view.addSubview(self.scrollView)

        let longestSide = max(self.preview.size.width, self.preview.size.height)
        let baseScale = min(1.0, 1600.0 / max(1.0, longestSide))
        self.mediaBaseSize = CGSize(
            width: max(1.0, self.preview.size.width * baseScale),
            height: max(1.0, self.preview.size.height * baseScale)
        )
        self.mediaView.frame = CGRect(origin: .zero, size: self.mediaBaseSize)
        self.scrollView.addSubview(self.mediaView)
        self.imageView.image = self.preview
        self.imageView.contentMode = .scaleToFill
        self.imageView.frame = self.mediaView.bounds
        self.mediaView.addSubview(self.imageView)

        if case .video = self.kind,
           let previewAsset = Self.videoOnlyPreviewAsset(url: self.sourceURL) {
            let player = AVPlayer(playerItem: AVPlayerItem(asset: previewAsset))
            player.isMuted = true
            player.actionAtItemEnd = .none
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resize
            layer.frame = self.mediaView.bounds
            self.mediaView.layer.addSublayer(layer)
            self.player = player
            self.playerLayer = layer
            self.playerObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            player.play()
        }

        self.borderView.isUserInteractionEnabled = false
        self.borderView.layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor
        self.borderView.layer.borderWidth = 1.0 / UIScreen.main.scale
        self.borderView.layer.cornerRadius = 8.0
        self.view.addSubview(self.borderView)

        self.hintLabel.text = self.l10n.animatedProfileCropHint
        self.hintLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        self.hintLabel.font = .systemFont(ofSize: 14.0, weight: .medium)
        self.hintLabel.textAlignment = .center
        self.view.addSubview(self.hintLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let preservedCrop = self.didConfigureViewport ? self.currentCrop() : nil
        let safe = self.view.safeAreaInsets
        let navigationY = safe.top
        self.cancelButton.frame = CGRect(x: 10.0, y: navigationY, width: 92.0, height: 52.0)
        self.applyButton.frame = CGRect(x: self.view.bounds.width - 112.0, y: navigationY, width: 102.0, height: 52.0)
        self.titleLabel.frame = CGRect(x: 104.0, y: navigationY, width: self.view.bounds.width - 208.0, height: 52.0)

        let availableTop = navigationY + 70.0
        let availableBottom = self.view.bounds.height - safe.bottom - 52.0
        let maxWidth = max(1.0, self.view.bounds.width - 24.0)
        let maxHeight = max(1.0, availableBottom - availableTop)
        let cropWidth = min(maxWidth, maxHeight * AorusAnimatedProfileCrop.aspectRatio)
        let cropHeight = cropWidth / AorusAnimatedProfileCrop.aspectRatio
        let cropFrame = CGRect(
            x: floor((self.view.bounds.width - cropWidth) * 0.5),
            y: floor(availableTop + (maxHeight - cropHeight) * 0.5),
            width: cropWidth,
            height: cropHeight
        )
        self.scrollView.frame = cropFrame
        self.borderView.frame = cropFrame
        self.hintLabel.frame = CGRect(
            x: 20.0,
            y: cropFrame.maxY + 12.0,
            width: self.view.bounds.width - 40.0,
            height: 24.0
        )
        self.imageView.frame = self.mediaView.bounds
        self.playerLayer?.frame = self.mediaView.bounds
        self.configureViewport(crop: preservedCrop)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.player?.pause()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.mediaView
    }

    private func configureViewport(crop: AorusAnimatedProfileCrop?) {
        guard self.scrollView.bounds.width > 1.0,
              self.scrollView.bounds.height > 1.0,
              self.mediaBaseSize.width > 1.0,
              self.mediaBaseSize.height > 1.0 else {
            return
        }
        let minimum = max(
            self.scrollView.bounds.width / self.mediaBaseSize.width,
            self.scrollView.bounds.height / self.mediaBaseSize.height
        )
        self.scrollView.minimumZoomScale = minimum
        self.scrollView.maximumZoomScale = max(minimum * 6.0, minimum + 0.01)
        let target = crop?.clampedRect ?? self.centeredInitialCrop().clampedRect
        let zoom = min(
            self.scrollView.maximumZoomScale,
            max(minimum, self.scrollView.bounds.width / (target.width * self.mediaBaseSize.width))
        )
        self.scrollView.zoomScale = zoom
        self.scrollView.contentOffset = CGPoint(
            x: target.minX * self.mediaBaseSize.width * zoom,
            y: target.minY * self.mediaBaseSize.height * zoom
        )
        self.didConfigureViewport = true
    }

    private func centeredInitialCrop() -> AorusAnimatedProfileCrop {
        let sourceAspect = self.mediaBaseSize.width / self.mediaBaseSize.height
        let targetAspect = AorusAnimatedProfileCrop.aspectRatio
        if sourceAspect > targetAspect {
            let width = targetAspect / sourceAspect
            return AorusAnimatedProfileCrop(normalizedRect: CGRect(x: (1.0 - width) * 0.5, y: 0.0, width: width, height: 1.0))
        } else {
            let height = sourceAspect / targetAspect
            return AorusAnimatedProfileCrop(normalizedRect: CGRect(x: 0.0, y: (1.0 - height) * 0.5, width: 1.0, height: height))
        }
    }

    private func currentCrop() -> AorusAnimatedProfileCrop {
        let zoom = max(self.scrollView.zoomScale, 0.0001)
        let rect = CGRect(
            x: self.scrollView.contentOffset.x / zoom / self.mediaBaseSize.width,
            y: self.scrollView.contentOffset.y / zoom / self.mediaBaseSize.height,
            width: self.scrollView.bounds.width / zoom / self.mediaBaseSize.width,
            height: self.scrollView.bounds.height / zoom / self.mediaBaseSize.height
        )
        return AorusAnimatedProfileCrop(normalizedRect: rect)
    }

    @objc private func cancelPressed() {
        self.dismiss(animated: true) { [completion = self.completion] in
            completion(nil)
        }
    }

    @objc private func applyPressed() {
        let crop = self.currentCrop()
        self.applyButton.isEnabled = false
        self.dismiss(animated: true) { [completion = self.completion] in
            completion(crop)
        }
    }
}
