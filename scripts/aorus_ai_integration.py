#!/usr/bin/env python3
from pathlib import Path
import sys


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
            "\n" + indent + "items[.aorusGram]!.append(PeerInfoScreenDisclosureItem(id: 1, text: aorusAILocalized(\"ИИ-компаньон\", \"AI Companion\"), icon: {\n"
            + indent + "    let size = CGSize(width: 30.0, height: 30.0)\n"
            + indent + "    let format = UIGraphicsImageRendererFormat()\n"
            + indent + "    format.scale = UIScreen.main.scale\n"
            + indent + "    format.opaque = false\n"
            + indent + "    return UIGraphicsImageRenderer(size: size, format: format).image { _ in\n"
            + indent + "        UIColor.systemBlue.setFill()\n"
            + indent + "        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7.0).fill()\n"
            + indent + "        let symbol = UIImage(systemName: \"sparkles\", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold))?.withTintColor(.white, renderingMode: .alwaysOriginal)\n"
            + indent + "        symbol?.draw(in: CGRect(x: 7.0, y: 7.0, width: 16.0, height: 16.0))\n"
            + indent + "    }.withRenderingMode(.alwaysOriginal)\n"
            + indent + "}(), action: {\n"
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
    sentinel = "// AorusGram: AorusAI message action v2"
    if sentinel in value:
        return
    if "import AorusGramUI\n" not in value:
        value = replace_once(value, "import AccountContext\n", "import AccountContext\nimport AorusGramUI\n", "AorusGramUI import")

    anchor = "        if !isReplyThreadHead, (!data.messageActions.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty || clearCacheAsDelete) {"

    # A tree patched by an earlier revision of this integrator carries a single flat
    # action instead of the nested menu. Drop that block first so repeated runs
    # converge on the current source rather than emitting both variants.
    legacy_sentinel = "        // AorusGram: AorusAI message action v1\n"
    legacy_index = value.find(legacy_sentinel)
    if legacy_index >= 0:
        anchor_index = value.find(anchor, legacy_index)
        if anchor_index < 0:
            raise RuntimeError("AorusAI: legacy message action block end not found")
        value = value[:legacy_index] + value[anchor_index:]

    # §10: the top row only opens a nested native menu; every AI action lives one
    # level down, grouped with separators, with Telegram's own Back row on top.
    # The menu contents come from AorusGramUI so that ContextUI stays out of it.
    block = (
        "        " + sentinel + "\n"
        "        if messages.count == 1, !messages[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n"
        "            let aorusAIMessage = messages[0]\n"
        "            let aorusAIPresentationData = context.sharedContext.currentPresentationData.with { $0 }\n"
        "            let aorusAIRun: (String) -> Void = { [weak controllerInteraction] entryId in\n"
        "                aorusAIRunMessageMenuAction(\n"
        "                    id: entryId,\n"
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
        "                return UIImage(systemName: \"sparkles\")?.withTintColor(theme.actionSheet.primaryTextColor, renderingMode: .alwaysOriginal)\n"
        "            }, action: { c, _ in\n"
        "                var aorusAIItems: [ContextMenuItem] = []\n"
        "                aorusAIItems.append(.action(ContextMenuActionItem(text: aorusAIPresentationData.strings.Common_Back, icon: { theme in\n"
        "                    return generateTintedImage(image: UIImage(bundleImageName: \"Chat/Context Menu/Back\"), color: theme.actionSheet.primaryTextColor)\n"
        "                }, iconPosition: .left, action: { c, _ in\n"
        "                    c?.popItems()\n"
        "                })))\n"
        "                aorusAIItems.append(.separator)\n"
        "                let aorusAISections = aorusAIMessageMenuSections()\n"
        "                for aorusAISectionIndex in aorusAISections.indices {\n"
        "                    if aorusAISectionIndex != 0 {\n"
        "                        aorusAIItems.append(.separator)\n"
        "                    }\n"
        "                    for aorusAIEntry in aorusAISections[aorusAISectionIndex].entries {\n"
        "                        let aorusAIEntryId = aorusAIEntry.id\n"
        "                        aorusAIItems.append(.action(ContextMenuActionItem(text: aorusAIEntry.title, icon: { _ in\n"
        "                            return nil\n"
        "                        }, action: { c, _ in\n"
        "                            c?.dismiss(completion: {\n"
        "                                aorusAIRun(aorusAIEntryId)\n"
        "                            })\n"
        "                        })))\n"
        "                    }\n"
        "                }\n"
        "                c?.pushItems(items: .single(ContextController.Items(content: .list(aorusAIItems))))\n"
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
