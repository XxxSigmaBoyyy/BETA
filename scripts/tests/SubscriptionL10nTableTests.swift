import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("SubscriptionL10nTable test failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum SubscriptionL10nTableTests {
    static func main() {
        require(SubscriptionL10nTable.mandatoryUpdateEnglish.count == 13, "unexpected mandatory-update key count")
        for language in SubLanguage.allCases where language != .en && language != .ru {
            for english in SubscriptionL10nTable.mandatoryUpdateEnglish {
                guard let translated = SubscriptionL10nTable.mandatoryUpdateTranslation(of: english, into: language) else {
                    require(false, "missing \(language.rawValue) translation for \(english)")
                    continue
                }
                require(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty \(language.rawValue) translation")
                require(translated.components(separatedBy: "%@").count == english.components(separatedBy: "%@").count,
                        "\(language.rawValue) translation loses %@ for \(english)")
            }
        }
        require(SubscriptionL10nTable.mandatoryUpdateTranslation(of: "unknown", into: .de) == nil,
                "unknown key must not resolve")
        print("SubscriptionL10nTable tests: OK")
    }
}
