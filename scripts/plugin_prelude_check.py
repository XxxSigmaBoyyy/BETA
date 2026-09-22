#!/usr/bin/env python3
"""Run the plugin prelude the way the app does, before CI has to.

`AorusPluginPrelude.source` is JavaScript written inside a Swift string, which means a
mistake in it is invisible to every Swift check: the file compiles, the tests build, and
then every single plugin fails to start because the prelude threw while it was being
evaluated. Run 490 through 494 died exactly that way — forty test assertions failing at
once, all of them "plugin starts", because none of them could.

There is no JavaScriptCore here, but there is Node. The prelude only needs a `__aorusHost`
to run against, so this builds one out of stubs, evaluates the prelude, and then asks the
result the questions the API promises: that `aorus` exists, that it is frozen, that every
namespace the permission scanner names is really published, and that `__aorusHost` is gone
by the end.

Usage: plugin_prelude_check.py <repo root>
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

PRELUDE = "AorusGram/Sources/Features/Plugins/AorusPluginPrelude.swift"


def swift_string(text: str) -> str:
    """The Swift multiline literal, as the characters JavaScriptCore would see.

    Interpolations are substituted first, because `\\(` is not an escape and would otherwise
    be read as one.
    """
    out: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char != "\\":
            out.append(char)
            index += 1
            continue
        if index + 1 >= length:
            out.append(char)
            break
        following = text[index + 1]
        mapping = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
        if following in mapping:
            out.append(mapping[following])
            index += 2
            continue
        # An escape Swift does not define is left alone: `\d` inside a regular expression is
        # one of those, and eating the backslash would quietly change the pattern.
        out.append(char)
        out.append(following)
        index += 2
    return "".join(out)


def extract(root: Path) -> tuple[str, list[str], str]:
    source = (root / PRELUDE).read_text(encoding="utf-8")

    events = re.search(r'public static let events: \[String\] = \[(.*?)\n    \]', source, re.S)
    if not events:
        raise SystemExit("prelude: could not find the events list")
    names = re.findall(r'"([^"]+)"', events.group(1))

    version = re.search(r'public static let apiVersion = "([^"]+)"', source)
    if not version:
        raise SystemExit("prelude: could not find apiVersion")

    body = re.search(r'public static let source: String = """\n(.*?)\n    """\n', source, re.S)
    if not body:
        raise SystemExit("prelude: could not find the source literal")
    text = body.group(1)

    # The two interpolations the literal actually uses.
    text = text.replace(
        r'\(events.map { "'"'"'\($0)'"'"'" }.joined(separator: ", "))',
        ", ".join("'%s'" % name for name in names),
    )
    text = text.replace(r"\(apiVersion)", version.group(1))
    if "\\(" in text:
        remaining = sorted(set(re.findall(r"\\\([^)]*\)", text)))
        raise SystemExit("prelude: unhandled interpolation(s): " + ", ".join(remaining))
    return swift_string(text), names, version.group(1)


HARNESS = r"""
// A host that answers every block the prelude installs, the way the real one does.
//
// The shapes matter. `overlaysDefine` answers how many it accepted, not whether it accepted
// anything, and the prelude compares that against what it sent — a stub that returned `true`
// would make every add throw and prove nothing. `request` settles through the dispatcher,
// which is how the real boundary works, so the asynchronous half of the API can be exercised
// here too.
// Taken before the prelude runs, because the prelude publishes its own frozen `console` as
// a global. Reporting through that one sends the verdict into the plugin's log instead of to
// this process, which is how a check can pass while testing nothing.
const nodeLog = console.error.bind(console);
globalThis.__nodeLog = nodeLog;

const calls = [];
const storageValues = {};
globalThis.__calls = calls;
globalThis.__answers = {};
globalThis.__requestFailures = {};
globalThis.__defineVerdict = {};

function record(name, args) { calls.push({ name: name, args: args }); }

