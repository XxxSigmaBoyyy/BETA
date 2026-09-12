import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit
import Display
import MediaResources
import AnimatedStickerNode

// Embedded subscription animations: large duck illustrations for the full-screen
// flows + small looping icons used inside the entry banner.
enum SubscriptionDuck: String {
    case trial
    case expired
    case purchase
    case fire        // small banner icon — "пробный период активен"
    case boost       // small banner icon — "подписка активна"
    case confirm     // activation confirmation prompt
    case error       // activation failed (key used / invalid)
    case outdated    // mandatory application update

    var base64: String {
        switch self {
        case .trial:    return SubscriptionAnimationAssets.trial
        case .expired:  return SubscriptionAnimationAssets.expired
        case .purchase: return SubscriptionAnimationAssets.purchase
        case .fire:     return SubscriptionAnimationAssets.fire
        case .boost:    return SubscriptionAnimationAssets.boost
        case .confirm:  return SubscriptionAnimationAssets.confirm
        case .error:    return SubscriptionAnimationAssets.error
        case .outdated: return SubscriptionAnimationAssets.outdated
        }
    }
}

// Minimal AnimatedStickerNodeSource for a local gzip-tgs file. The direct frame
// source decompresses (TGGUnzipData) internally, so we hand it the raw .tgs path.
private final class LocalTgsSource: AnimatedStickerNodeSource {
    let fitzModifier: EmojiFitzModifier? = nil
    let isVideo: Bool = false
    private let path: String

    init(path: String) { self.path = path }

    func cachedDataPath(width: Int, height: Int) -> Signal<(String, Bool), NoError> {
        return .never()
    }

    func directDataPath(attemptSynchronously: Bool) -> Signal<String?, NoError> {
        return .single(self.path)
    }
}

// UIView wrapper hosting a looping Telegram TGS animation via the real RLottie
// pipeline (AnimatedStickerNode). Safe: if the asset is missing it shows nothing.
final class SubscriptionDuckView: UIView {
    private let stickerNode = DefaultAnimatedStickerNodeImpl()

    init(duck: SubscriptionDuck, renderSizePx: Int = 320) {
        super.init(frame: .zero)
        addSubview(stickerNode.view)
        if let path = SubscriptionDuckView.materialize(duck) {
            stickerNode.setup(
                source: LocalTgsSource(path: path),
                width: renderSizePx,
                height: renderSizePx,
                playbackMode: .loop,
                mode: .direct(cachePathPrefix: nil)
            )
            stickerNode.visibility = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        stickerNode.frame = bounds
        stickerNode.updateLayout(size: bounds.size)
    }

    // Decode the embedded base64 .tgs to a cached file once; returns its path.
    private static func materialize(_ duck: SubscriptionDuck) -> String? {
        let dir = NSTemporaryDirectory() + "aorus_subscription_anim"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Key the cache filename on a stable content signature of the embedded
        // asset (FNV-1a over the base64). Without this, a fixed "<duck>.tgs" name
        // reuses a stale .tgs cached by a previous app version — so a changed
        // animation would never appear after an update. A new asset → new hash →
        // new filename → the old cached file is ignored and the new one is written.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in duck.base64.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let path = dir + "/" + duck.rawValue + "-" + String(hash, radix: 16) + ".tgs"
        if FileManager.default.fileExists(atPath: path) { return path }
        guard let data = Data(base64Encoded: duck.base64), !data.isEmpty else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }
}
