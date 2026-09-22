import Foundation

// The AorusAI timeline, in the app's language.
//
// The gateway used to send one Russian sentence per row and the client showed it. That was
// fine while the client was Russian and wrong the moment it was not: a German build reading
// "Анализирую 75 сообщений…" in the middle of its own interface. So the gateway now sends a
// stable key and the parameters that go in it, and keeps the Russian sentence as a fallback.
//
// The rule from the contract, in order:
//
//   1. an unknown key shows the server's own sentence — never a blank row, which is what
//      would happen if a new server string had to wait for a client release;
//   2. a known key is written here, in every language the app speaks, through the same
//      table as the rest of the interface;
//   3. the parameters keep the sentence specific. "Профиль @monk получен", not
//      "Analyzing…" — collapsing to something generic loses the only part worth reading.
//
// The chat text the model writes still follows the person's own language and is not touched
// by any of this; only the chrome around it follows the app locale.

/// One timeline row: the key wins, the server's sentence is the fallback.
public func aorusAITimelineText(key: String?, params: [String: String], fallback: String) -> String {
    if let key = key, let localized = aorusAITimelineTemplate(key) {
        return aorusAITimelineFill(localized, params)
    }
    return fallback
}

/// `{name}` replaced by the parameter of that name. A placeholder with no parameter is left
/// as it is rather than becoming an empty gap, so a mismatch between client and gateway
/// reads as a missing value instead of a broken sentence.
func aorusAITimelineFill(_ template: String, _ params: [String: String]) -> String {
    guard template.contains("{") else { return template }
    var result = template
    for (name, value) in params {
        result = result.replacingOccurrences(of: "{\(name)}", with: value)
    }
    return result
}

/// Every key the contract defines. A key that is not here falls back to the gateway's own
/// sentence, which is why this list can grow one release behind the server without anything
/// going blank.
func aorusAITimelineTemplate(_ key: String) -> String? {
    switch key {
    case "status.thinking.request":
        return aorusL("Анализирую запрос…", "Analyzing the request…")
    case "status.thinking.message":
        return aorusL("Анализирую сообщение…", "Analyzing the message…")
    case "status.thinking.history":
        return aorusL("Анализирую {count} сообщений…", "Analyzing {count} messages…")
    case "status.tool.profile.looking":
        return aorusL("Смотрю профиль @{username}…", "Looking at @{username}'s profile…")
    case "status.permission.needed":
        return aorusL("Нужен дополнительный контекст", "More context is needed")
    case "status.responding":
        return aorusL("Формирую ответ…", "Writing the answer…")
    case "status.done":
        return aorusL("Готово", "Done")

    case "reasoning.profile.prefetch":
        return aorusL(
            "Для ответа полезно сначала посмотреть доступные данные профиля.",
            "It helps to look at the available profile data first."
        )
    case "reasoning.history":
        return aorusL(
            "Сопоставляю профиль и {count} доступных сообщений. Выводы ограничиваю этой выборкой.",
            "Comparing the profile against {count} available messages. Conclusions stay within that sample."
        )
    case "reasoning.context":
        return aorusL(
            "Учитываю выбранное сообщение, его отправителя и контекст чата.",
            "Taking the selected message, its sender and the chat context into account."
        )
    case "reasoning.restore.previous":
        return aorusL("Восстанавливаю предыдущую версию…", "Restoring the previous version…")
    case "reasoning.restore.slide":
        return aorusL("Восстанавливаю слайд {slide} из истории…", "Restoring slide {slide} from history…")
    case "reasoning.artifact.edit.pptx":
        return aorusL(
            "Анализирую текущую презентацию и вношу точечные изменения…",
            "Reading the current presentation and making targeted changes…"
        )
    case "reasoning.artifact.edit.file":
        return aorusL(
            "Анализирую текущий файл и вношу изменения…",
            "Reading the current file and making changes…"
        )
    case "reasoning.artifact.new.pptx":
        return aorusL("Проектирую структуру презентации…", "Designing the structure of the presentation…")
    case "reasoning.artifact.new.file":
        return aorusL("Подготавливаю структуру файла…", "Preparing the structure of the file…")
    case "reasoning.android.design":
        return aorusL("Проектирую структуру приложения…", "Designing the structure of the app…")

    case "tool.profile.name":
        return aorusL("Профиль @{username}", "@{username}'s profile")
    case "tool.profile.ready":
        return aorusL("Профиль @{username} получен", "Profile @{username} received")

    case "permission.history.title":
        return aorusL("Посмотреть переписку с @{username}?", "Look at the conversation with @{username}?")
    case "permission.history.description":
        return aorusL(
            "AorusAI получит только выбранный тобой объём сообщений для этого запроса.",
            "AorusAI receives only the number of messages you choose, for this request."
        )
    case "permission.opt.20":
        return aorusL("20 сообщений", "20 messages")
    case "permission.opt.50":
        return aorusL("50 сообщений", "50 messages")
    case "permission.opt.100":
        return aorusL("100 сообщений", "100 messages")
    case "permission.opt.period":
        return aorusL("Выбрать период", "Choose a period")

    case "render.restore.file":
        return aorusL("Восстанавливаю файл…", "Restoring the file…")
    case "render.restore.slides":
        return aorusL("Восстанавливаю слайды…", "Restoring the slides…")
    case "render.edit.slides":
        return aorusL("Изменяю слайды…", "Changing the slides…")
    case "render.edit.file":
        return aorusL("Изменяю файл…", "Changing the file…")
    case "render.create.slides":
        return aorusL("Создаю слайды…", "Creating the slides…")
    case "render.create.file":
        return aorusL("Создаю файл…", "Creating the file…")

    case "build.repair":
        return aorusL("Исправляю ошибки сборки…", "Fixing the build errors…")
    case "build.run":
        return aorusL("Сборка приложения…", "Building the app…")
    case "build.retry":
        return aorusL("Повторная сборка…", "Building again…")
    case "build.finalize.apk":
        return aorusL("Подготавливаю APK…", "Preparing the APK…")
    case "build.finalize.aab":
        return aorusL("Подготавливаю AAB…", "Preparing the AAB…")
    case "build.diagnose":
        return aorusL("Анализирую ошибки сборки…", "Reading the build errors…")

    default:
        return nil
    }
}

/// Every key this build knows, for the test that checks the catalog against the contract.
public let aorusAITimelineKeys: [String] = [
    "status.thinking.request", "status.thinking.message", "status.thinking.history",
    "status.tool.profile.looking", "status.permission.needed", "status.responding", "status.done",
    "reasoning.profile.prefetch", "reasoning.history", "reasoning.context",
    "reasoning.restore.previous", "reasoning.restore.slide",
    "reasoning.artifact.edit.pptx", "reasoning.artifact.edit.file",
    "reasoning.artifact.new.pptx", "reasoning.artifact.new.file", "reasoning.android.design",
    "tool.profile.name", "tool.profile.ready",
    "permission.history.title", "permission.history.description",
    "permission.opt.20", "permission.opt.50", "permission.opt.100", "permission.opt.period",
    "render.restore.file", "render.restore.slides", "render.edit.slides", "render.edit.file",
    "render.create.slides", "render.create.file",
    "build.repair", "build.run", "build.retry", "build.finalize.apk", "build.finalize.aab",
    "build.diagnose",
]