const host = new Proxy({}, {
    get(target, name) {
        if (typeof name !== 'string') { return undefined; }
        switch (name) {
        case 'pluginInfo': return () => ({ id: 'test', name: 'Test', version: '1.0.0', author: '' });
        case 'deviceInfo': return () => ({ language: 'en', systemVersion: '18.0', appVersion: '1', isDark: false });
        case 'language': return () => 'en';
        case 'settingsInitial': return () => '{}';
        case 'storageInitial': return () => JSON.stringify(storageValues);
        case 'logHistory': return () => '[]';
        case 'grantedPermissions': return () => ['sendMessages'];
        case 'hasPermission': return (value) => value === 'sendMessages';
        case 'registerDispatcher': return (value) => { globalThis.__dispatcher = value; };
        case 'crypto': return () => '';
        case 'log': return (level, text) => record('log', [level, text]);
        case 'storageWrite': return (key, json) => {
            record('storageWrite', [key, json]);
            if (json === null) { delete storageValues[key]; } else { storageValues[key] = JSON.parse(json); }
            return true;
        };
        case 'overlaysDefine':
        case 'nativeButtonsDefine': return (json) => {
            record(name, [json]);
            if (globalThis.__defineVerdict[name] !== undefined) { return globalThis.__defineVerdict[name]; }
            return JSON.parse(json).length;
        };
        case 'request': return (kind, json, id) => {
            record('request', [kind, JSON.parse(json)]);
            const dispatcher = globalThis.__dispatcher;
            if (globalThis.__requestFailures[kind]) {
                dispatcher.reject(id, globalThis.__requestFailures[kind]);
                return;
            }
            // A shape that does not crash a plugin written against the real thing. The
            // point of running these sources is to catch what throws on the way in, not to
            // model every host answer.
            let answer = null;
            if (Object.prototype.hasOwnProperty.call(globalThis.__answers, kind)) {
                answer = globalThis.__answers[kind];
            } else if (/\.(list|search|messages|history|accounts)$/.test(kind)) {
                answer = [];
            } else if (kind !== 'chat.current' && kind !== 'users.pick' && kind !== 'files.info') {
                answer = {};
            }
            dispatcher.resolve(id, JSON.stringify(answer));
        };
        case 'timerSchedule': return (id, ms, repeats) => {
            record('timerSchedule', [id, ms, repeats]);
            setTimeout(() => {
                const dispatcher = globalThis.__dispatcher;
                if (dispatcher) { dispatcher.timerFire(id); }
            }, 0);
        };
        }
        return (...args) => { record(name, args); return true; };
    }
});
globalThis.__aorusHost = host;
"""

CHECKS = r"""
const problems = [];
if (typeof aorus !== 'object' || aorus === null) { problems.push('aorus was not published'); }
if (!Object.isFrozen(aorus)) { problems.push('aorus is not frozen'); }
if (typeof globalThis.__aorusHost !== 'undefined') { problems.push('__aorusHost survived the prelude'); }
if (typeof console.log !== 'function') { problems.push('console was not published'); }
if (typeof globalThis.__dispatcher !== 'object') { problems.push('no dispatcher was registered'); }
for (const name of EXPECTED_NAMESPACES) {
    if (typeof aorus[name] === 'undefined') { problems.push('aorus.' + name + ' is missing'); }
}
for (const event of EXPECTED_EVENTS) {
    try {
        aorus.on(event, function () {});
    } catch (error) {
        problems.push('aorus.on(' + event + ') threw: ' + error.message);
    }
}
try {
    aorus.on('somethingNobodyDeclared', function () {});
    problems.push('aorus.on accepted an event that is not declared');
} catch (error) { /* expected */ }

// ---- behaviour ----------------------------------------------------------------------
//
// The same things the Swift tests assert, asked of the JavaScript directly. A logic mistake
// here is one nobody finds until forty assertions fail at once in CI.

