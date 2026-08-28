#!/usr/bin/env python3
from pathlib import Path
import re
import sys


# The settings row must be indistinguishable from every native one, so the icon is
# drawn by Telegram's own renderer (public in TelegramPresentationData, already
# imported by PeerInfoSettingsItems.swift): a 30x30 rounded square with the shared
# gradient, backdrop and white masked glyph. `Item List/Icons/AITools` is an asset
# that ships with the app, and the two-colour background follows the same form the
# `business` row uses, so the row reads as ours without looking foreign.
AI_ROW_ICON = (
    'icon: renderSettingsIcon(name: "Item List/Icons/AITools", '
    "backgroundColors: [UIColor(rgb: 0xA95CE3), UIColor(rgb: 0x5B7CFA)])"
)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"AorusAI: {label} anchor not found")
    return text.replace(old, new, 1)


def patch_settings(root: Path) -> None:
    base = root / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources"
    screen = base / "PeerInfoScreen.swift"
    actions = base / "PeerInfoScreenSettingsActions.swift"
    items = base / "PeerInfoSettingsItems.swift"
    for path in (screen, actions, items):
        if not path.is_file():
            raise RuntimeError(f"AorusAI: missing {path}")

    value = screen.read_text(encoding="utf-8")
    if "case aorusAI" not in value:
        value = replace_once(value, "    case aorusGram\n", "    case aorusGram\n    case aorusAI\n", "settings enum")
        screen.write_text(value, encoding="utf-8")

    value = actions.read_text(encoding="utf-8")
    if "import AorusGramUI\n" not in value:
        import_anchor = "import AccountContext\n"
        if import_anchor not in value:
            raise RuntimeError("AorusAI: settings action import anchor not found")
        value = value.replace(import_anchor, import_anchor + "import AorusGramUI\n", 1)
    if "case .aorusAI:" not in value:
        value = replace_once(
            value,
            "        case .faq:\n            self.openFaq()\n",
            "        case .aorusAI:\n            push(aorusAIConversationListController(context: self.context))\n        case .faq:\n            self.openFaq()\n",
            "settings action",
        )
    actions.write_text(value, encoding="utf-8")

    value = items.read_text(encoding="utf-8")
    if "import AorusGramUI\n" not in value:
        import_anchor = "import AccountContext\n"
        if import_anchor not in value:
            raise RuntimeError("AorusAI: settings item import anchor not found")
        value = value.replace(import_anchor, import_anchor + "import AorusGramUI\n", 1)
    # Upgrade installations produced by an earlier revision of this integrator.
    # Keeping migrations outside the sentinel branch makes repeated runs converge
    # to the current source instead of preserving stale generated UI forever.
    for legacy_label in (
        'context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode == "ru" ? "ИИ-компаньон" : "AI Companion"',
        'presentationData.strings.baseLanguageCode == "ru" ? "ИИ-компаньон" : "AI Companion"',
    ):
        value = value.replace(
            legacy_label,
            'aorusAILocalized("ИИ-компаньон", "AI Companion")',
        )
    # An earlier revision drew a flat systemBlue square with an SF Symbol on it, which
    # stood out next to every native row. Replace it with Telegram's own settings-icon
    # renderer so the row is indistinguishable in shape, gradient and glyph weight.
    value = re.sub(
        r'icon: \{\n(?:[^\n]*\n)*?[^\n]*UIColor\.systemBlue\.setFill\(\)\n(?:[^\n]*\n)*?[^\n]*\}\(\), action: \{',
        lambda _: AI_ROW_ICON + ", action: {",
        value,
    )
    sentinel = "interaction.openSettings(.aorusAI)"
    if sentinel not in value:
        aorus_marker = "interaction.openSettings(.aorusGram)"
        marker_index = value.find(aorus_marker)
        if marker_index < 0:
            raise RuntimeError("AorusAI: AorusGram settings row not found")
        item_start = value.rfind("items[.aorusGram]!.append(", 0, marker_index)
        if item_start < 0:
            raise RuntimeError("AorusAI: AorusGram settings item start not found")
        line_start = value.rfind("\n", 0, item_start) + 1
        indent = value[line_start:item_start]
        closing = "\n" + indent + "}))"
        closing_index = value.find(closing, marker_index)
        if closing_index < 0:
            raise RuntimeError("AorusAI: AorusGram settings item end not found")
        insertion_index = closing_index + len(closing)
        addition = (
            "\n" + indent + "items[.aorusGram]!.append(PeerInfoScreenDisclosureItem(id: 1, text: aorusAILocalized(\"ИИ-компаньон\", \"AI Companion\"), "
            + AI_ROW_ICON + ", action: {\n"
            + indent + "    interaction.openSettings(.aorusAI)\n"
            + indent + "}))"
        )
        value = value[:insertion_index] + addition + value[insertion_index:]
    items.write_text(value, encoding="utf-8")


