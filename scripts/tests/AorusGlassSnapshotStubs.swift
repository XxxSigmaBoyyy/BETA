import Foundation

// Stand-ins for the two things `AorusGlassSnapshot` borrows from the rest of its own module,
// so that the file can be type-checked on its own in the preflight instead of an hour into the
// Bazel build.
//
// Everything that is actually at risk in that file is UIKit — window walking, a render-server
// capture, cropping, corner shapes, availability against the iOS version the app deploys to —
// and none of it needs the licence stack to be present to be checked. What the stubs stand in
// for is two reads, and the build itself still checks that they are the real ones.

enum AorusLicenseAccess {
    static var isAllowed: Bool { return true }
}

enum AorusGramConfig {
    enum Feature {
        case glassUI
    }

    static func isEnabled(_ feature: Feature) -> Bool { return true }
}
