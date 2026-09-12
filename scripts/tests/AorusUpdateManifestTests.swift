import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusUpdateManifest test failed: \(message)\n", stderr)
        exit(1)
    }
}

private func data(_ json: String) -> Data { Data(json.utf8) }

@main
private enum AorusUpdateManifestTests {
    static func main() {
        let manifest = data("""
        {"apps":[{"bundleIdentifier":"com.aorusgram","versions":[
          {"version":"1.0","buildVersion":"9","downloadURL":"https://download.aorusgram.com/old.ipa","size":100},
          {"version":"2.0","buildVersion":"24","downloadURL":"https://download.aorusgram.com/new.ipa?v=2","size":200}
        ]}]}
        """)
        let newest = AorusUpdateManifestParser.newestRelease(in: manifest)
        require(newest?.version == "2.0" && newest?.build == 24,
                "highest numeric build is selected")

        let hostileHost = data("""
        {"apps":[{"bundleIdentifier":"com.aorusgram","versions":[
          {"version":"3.0","buildVersion":"30","downloadURL":"https://evil.example/AorusGram.ipa","size":200}
        ]}]}
        """)
        require(AorusUpdateManifestParser.newestRelease(in: hostileHost) == nil,
                "cross-host download is rejected")

        let oversized = data("""
        {"apps":[{"bundleIdentifier":"com.aorusgram","versions":[
          {"version":"3.0","buildVersion":"30","downloadURL":"https://download.aorusgram.com/AorusGram.ipa","size":9999999999}
        ]}]}
        """)
        require(AorusUpdateManifestParser.newestRelease(in: oversized) == nil,
                "oversized IPA is rejected")

        print("AorusUpdateManifest tests: OK")
    }
}
