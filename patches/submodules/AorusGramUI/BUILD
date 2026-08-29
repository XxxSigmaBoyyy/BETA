load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AorusGramUI",
    module_name = "AorusGramUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Telegram’s deployment target is below iOS 14; SwiftUI uses .toolbar / ToolbarItem (14+).
    copts = ["-Xfrontend", "-disable-availability-checking"],
    # No sdk_frameworks here: this rules_swift removed the attribute from
    # swift_library, and Swift autolinking already pulls in the SDK frameworks this
    # module imports — the same way AVFoundation, Photos, Speech and Intents are
    # linked in the builds that shipped.
    deps = [
        "//submodules/AorusGram:AorusGram",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/ImageBlur:ImageBlur",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/ItemListPeerActionItem:ItemListPeerActionItem",
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
        # The AorusAI message actions are a native context menu level, built from
        # ContextUI's own items. Nothing in ContextUI's dependency graph reaches back
        # into TelegramUI or PeerInfo, so this cannot close a cycle.
        "//submodules/ContextUI:ContextUI",
        "//submodules/ComponentFlow",
        "//submodules/ActivityIndicator:ActivityIndicator",
        "//submodules/TextFormat:TextFormat",
        "//submodules/AppBundle:AppBundle",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/TelegramUI/Components/ItemListDatePickerItem:ItemListDatePickerItem",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
