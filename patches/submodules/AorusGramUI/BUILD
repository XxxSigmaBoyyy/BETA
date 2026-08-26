load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AorusGramUI",
    module_name = "AorusGramUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Telegram’s deployment target is below iOS 14; SwiftUI uses .toolbar / ToolbarItem (14+).
    copts = ["-Xfrontend", "-disable-availability-checking"],
    sdk_frameworks = ["QuickLook"],
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
        "//submodules/ComponentFlow",
        "//submodules/ActivityIndicator:ActivityIndicator",
        "//submodules/TextFormat:TextFormat",
        "//submodules/AppBundle:AppBundle",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/TelegramUI/Components/ItemListDatePickerItem:ItemListDatePickerItem",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
