import Foundation

struct AorusUpdateRelease: Equatable {
    let version: String
    let build: Int
    let url: URL
    let size: Int64?
}

enum AorusUpdateManifestParser {
    private struct Manifest: Decodable {
        struct App: Decodable {
            struct Version: Decodable {
                let version: String
                let buildVersion: String
                let downloadURL: String
                let size: Int64?
            }

            let bundleIdentifier: String
            let version: String?
            let buildVersion: String?
            let downloadURL: String?
            let size: Int64?
            let versions: [Version]?
        }

        let apps: [App]
    }

    static func newestRelease(in data: Data,
                              bundleIdentifier: String = "com.aorusgram",
                              allowedHost: String = "download.aorusgram.com",
                              maximumSize: Int64 = 768 * 1024 * 1024) -> AorusUpdateRelease? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let app = manifest.apps.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }

        func make(version: String, buildVersion: String, downloadURL: String,
                  size: Int64?) -> AorusUpdateRelease? {
            guard let build = Int(buildVersion), build >= 0,
                  let url = URL(string: downloadURL),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == allowedHost,
                  url.port == nil || url.port == 443,
                  url.user == nil,
                  url.password == nil,
                  url.pathExtension.lowercased() == "ipa",
                  size == nil || (size! > 0 && size! <= maximumSize) else {
                return nil
            }
            return AorusUpdateRelease(version: version, build: build, url: url, size: size)
        }

        let versions = (app.versions ?? []).compactMap {
            make(version: $0.version, buildVersion: $0.buildVersion,
                 downloadURL: $0.downloadURL, size: $0.size)
        }
        if let newest = versions.max(by: { $0.build < $1.build }) {
            return newest
        }

        guard let version = app.version,
              let buildVersion = app.buildVersion,
              let downloadURL = app.downloadURL else { return nil }
        return make(version: version, buildVersion: buildVersion,
                    downloadURL: downloadURL, size: app.size)
    }
}
