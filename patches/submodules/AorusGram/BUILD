load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

apple_static_xcframework_import(
    name = "LibXray",
    xcframework_imports = glob([
        "ThirdParty/LibXray.xcframework/**",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

objc_library(
    name = "LibXraySystemLibraries",
    sdk_dylibs = [
        "libresolv",
    ],
)

filegroup(
    name = "AorusVideoMaskImages",
    srcs = glob([
        "Resources/VideoMasks/*.png",
    ]),
)

plist_fragment(
    name = "AorusVideoMaskAssetsInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>com.aorusgram.VideoMaskAssets</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>AorusVideoMaskAssets</string>
    """
)

apple_resource_bundle(
    name = "AorusVideoMaskAssets",
    infoplists = [
        ":AorusVideoMaskAssetsInfoPlist",
    ],
    resources = [
        ":AorusVideoMaskImages",
    ],
)

swift_library(
    name = "AorusGram",
    module_name = "AorusGram",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Telegram’s deployment target is below iOS 14; SwiftUI here uses .toolbar / ToolbarItem (14+).
    copts = ["-Xfrontend", "-disable-availability-checking"],
    data = [
        ":AorusVideoMaskAssets",
    ],
    deps = [
        ":LibXray",
        ":LibXraySystemLibraries",
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/AorusBadge:AorusBadge",
    ],
    visibility = [
        "//visibility:public",
    ],
)
