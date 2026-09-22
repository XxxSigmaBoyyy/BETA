import Foundation

// The timeline i18n contract, both halves: what the client takes out of an event, and what
// it writes in place of it.
//
// The rule that matters most is the fallback. A gateway that ships a new key before the app
// knows it must not leave a blank row — the row is what someone is reading to find out what
// the assistant is doing — so an unknown key shows the sentence the gateway sent.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

/// Stands in for the app's translation table. The real one picks a language; here English is
/// enough, because what is being checked is which template is chosen and how it is filled.
func aorusL(_ ru: String, _ en: String) -> String {
    return en
}

@main
enum AorusAITimelineTests {
static func main() {
// Parameters are numbers and strings and nothing else. Anything without a sensible one-line
// rendering is dropped rather than interpolated into a sentence someone reads.
let params = AorusAITimelineText.parameters([
    "count": NSNumber(value: 75),
    "username": "monk",
    "ratio": NSNumber(value: 0.5),
    "flag": NSNumber(value: true),
    "nested": ["a": 1],
    "list": [1, 2, 3],
])
expect(params["count"] == "75", "an integer parameter keeps its exact value")
expect(params["username"] == "monk", "a string parameter arrives as it is")
expect(params["ratio"] == "0.5", "a fractional parameter is not truncated to an integer")
expect(params["flag"] == "1", "a boolean parameter renders as a digit rather than as a word")
expect(params["nested"] == nil, "an object parameter is dropped rather than described")
expect(params["list"] == nil, "an array parameter is dropped rather than described")

// The key and the gateway's own sentence come out of one body.
let status = AorusAITimelineText.from(
    ["key": "status.thinking.history", "params": ["count": NSNumber(value: 75)], "label": "Анализирую 75 сообщений…"],
    textFields: ["label"]
)
expect(status?.key == "status.thinking.history", "the key is read")
expect(status?.params["count"] == "75", "the parameters are read")
expect(status?.text == "Анализирую 75 сообщений…", "the gateway's own sentence is kept as the fallback")

// An event with neither is not a row at all.
expect(AorusAITimelineText.from(["label": ""], textFields: ["label"]) == nil, "an empty event is not a timeline row")
expect(AorusAITimelineText.from([:], textFields: ["label", "summary"]) == nil, "an event with no text and no key is dropped")

// `summary` and `label` are the same field under different names, so the first one present
// is used rather than each event body needing its own reader.
let summary = AorusAITimelineText.from(
    ["key": "reasoning.history", "params": ["count": NSNumber(value: 12)], "summary": "…"],
    textFields: ["summary"]
)
expect(summary?.key == "reasoning.history", "a reasoning summary carries a key like any other row")

// A key longer than the field allows is not a key. It is dropped and the sentence shows.
let absurd = AorusAITimelineText.from(
    ["key": String(repeating: "k", count: 200), "label": "fallback"],
    textFields: ["label"]
)
expect(absurd?.key == nil, "an absurdly long key is refused")
expect(absurd?.text == "fallback", "and the sentence is shown instead")

// ---- rendering ----------------------------------------------------------------------

expect(
    aorusAITimelineText(key: "status.thinking.history", params: ["count": "75"], fallback: "нет") == "Analyzing 75 messages…",
    "a known key is localized with its parameter filled in"
)
expect(
    aorusAITimelineText(key: "tool.profile.ready", params: ["username": "monk"], fallback: "нет") == "Profile @monk received",
    "the sentence stays specific rather than collapsing to something generic"
)
expect(
    aorusAITimelineText(key: "status.done", params: [:], fallback: "нет") == "Done",
    "a key with no parameters needs none"
)
// The whole point of the fallback.
expect(
    aorusAITimelineText(key: "status.invented.tomorrow", params: [:], fallback: "Сервер сказал так") == "Сервер сказал так",
    "a key this build does not know shows the gateway's own sentence"
)
expect(
    aorusAITimelineText(key: nil, params: [:], fallback: "Сервер сказал так") == "Сервер сказал так",
    "an event with no key at all shows the gateway's own sentence"
)
// A placeholder with no parameter stays visible rather than leaving a hole, so a mismatch
// reads as a missing value instead of a broken sentence.
expect(
    aorusAITimelineText(key: "status.thinking.history", params: [:], fallback: "нет") == "Analyzing {count} messages…",
    "a placeholder with nothing to put in it is left in place"
)

// Every key the contract lists has a template, and every template that takes a parameter
// says so with a placeholder. A key in the list with no template would silently fall back
// forever; a template with a placeholder nobody fills would show braces to a person.
for key in aorusAITimelineKeys {
    expect(aorusAITimelineTemplate(key) != nil, "key \(key) has no template")
}
let parameterised: [String: String] = [
    "status.thinking.history": "count",
    "status.tool.profile.looking": "username",
    "reasoning.history": "count",
    "reasoning.restore.slide": "slide",
    "tool.profile.name": "username",
    "tool.profile.ready": "username",
    "permission.history.title": "username",
]
for (key, name) in parameterised {
    let template = aorusAITimelineTemplate(key) ?? ""
    expect(template.contains("{\(name)}"), "key \(key) must interpolate {\(name)}")
}
for key in aorusAITimelineKeys where parameterised[key] == nil {
    let template = aorusAITimelineTemplate(key) ?? ""
    expect(!template.contains("{"), "key \(key) carries a placeholder nothing fills")
}

if failures == 0 {
    print("AorusAI timeline tests: OK")
} else {
    exit(1)
}
}
}