def patch_context_menu(root: Path) -> None:
    path = root / "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
    if not path.is_file():
        raise RuntimeError(f"AorusAI: missing {path}")
    value = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: AorusAI message action v5"
    if sentinel in value:
        return
    if "import AorusGramUI\n" not in value:
        value = replace_once(value, "import AccountContext\n", "import AccountContext\nimport AorusGramUI\n", "AorusGramUI import")

    anchor = "        if !isReplyThreadHead, (!data.messageActions.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty || clearCacheAsDelete) {"

    # A tree patched by an earlier revision of this integrator carries a different
    # menu shape. Drop that block first so repeated runs converge on the current
    # source rather than emitting both variants.
    for legacy_sentinel in (
        "        // AorusGram: AorusAI message action v1\n",
        "        // AorusGram: AorusAI message action v2\n",
        "        // AorusGram: AorusAI message action v3\n",
        "        // AorusGram: AorusAI message action v4\n",
    ):
        legacy_index = value.find(legacy_sentinel)
        if legacy_index < 0:
            continue
        anchor_index = value.find(anchor, legacy_index)
        if anchor_index < 0:
            raise RuntimeError("AorusAI: legacy message action block end not found")
        value = value[:legacy_index] + value[anchor_index:]

    # §10: the AorusAI row opens the module's own bounded sheet, not another level of
    # Telegram's context menu.
    #
    # ContextControllerActionsStackNode only positions the top two containers of its
    # stack (`i == count - 1` and `i == count - 2`); anything deeper keeps
    # `transitionFraction = 0`, i.e. stays on screen at x = 0 behind a dim node whose
    # colour is `contextMenu.sectionSeparatorColor` — 20 % black in the dark theme. A
    # second pushed level therefore leaves the chat menu readable underneath. So the
    # twenty-two AorusAI actions once had to live in ONE pushed level, which is taller
    # than the screen: its rows ran out of the frame with nothing to scroll them.
    #
    # A sheet owned by AorusGramUI has none of those limits: its body scrolls, its
    # height is clamped to the screen, its four sections keep their headers, and a row
    # with options (translation language, tone) opens a nested level inside the sheet.
    # The generated code is therefore reduced to closing the menu and handing over the
    # message; the contents live in the module, out of TelegramUI.
    #
    # The row icon stays a native bundle image tinted through `generateTintedImage`,
    # like every other row in this file. SF Symbols went through
    # `withTintColor(_:renderingMode:)` before, which keeps the symbol's own (black)
    # rendering in a context menu.
    block = (
        "        " + sentinel + "\n"
        "        if messages.count == 1, !messages[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n"
        "            let aorusAIMessage = messages[0]\n"
        "            let aorusAIOpen: () -> Void = { [weak controllerInteraction] in\n"
        "                aorusAIPresentMessageActions(\n"
        "                    context: context,\n"
        "                    navigationController: controllerInteraction?.navigationController(),\n"
        "                    peerId: aorusAIMessage.id.peerId.toInt64(),\n"
        "                    messageNamespace: aorusAIMessage.id.namespace,\n"
        "                    messageId: aorusAIMessage.id.id,\n"
        "                    authorPeerId: aorusAIMessage.author?.id.toInt64(),\n"
        "                    text: aorusAIMessage.text\n"
        "                )\n"
        "            }\n"
        "            actions.append(.action(ContextMenuActionItem(text: aorusAIMessageMenuTitle(), icon: { theme in\n"
        "                return generateTintedImage(image: UIImage(bundleImageName: aorusAIMessageMenuIconName()), color: theme.actionSheet.primaryTextColor)\n"
        "            }, action: { c, _ in\n"
        "                c?.dismiss(completion: {\n"
        "                    aorusAIOpen()\n"
        "                })\n"
        "            })))\n"
        "            actions.append(.separator)\n"
        "        }\n"
    )
    value = replace_once(value, anchor, block + anchor, "message context menu")
    path.write_text(value, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: aorus_ai_integration.py <telegram-ios-root>")
    root = Path(sys.argv[1]).resolve()
    patch_settings(root)
    patch_context_menu(root)
    print("AorusAI: settings and message context menu integrated")


if __name__ == "__main__":
    main()