function check(name, condition) { if (!condition) { problems.push(name); } }
function throws(name, body) {
    try { body(); problems.push(name); } catch (error) { /* expected */ }
}
function lastRequest(kind) {
    for (let i = globalThis.__calls.length - 1; i >= 0; i--) {
        const call = globalThis.__calls[i];
        if (call.name === 'request' && call.args[0] === kind) { return call.args[1]; }
    }
    return null;
}

// Storage, including the wrong-type recovery.
aorus.storage.setJSON('state', { count: 3 });
check('storage.getJSON does not round-trip', aorus.storage.getJSON('state').count === 3);
check('storage.getJSON ignores its fallback', aorus.storage.getJSON('missing', 'x') === 'x');
check('storage.has is wrong', aorus.storage.has('state') && !aorus.storage.has('missing'));
check('storage.push does not answer the new length', aorus.storage.push('items', 'a') === 1);
aorus.storage.set('scalar', 7);
check('push onto a non-array does not start a new one', aorus.storage.push('scalar', 'a') === 1);

// Arguments refused in JavaScript, before anything crosses.
throws('chat.scrollTo accepted something that is not a message', () => aorus.chat.scrollTo('abc'));
throws('chat.messages accepted a limit out of range', () => aorus.chat.messages({ limit: 500 }));
throws('chat.setTyping accepted a non-boolean', () => aorus.chat.setTyping('yes'));
throws('moderation accepted no group', () => aorus.moderation.ban('42'));
throws('users.search accepted a bad limit', () => aorus.users.search('ab', { limit: 0 }));
throws('files.writeText accepted a non-string', () => aorus.files.writeText('a.txt', 5));
throws('navigation.openProfile accepted me', () => aorus.navigation.openProfile('me'));

// What a call actually sends.
aorus.chat.setDraft('hello');
check('chat.setDraft sends the wrong mode', (lastRequest('chat.setDraft') || {}).mode === 'set');
aorus.chat.insert('more');
check('chat.insert sends the wrong mode', (lastRequest('chat.setDraft') || {}).mode === 'insert');
aorus.chat.clear();
check('chat.clear sends the wrong mode', (lastRequest('chat.setDraft') || {}).mode === 'clear');
aorus.messages.deleteLocal({ peerId: '-100123', namespace: 0, messageId: 5 });
check('messages.deleteLocal sends the wrong reference', (lastRequest('messages.deleteLocal') || {}).messageId === 5);
aorus.theme.resetAccentColor();
check('theme.resetAccentColor does not clear the colour', lastRequest('theme.setAccent').color === null);
aorus.proxy.startAutoSwitch();
check('proxy.startAutoSwitch does not enable', lastRequest('proxy.autoSwitch').enabled === true);

// Overlays and native buttons answer with an id, and refuse rather than inventing one.
const overlayId = aorus.ui.addFloatingButton({ title: 'Go', icon: 'bolt.fill' }, function () {});
check('addFloatingButton did not answer an id', typeof overlayId === 'string' && overlayId.length > 0);
check('the overlay was not published', aorus.ui.overlays().length === 1);
globalThis.__defineVerdict.overlaysDefine = -1;
throws('an ungranted overlay add did not throw', () => aorus.ui.addFloatingButton({ title: 'No' }));
check('a refused add left the overlay behind', aorus.ui.overlays().length === 1);
globalThis.__defineVerdict.overlaysDefine = undefined;
check('removeFloatingButton did not remove', aorus.ui.removeFloatingButton(overlayId) === true);
check('the overlay survived its removal', aorus.ui.overlays().length === 0);

const buttonId = aorus.ui.addChatListHeaderButton({ title: 'TON' }, function () {});
check('addChatListHeaderButton did not answer an id', typeof buttonId === 'string');
globalThis.__defineVerdict.nativeButtonsDefine = -1;
throws('an ungranted button add did not throw', () => aorus.ui.addChatListHeaderButton({ title: 'No' }));
globalThis.__defineVerdict.nativeButtonsDefine = undefined;

