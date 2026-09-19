import Foundation
import UIKit

// Stand-ins for what `AorusPluginControllers.swift` borrows from Telegram, so that file can
// be type-checked in the preflight instead of forty minutes into the Bazel build.
//
// Three builds were lost to type errors in that one file — a property whose name a base
// class already used, a case pattern from a type with the same-looking name, an optional
// wrapped twice — and none of them could be seen by parsing, which is all CI could do with
// a file that names Telegram's modules. So the modules are stood in for here: the file's
// imports are stripped, these declarations take their place, and the body is checked for
// real against the iOS SDK.
//
// Every declaration below is copied from the pinned Telegram tree and must keep matching
// it. A stub that drifts is worse than no stub, so the two places most likely to drift —
// `AorusPluginRuntimeManager`, which is ours and changes with the feature — are checked
// against the real file by `release_security_check.py`, signature by signature.

// MARK: - AsyncDisplayKit

open class ASDisplayNode {
    public var view: UIView = UIView()
    public var backgroundColor: UIColor?
    public init() {}
}

// MARK: - Display

public struct ContainerViewLayout: Equatable {
    public var size: CGSize
    public var intrinsicInsets: UIEdgeInsets
}

public enum ContainedViewLayoutTransitionCurve: Equatable {
    case linear
    case easeInOut
    case easeIn
    case spring
}

public enum ContainedViewLayoutTransition {
    case immediate
    case animated(duration: Double, curve: ContainedViewLayoutTransitionCurve)

    public func updateFrame(view: UIView, frame: CGRect, force: Bool = false, beginWithCurrentState: Bool = false, delay: Double = 0.0, completion: ((Bool) -> Void)? = nil) {
    }
}

public enum StatusBarStyle {
    case Black
    case White
    case Hide
    case Ignore
}

public final class StatusBar {
    public var statusBarStyle: StatusBarStyle = .Black
}

public enum NavigationBarStyle {
    case legacy
    case glass
}

public enum NavigationBar {
    public typealias Style = NavigationBarStyle
}

public final class NavigationBarPresentationData {
    public convenience init(presentationData: PresentationData, style: NavigationBarStyle = .legacy) {
        self.init()
    }

    public init() {}
}

public enum ViewControllerNavigationPresentation {
    case `default`
    case master
    case modal
    case flatModal
    case standaloneModal
    case standaloneFlatModal
    case modalInLargeLayout
    case modalInCompactLayout
}

@objc open class ViewController: UIViewController {
    public struct NavigationLayout {
        public var navigationFrame: CGRect
        public var defaultContentHeight: CGFloat
    }

    public let statusBar = StatusBar()
    open var navigationPresentation: ViewControllerNavigationPresentation = .default

    private var _displayNode: ASDisplayNode?
    public final var displayNode: ASDisplayNode {
        get {
            if let value = self._displayNode { return value }
            self.loadDisplayNode()
            return self._displayNode!
        } set(value) {
            self._displayNode = value
        }
    }

    public init(navigationBarPresentationData: NavigationBarPresentationData?) {
        super.init(nibName: nil, bundle: nil)
    }

    required public init(coder aDecoder: NSCoder) {
        super.init(nibName: nil, bundle: nil)
    }

    open func loadDisplayNode() {
        self._displayNode = ASDisplayNode()
    }

    open func displayNodeDidLoad() {}

    open func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {}

    open func navigationLayout(layout: ContainerViewLayout) -> NavigationLayout {
        return NavigationLayout(navigationFrame: CGRect(), defaultContentHeight: 0.0)
    }
}

open class ViewControllerTracingNode: ASDisplayNode {
}

open class NavigationController: UINavigationController {
    public func pushViewController(_ controller: ViewController) {}
}

// MARK: - TelegramPresentationData

public final class PresentationThemeList {
    public let blocksBackgroundColor = UIColor.white
    public let itemBlocksBackgroundColor = UIColor.white
    public let itemPrimaryTextColor = UIColor.black
    public let itemSecondaryTextColor = UIColor.gray
    public let itemAccentColor = UIColor.blue
    public let itemDestructiveColor = UIColor.red
    public let itemBlocksSeparatorColor = UIColor.lightGray
}

public final class PresentationThemeStatusBar {
    public let style: StatusBarStyle = .Black
}

public final class PresentationThemeRootController {
    public let statusBarStyle = PresentationThemeStatusBar()
}

public final class PresentationThemeActionSheet {
    public let primaryTextColor = UIColor.black
}

public final class PresentationTheme {
    public let overallDarkAppearance = false
    public let list = PresentationThemeList()
    public let rootController = PresentationThemeRootController()
    public let actionSheet = PresentationThemeActionSheet()
}

public final class PresentationStrings {
    public let Common_Cancel = "Cancel"
    public let baseLanguageCode = "en"
}

public final class PresentationData {
    public let theme = PresentationTheme()
    public let strings = PresentationStrings()
}

// MARK: - SwiftSignalKit / AccountContext

public final class Atomic<T> {
    private var value: T

    public init(value: T) {
        self.value = value
    }

    public func with<R>(_ f: (T) -> R) -> R {
        return f(self.value)
    }
}

public protocol SharedAccountContext: AnyObject {
    var currentPresentationData: Atomic<PresentationData> { get }
}

public protocol AccountContext: AnyObject {
    var sharedContext: SharedAccountContext { get }
}

// MARK: - AorusGramUI's own module surface

public enum AorusLang {
    case ru
    case en

    public static var current: AorusLang { return .en }
}

public func aorusL(_ ru: String, _ en: String) -> String {
    return AorusLang.current == .ru ? ru : en
}

/// The entitlement verdict, read by the editor's debug host. The real one is in the core
/// module and reaches the licence stack; only the shape matters here.
public enum AorusLicenseAccess {
    public static var isAllowed: Bool { return true }
}

/// The plugin runtime. It lives in the same module as the screens and pulls in TelegramCore,
/// so only what the screens call is stood in for. Signatures are checked against the real
/// file — see `check_plugin_ui_stubs` in `release_security_check.py`.
public final class AorusPluginRuntimeManager {
    public static let shared = AorusPluginRuntimeManager()

    public func configure(context: AccountContext) {}
    public func start(id: String, completion: ((AorusPluginRunError?) -> Void)? = nil) {}
    public func stop(id: String, completion: (() -> Void)? = nil) {}
    public func restart(id: String, completion: ((AorusPluginRunError?) -> Void)? = nil) {}
    public func sandbox(id: String) -> AorusPluginSandbox? { return nil }
    public func settingsSchema(id: String) -> [AorusPluginSettingField] { return [] }
    public func page(pluginId: String, pageId: String) -> AorusPluginUIPage? { return nil }
    public func pluginSettingsShortcuts() -> [(pluginId: String, shortcut: AorusPluginSettingsShortcut)] { return [] }
    public func performSettingsShortcut(pluginId: String, id: String) {}
    public func openURL(pluginId: String, url: String, completion: ((Error?) -> Void)? = nil) {}
    public func dispatchUIAction(pluginId: String, pageId: String, rowId: String, value: AorusPluginJSONValue?) {}
}