// Handlers given to `add` are called directly, so a plugin with several does not have to
// work out which one fired.
let pressedOverlay = null;
const secondOverlay = aorus.ui.addFloatingButton({ title: 'Two' }, function (event) { pressedOverlay = event.id; });
globalThis.__dispatcher.dispatch('overlayAction', { id: secondOverlay });
check('an overlay handler was not called', pressedOverlay === secondOverlay);
let pressedButton = null;
aorus.plugins.on('topic', function (event) { pressedButton = event.from; });
globalThis.__dispatcher.dispatch('pluginMessage', { topic: 'topic', from: 'other', payload: {} });
check('a plugin message did not reach its topic', pressedButton === 'other');
globalThis.__dispatcher.dispatch('pluginMessage', { topic: 'unrelated', from: 'x', payload: {} });
check('a plugin message reached the wrong topic', pressedButton === 'other');

// Strings republish the whole set, and restoring answers how many went back.
aorus.strings.override('A', 'one');
aorus.strings.override('B', 'two');
check('strings.restore did not remove the key', aorus.strings.restore('B') === true);
check('strings.all is wrong after a restore', Object.keys(aorus.strings.all()).join(',') === 'A');
check('strings.restoreAll did not count', aorus.strings.restoreAll() === 1);

// Formatted text: the offsets are counted in UTF-16 units, which is the part that is easy to
// get wrong and impossible to see.
const composed = aorus.text.compose(['\u{1F48E} ', aorus.text.bold('bold')]);
check('compose joined the parts wrongly', composed.text === '\u{1F48E} bold');
check('compose counted an emoji as one unit', composed.entities[0].offset === 3);
check('compose measured the run wrongly', composed.entities[0].length === 4);

// The runtime answers about itself.
check('runtime.pluginId is missing', aorus.runtime.pluginId === 'test');
check('runtime.hasPermission is wrong', aorus.runtime.hasPermission('sendMessages') === true);
check('runtime.hasPermission invents a grant', aorus.runtime.hasPermission('network') === false);

// A promise that settles, through the dispatcher, the way the real boundary does.
globalThis.__answers['chat.current'] = { peerId: '5', title: 'Team', kind: 'group' };
aorus.chat.current().then(function (value) {
    check('a request did not resolve with what the host answered', value && value.title === 'Team');
    globalThis.__requestFailures['chat.draft'] = 'No chat is open';
    return aorus.chat.draft().then(
        function () { problems.push('a rejected request resolved'); },
        function (error) {
            check('a rejection lost its message', String(error.message) === 'No chat is open');
        }
    );
}).then(function () {
VERDICT_TAIL
    globalThis.__nodeLog('VERDICT ' + JSON.stringify(problems));
}, function (error) {
    problems.push('the behaviour checks threw: ' + error.message);
    globalThis.__nodeLog('VERDICT ' + JSON.stringify(problems));
});
"""


TESTS = "scripts/tests/AorusPluginCoreTests.swift"


def plugin_sources(root: Path) -> list[str]:
    """Every plugin the Swift tests run, as JavaScript.

    The two failures the first version of this check missed were both in test sources it
    never executed: `aorus.console.history(...)` on a namespace that had no `console`, and
    `.sort()` on a frozen array. Reading the same sources the tests use closes that: what CI
    runs is what runs here.
    """
    text = (root / TESTS).read_text(encoding="utf-8")
    sources: list[str] = []
    # `source: """ ... """` and the inline single-line form both appear.
    for match in re.finditer(r'"""\n(.*?)\n\s*"""', text, re.S):
        body = match.group(1)
        if "aorus." not in body:
            continue
        sources.append(textwrap.dedent(body))
    for match in re.finditer(r'source: "((?:[^"\\]|\\.)*)"', text):
        body = match.group(1)
        if "aorus." not in body:
            continue
        sources.append(body.replace('\\"', '"').replace("\\\\", "\\"))
    return sources


RUN_SOURCES = r"""
// Each plugin the Swift tests run, evaluated the way the sandbox evaluates it. A source that
// throws here is a plugin that would fail to start there.
//
// Only what throws on the way in is reported. A promise that rejects because this harness
// answered a host call with a shape the plugin did not expect says nothing about the plugin;
// the sandbox hands those to the plugin's own error handler and carries on, so this does too.
const sourceProblems = [];
process.on('unhandledRejection', function () {});
for (let index = 0; index < PLUGIN_SOURCES.length; index++) {
    // A handler that throws does not reach here: the prelude catches it and writes an error
    // to the plugin's log, exactly as the sandbox does. That log line is the signal — in the
    // app it is the difference between a plugin that ran and one whose start handler died
    // halfway through with nothing on screen to say so.
    const before = globalThis.__calls.length;
    try {
        (0, eval)(PLUGIN_SOURCES[index]);
        if (globalThis.__dispatcher) { globalThis.__dispatcher.dispatch('start'); }
    } catch (error) {
        sourceProblems.push('test plugin ' + (index + 1) + ' threw: ' + error.message);
        continue;
    }
    for (let i = before; i < globalThis.__calls.length; i++) {
        const call = globalThis.__calls[i];
        if (call.name === 'log' && call.args[0] === 'error') {
            sourceProblems.push('test plugin ' + (index + 1) + ' logged an error: ' + call.args[1]);
        }
    }
}
for (const problem of sourceProblems) { problems.push(problem); }
"""


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    prelude, events, version = extract(root)

    # Every namespace the permission scanner names has to exist, or a plugin asking for that
    # capability is granted something it can never call.
    model = (root / "AorusGram/Sources/Features/Plugins/AorusPluginModel.swift").read_text(encoding="utf-8")
    block = model[model.index("sourceProbes"):model.index("public static func requestedBySource")]
    namespaces = sorted({
        needle.split(".")[1]
        for needle in re.findall(r'"(aorus\.[^"]*)"', block)
        if not needle.startswith("aorus.on(") and not needle.startswith("aorus.once(")
        and len(needle.split(".")) > 1
    })

    sources = plugin_sources(root)
    if not sources:
        print("Plugin prelude check FAILED: no plugin sources found in the tests")
        return 1
    script = "\n".join([
        HARNESS,
        "const EXPECTED_NAMESPACES = " + json.dumps(namespaces) + ";",
        "const EXPECTED_EVENTS = " + json.dumps(events) + ";",
        "const PLUGIN_SOURCES = " + json.dumps(sources) + ";",
        prelude,
        CHECKS.replace("VERDICT_TAIL", RUN_SOURCES),
    ])
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "prelude-check.js"
        path.write_text(script, encoding="utf-8")
        result = subprocess.run(
            ["node", str(path)], capture_output=True, text=True, timeout=120
        )
    if result.returncode != 0:
        print("Plugin prelude check FAILED: the prelude did not run")
        for line in (result.stderr or result.stdout).strip().split("\n")[:25]:
            print("  " + line)
        return 1
    verdict = [
        line for line in (result.stderr or "").strip().split("\n") if line.startswith("VERDICT ")
    ]
    if not verdict:
        # An absent verdict used to read as an empty one, which is a check that passes by
        # testing nothing. It is a failure.
        print("Plugin prelude check FAILED: the harness never reported")
        print("  " + ((result.stderr or result.stdout).strip()[:2000] or "(no output at all)"))
        return 1
    try:
        problems = json.loads(verdict[-1][len("VERDICT "):])
    except json.JSONDecodeError:
        print("Plugin prelude check FAILED: the verdict could not be read")
        print("  " + verdict[-1][:2000])
        return 1
    if problems:
        print("Plugin prelude check FAILED:")
        for problem in problems:
            print("  " + problem)
        return 1
    print(
        "Plugin prelude check: OK (api %s, %d events, %d namespaces)"
        % (version, len(events), len(namespaces))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
