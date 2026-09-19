import Foundation

// The JavaScript that runs in a plugin's context before the plugin itself.
//
// It is the whole of the boundary between a plugin and the app. The sandbox hands it one
// object, `__aorusHost`, whose members are Swift blocks; the prelude captures that object in
// a closure, builds the public `aorus` API on top of it, publishes `aorus`, `console` and the
// four timer functions as non-writable globals, freezes every object it published, and then
// deletes `__aorusHost` from the global scope. Once it has run, the only way from plugin code
// to the app is through the frozen API, and every call in that API is one of the host blocks
// with its arguments already coerced and checked.
//
// Nothing else is installed in the context: no Swift classes, no bridged objects. JavaScriptCore
// on its own has no file, network or process access, so the set of host blocks IS the set of
// things a plugin can do.
public enum AorusPluginPrelude {
    public static let apiVersion = "1.0"

    /// Events a plugin may subscribe to. Anything else is rejected at `aorus.on`.
    public static let events: [String] = [
        "start", "stop", "message", "send", "messageDeleted", "messageEdited",
        "foreground", "background", "settingsChanged", "uiAction", "contextAction",
    ]

    public static let source: String = """
    (function (host) {
        'use strict';

        var freeze = Object.freeze;
        var KNOWN_EVENTS = [\(events.map { "'\($0)'" }.joined(separator: ", "))];
        var MAX_TIMERS = 64;
        var MAX_LOG_CHARS = 4096;

        function typeError(message) { return new TypeError(message); }

        function requireString(value, name) {
            if (typeof value !== 'string') { throw typeError(name + ' must be a string'); }
            return value;
        }

        function requireFunction(value, name) {
            if (typeof value !== 'function') { throw typeError(name + ' must be a function'); }
            return value;
        }

        function optionalObject(value, name) {
            if (value === undefined || value === null) { return {}; }
            if (typeof value !== 'object') { throw typeError(name + ' must be an object'); }
            return value;
        }

        function toPeerId(value) {
            if (value === 'me') { return 'me'; }
            if (typeof value === 'number' && Number.isSafeInteger(value)) { return String(value); }
            if (typeof value === 'string' && /^-?\\d+$/.test(value)) { return value; }
            throw typeError('peerId must be a decimal string, a safe integer or \\'me\\'');
        }

        // What console.* prints for a value: JSON for objects, with cycles cut and the
        // whole thing capped so a runaway object cannot flood the log.
        function describe(value, depth, seen) {
            if (value === null) { return 'null'; }
            var type = typeof value;
            if (type === 'string') { return depth === 0 ? value : JSON.stringify(value); }
            if (type === 'number' || type === 'boolean' || type === 'undefined' || type === 'bigint' || type === 'symbol') { return String(value); }
            if (type === 'function') { return '[Function' + (value.name ? ' ' + value.name : '') + ']'; }
            if (value instanceof Error) { return (value.name || 'Error') + ': ' + value.message + (value.stack ? '\\n' + value.stack : ''); }
            if (value instanceof Date) { return value.toISOString(); }
            if (value instanceof RegExp) { return String(value); }
            if (depth > 6) { return '[Object]'; }
            if (seen.indexOf(value) !== -1) { return '[Circular]'; }
            seen.push(value);
            var out;
            if (Array.isArray(value)) {
                out = '[' + value.map(function (item) { return describe(item, depth + 1, seen); }).join(', ') + ']';
            } else if (value instanceof Map) {
                out = 'Map(' + value.size + ')';
            } else if (value instanceof Set) {
                out = 'Set(' + value.size + ')';
            } else {
                var parts = [];
                var keys = Object.keys(value);
                for (var i = 0; i < keys.length; i++) {
                    parts.push(keys[i] + ': ' + describe(value[keys[i]], depth + 1, seen));
                }
                out = '{' + parts.join(', ') + '}';
            }
            seen.pop();
            return out;
        }

        function formatArgs(args) {
            var pieces = [];
            for (var i = 0; i < args.length; i++) { pieces.push(describe(args[i], 0, [])); }
            var text = pieces.join(' ');
            if (text.length > MAX_LOG_CHARS) { text = text.slice(0, MAX_LOG_CHARS) + '…'; }
            return text;
        }

        function log(level, args) { host.log(level, formatArgs(args)); }

        function reportError(where, error) {
            var text = where + ': ' + describe(error, 0, []);
            if (error && typeof error === 'object' && typeof error.line === 'number') {
                text += ' (line ' + error.line + ')';
            }
            host.log('error', text);
        }

        var console = freeze({
            log: function () { log('info', arguments); },
            info: function () { log('info', arguments); },
            warn: function () { log('warn', arguments); },
            error: function () { log('error', arguments); },
            debug: function () { log('debug', arguments); }
        });

        // ---- events -------------------------------------------------------------------

        var handlers = {};
        for (var e = 0; e < KNOWN_EVENTS.length; e++) { handlers[KNOWN_EVENTS[e]] = []; }

        function notifyHooks() {
            host.hooksChanged(handlers.send.length > 0, commandOrder.length > 0);
        }

        function on(event, handler) {
            requireString(event, 'event');
            requireFunction(handler, 'handler');
            if (!handlers.hasOwnProperty(event)) { throw new Error('Unknown event: ' + event); }
            handlers[event].push(handler);
            if (event === 'send') { notifyHooks(); }
            return function () { off(event, handler); };
        }

        function off(event, handler) {
            requireString(event, 'event');
            if (!handlers.hasOwnProperty(event)) { return; }
            var list = handlers[event];
            for (var i = list.length - 1; i >= 0; i--) {
                if (list[i] === handler || list[i].__aorusOriginal === handler) { list.splice(i, 1); }
            }
            if (event === 'send') { notifyHooks(); }
        }

        function once(event, handler) {
            requireFunction(handler, 'handler');
            var wrapper = function () {
                off(event, wrapper);
                return handler.apply(undefined, arguments);
            };
            wrapper.__aorusOriginal = handler;
            return on(event, wrapper);
        }

        function emit(event, payload) {
            var list = handlers[event];
            if (!list) { return; }
            var snapshot = list.slice();
            for (var i = 0; i < snapshot.length; i++) {
                try {
                    var result = snapshot[i](payload);
                    if (result && typeof result.then === 'function') {
                        result.then(undefined, function (error) { reportError('Handler for \\'' + event + '\\' rejected', error); });
                    }
                } catch (error) {
                    reportError('Handler for \\'' + event + '\\' failed', error);
                }
            }
        }

        // ---- commands -----------------------------------------------------------------

        var prefix = '.';
        var commands = {};
        var commandOrder = [];

        function registerCommand(name, handler, options) {
            requireString(name, 'name');
            requireFunction(handler, 'handler');
            var opts = optionalObject(options, 'options');
            var key = name.trim().toLowerCase();
            if (!/^[a-z0-9_][a-z0-9_\\-]{0,31}$/.test(key)) {
                throw new Error('Command name may contain letters, digits, _ and -, up to 32 characters');
            }
            if (!commands.hasOwnProperty(key)) { commandOrder.push(key); }
            commands[key] = {
                name: key,
                handler: handler,
                description: typeof opts.description === 'string' ? opts.description : '',
                usage: typeof opts.usage === 'string' ? opts.usage : ''
            };
            notifyHooks();
            return function () {
                if (commands[key] && commands[key].handler === handler) {
                    delete commands[key];
                    commandOrder.splice(commandOrder.indexOf(key), 1);
                    notifyHooks();
                }
            };
        }

        function setPrefix(value) {
            requireString(value, 'prefix');
            if (value.length < 1 || value.length > 3 || /[A-Za-z0-9\\s]/.test(value)) {
                throw new Error('Prefix must be 1 to 3 characters and contain no letters, digits or spaces');
            }
            prefix = value;
        }

        function listCommands() {
            return commandOrder.map(function (key) {
                var command = commands[key];
                return { name: command.name, description: command.description, usage: command.usage };
            });
        }

        // ---- promises completed by the host ---------------------------------------------

        var nextRequestId = 1;
        var pending = {};

        function request(kind, payload) {
            return new Promise(function (resolve, reject) {
                var id = nextRequestId++;
                pending[id] = { resolve: resolve, reject: reject };
                host.request(kind, JSON.stringify(payload === undefined ? {} : payload), id);
            });
        }

        function settle(id, isRejection, value) {
            var entry = pending[id];
            if (!entry) { return; }
            delete pending[id];
            if (isRejection) {
                entry.reject(new Error(typeof value === 'string' ? value : 'Request failed'));
            } else {
                entry.resolve(value);
            }
        }

        // ---- storage and settings ---------------------------------------------------------

        function parseJSON(text, fallback) {
            if (typeof text !== 'string' || text.length === 0) { return fallback; }
            try { return JSON.parse(text); } catch (error) { return fallback; }
        }

        function encodeValue(value, name) {
            var json = JSON.stringify(value);
            if (json === undefined) { throw typeError(name + ' must be a JSON value'); }
            return json;
        }

        var storageCache = parseJSON(host.storageInitial(), {});
        if (storageCache === null || typeof storageCache !== 'object' || Array.isArray(storageCache)) { storageCache = {}; }

        var storage = freeze({
            get: function (key, fallback) {
                requireString(key, 'key');
                return storageCache.hasOwnProperty(key) ? JSON.parse(JSON.stringify(storageCache[key])) : fallback;
            },
            set: function (key, value) {
                requireString(key, 'key');
                var json = encodeValue(value, 'value');
                if (!host.storageWrite(key, json)) { throw new Error('Storage limit exceeded'); }
                storageCache[key] = JSON.parse(json);
            },
            remove: function (key) {
                requireString(key, 'key');
                host.storageWrite(key, null);
                delete storageCache[key];
            },
            keys: function () { return Object.keys(storageCache); },
            clear: function () {
                var keys = Object.keys(storageCache);
                for (var i = 0; i < keys.length; i++) { host.storageWrite(keys[i], null); }
                storageCache = {};
            }
        });

        var settingsCache = parseJSON(host.settingsInitial(), {});
        if (settingsCache === null || typeof settingsCache !== 'object' || Array.isArray(settingsCache)) { settingsCache = {}; }
        var settingsSchema = [];

        function settingDefault(key) {
            for (var i = 0; i < settingsSchema.length; i++) {
                if (settingsSchema[i].key === key) { return settingsSchema[i]['default']; }
            }
            return undefined;
        }

        var settings = freeze({
            define: function (fields) {
                if (!Array.isArray(fields)) { throw typeError('fields must be an array'); }
                var clean = [];
                for (var i = 0; i < fields.length; i++) {
                    var field = fields[i];
                    if (!field || typeof field !== 'object' || typeof field.key !== 'string' || typeof field.type !== 'string') { continue; }
                    clean.push(field);
                }
                settingsSchema = JSON.parse(JSON.stringify(clean));
                host.settingsDefine(JSON.stringify(settingsSchema));
            },
            get: function (key, fallback) {
                requireString(key, 'key');
                if (settingsCache.hasOwnProperty(key)) { return JSON.parse(JSON.stringify(settingsCache[key])); }
                var value = settingDefault(key);
                return value === undefined ? fallback : value;
            },
            set: function (key, value) {
                requireString(key, 'key');
                var json = encodeValue(value, 'value');
                host.settingsWrite(key, json);
                settingsCache[key] = JSON.parse(json);
            },
            all: function () {
                var result = {};
                for (var i = 0; i < settingsSchema.length; i++) {
                    var key = settingsSchema[i].key;
                    if (settingsSchema[i]['default'] !== undefined) { result[key] = settingsSchema[i]['default']; }
                }
                var keys = Object.keys(settingsCache);
                for (var j = 0; j < keys.length; j++) { result[keys[j]] = settingsCache[keys[j]]; }
                return JSON.parse(JSON.stringify(result));
            }
        });

        // ---- native UI and integrations -------------------------------------------------

        var settingsShortcuts = [];
        var contextActions = [];
        var builderPages = [];

        function registerIntegration(target, definition, publish) {
            var value = optionalObject(definition, 'definition');
            if (typeof value.id !== 'string' || typeof value.title !== 'string') {
                throw typeError('integration id and title must be strings');
            }
            var clean = JSON.parse(JSON.stringify(value));
            for (var i = 0; i < target.length; i++) {
                if (target[i].id === clean.id) { target.splice(i, 1); break; }
            }
            target.push(clean);
            if (!publish(JSON.stringify(target))) { target.pop(); throw new Error('Invalid integration definition or permission not granted'); }
            return function () {
                for (var j = target.length - 1; j >= 0; j--) {
                    if (target[j].id === clean.id) { target.splice(j, 1); }
                }
                publish(JSON.stringify(target));
            };
        }

        function pageStyle(options) {
            var opts = optionalObject(options, 'options');
            var style = typeof opts.style === 'string' ? opts.style : 'push';
            if (['push', 'sheet', 'fullScreen'].indexOf(style) === -1) { throw new Error('style must be push, sheet or fullScreen'); }
            return style;
        }

        function publishBuilderPage(page) {
            var snapshot = JSON.parse(JSON.stringify(page));
            for (var i = 0; i < builderPages.length; i++) {
                if (builderPages[i].id === snapshot.id) { builderPages.splice(i, 1); break; }
            }
            builderPages.push(snapshot);
            if (!host.pagesDefine(JSON.stringify(builderPages))) { throw new Error('Invalid page definition or permission not granted'); }
        }

        function createPage(definition) {
            var opts = optionalObject(definition, 'definition');
            var id = requireString(opts.id, 'page id');
            var title = requireString(opts.title, 'page title');
            var page = { id: id, title: title, sections: [] };

            function addSection(definition) {
                var sectionOptions = optionalObject(definition, 'section');
                var section = { rows: [] };
                if (typeof sectionOptions.title === 'string') { section.title = sectionOptions.title; }
                if (typeof sectionOptions.footer === 'string') { section.footer = sectionOptions.footer; }
                page.sections.push(section);

                function addRow(type, definition) {
                    var rowOptions = optionalObject(definition, 'row');
                    var row = {};
                    var keys = Object.keys(rowOptions);
                    for (var i = 0; i < keys.length; i++) { row[keys[i]] = rowOptions[keys[i]]; }
                    row.id = requireString(row.id, 'row id');
                    row.title = requireString(row.title, 'row title');
                    row.type = type;
                    section.rows.push(row);
                    return sectionApi;
                }

                var sectionApi = freeze({
                    text: function (row) { return addRow('text', row); },
                    button: function (row) { return addRow('button', row); },
                    toggle: function (row) { return addRow('toggle', row); },
                    input: function (row) { return addRow('input', row); },
                    multiline: function (row) { return addRow('multiline', row); },
                    number: function (row) { return addRow('number', row); },
                    select: function (row) { return addRow('select', row); },
                    link: function (row) { return addRow('link', row); },
                    slider: function (row) { return addRow('slider', row); },
                    stepper: function (row) { return addRow('stepper', row); },
                    end: function () { return pageApi; }
                });
                return sectionApi;
            }

            function update(rowId, value) {
                requireString(rowId, 'rowId');
                for (var i = 0; i < page.sections.length; i++) {
                    for (var j = 0; j < page.sections[i].rows.length; j++) {
                        if (page.sections[i].rows[j].id === rowId) {
                            page.sections[i].rows[j].value = value;
                            publishBuilderPage(page);
                            return pageApi;
                        }
                    }
                }
                throw new Error('Unknown row: ' + rowId);
            }

            var pageApi = freeze({
                section: addSection,
                publish: function () { publishBuilderPage(page); return pageApi; },
                open: function (options) {
                    publishBuilderPage(page);
                    return request('ui.openPage', { pageId: id, style: pageStyle(options) });
                },
                update: update,
                snapshot: function () { return JSON.parse(JSON.stringify(page)); }
            });
            return pageApi;
        }

        function createAIChat(options) {
            var opts = optionalObject(options, 'options');
            var history = Array.isArray(opts.history) ? JSON.parse(JSON.stringify(opts.history)) : [];
            return freeze({
                ask: function (prompt) {
                    var text = requireString(prompt, 'prompt');
                    return request('ai.ask', { prompt: text, history: history }).then(function (answer) {
                        history.push({ role: 'user', content: text });
                        if (answer && typeof answer.text === 'string' && answer.text.length > 0) {
                            history.push({ role: 'assistant', content: answer.text });
                        }
                        if (history.length > 20) { history = history.slice(history.length - 20); }
                        return answer;
                    });
                },
                clear: function () { history = []; },
                messages: function () { return JSON.parse(JSON.stringify(history)); }
            });
        }

        // ---- timers -------------------------------------------------------------------

        var timers = {};
        var timerCount = 0;
        var nextTimerId = 1;

        function schedule(callback, delay, repeat) {
            requireFunction(callback, 'callback');
            if (timerCount >= MAX_TIMERS) { throw new Error('Too many timers (limit ' + MAX_TIMERS + ')'); }
            var ms = Number(delay);
            if (!isFinite(ms) || ms < 0) { ms = 0; }
            if (repeat && ms < 10) { ms = 10; }
            var id = nextTimerId++;
            var extra = Array.prototype.slice.call(arguments, 3);
            timers[id] = { callback: callback, args: extra, repeat: repeat };
            timerCount++;
            host.timerSchedule(id, ms, repeat);
            return id;
        }

        function cancel(id) {
            if (timers[id]) {
                delete timers[id];
                timerCount--;
                host.timerCancel(id);
            }
        }

        function timerFire(id) {
            var timer = timers[id];
            if (!timer) { return; }
            if (!timer.repeat) {
                delete timers[id];
                timerCount--;
            }
            try {
                timer.callback.apply(undefined, timer.args);
            } catch (error) {
                reportError('Timer callback failed', error);
            }
        }

        // ---- the outgoing text hook -------------------------------------------------------

        function runCommand(text, peerId, accountId) {
            var trimmed = text.replace(/^\\s+/, '');
            if (commandOrder.length === 0 || trimmed.slice(0, prefix.length) !== prefix) { return null; }
            var body = trimmed.slice(prefix.length);
            var match = /^([A-Za-z0-9_\\-]+)(?:\\s+([\\s\\S]*))?$/.exec(body);
            if (!match) { return null; }
            var name = match[1].toLowerCase();
            var command = commands[name];
            if (!command) { return null; }
            var args = match[2] === undefined ? '' : match[2].replace(/\\s+$/, '');
            var context = freeze({ peerId: peerId, accountId: accountId, raw: text, command: name });
            var result;
            try {
                result = command.handler(args, context);
            } catch (error) {
                reportError('Command ' + prefix + name + ' failed', error);
                return { consumed: true, replacement: null };
            }
            if (result && typeof result.then === 'function') {
                result.then(function (value) {
                    if (typeof value === 'string' && value.length > 0) {
                        aorus.messages.send(peerId, value, { accountId: accountId }).then(undefined, function (error) {
                            reportError('Command ' + prefix + name + ' could not send its result', error);
                        });
                    }
                }, function (error) {
                    reportError('Command ' + prefix + name + ' rejected', error);
                });
                return { consumed: true, replacement: null };
            }
            if (typeof result === 'string') { return { consumed: false, replacement: result }; }
            host.log('debug', 'Command ' + prefix + name + ' handled');
            return { consumed: true, replacement: null };
        }

        function runOutgoing(text, peerId, accountId) {
            var verdict = runCommand(text, peerId, accountId);
            if (verdict) { return verdict; }
            var current = text;
            var list = handlers.send.slice();
            for (var i = 0; i < list.length; i++) {
                var result;
                try {
                    result = list[i](freeze({ text: current, peerId: peerId, accountId: accountId }));
                } catch (error) {
                    reportError('Handler for \\'send\\' failed', error);
                    continue;
                }
                if (result === false) { return { consumed: true, replacement: null }; }
                if (typeof result === 'string') { current = result; continue; }
                if (result && typeof result.then === 'function') {
                    host.log('warn', 'A \\'send\\' handler returned a Promise; the text was sent unchanged. Use a command for asynchronous work.');
                }
            }
            return { consumed: false, replacement: current === text ? null : current };
        }

        // ---- the public API -----------------------------------------------------------------

        var info = host.pluginInfo();
        var device = host.deviceInfo();

        var cryptoApi = freeze({
            sha256: function (text) { return host.crypto('sha256', requireString(text, 'text'), ''); },
            hmacSHA256: function (key, text) { return host.crypto('hmac', requireString(key, 'key'), requireString(text, 'text')); },
            randomUUID: function () { return host.crypto('uuid', '', ''); },
            randomBytes: function (count) {
                var n = Number(count);
                if (!isFinite(n) || n < 1 || n > 1024) { throw new RangeError('count must be between 1 and 1024'); }
                return host.crypto('random', String(Math.floor(n)), '');
            },
            base64Encode: function (text) { return host.crypto('b64e', requireString(text, 'text'), ''); },
            base64Decode: function (text) {
                var result = host.crypto('b64d', requireString(text, 'text'), '');
                if (result === null) { throw new Error('Not valid base64'); }
                return result;
            }
        });

        var aorus = freeze({
            version: '\(apiVersion)',
            plugin: freeze({ id: info.id, name: info.name, version: info.version, author: info.author }),
            language: host.language(),
            device: freeze({
                language: device.language,
                systemVersion: device.systemVersion,
                appVersion: device.appVersion,
                isDark: !!device.isDark
            }),
            on: on,
            off: off,
            once: once,
            commands: freeze({
                register: registerCommand,
                setPrefix: setPrefix,
                prefix: function () { return prefix; },
                list: listCommands
            }),
            messages: freeze({
                send: function (peerId, text, options) {
                    var target = toPeerId(peerId);
                    requireString(text, 'text');
                    var opts = optionalObject(options, 'options');
                    return request('messages.send', {
                        peerId: target === 'me' ? null : target,
                        toSelf: target === 'me',
                        text: text,
                        replyTo: typeof opts.replyTo === 'number' ? opts.replyTo : null,
                        accountId: (typeof opts.accountId === 'string' && /^-?\\d+$/.test(opts.accountId)) ? opts.accountId : (typeof opts.accountId === 'number' && Number.isSafeInteger(opts.accountId) ? String(opts.accountId) : null)
                    });
                }
            }),
            chats: freeze({
                resolve: function (username) {
                    var name = requireString(username, 'username').replace(/^@/, '');
                    return request('chats.resolve', { username: name });
                },
                get: function (peerId) {
                    var target = toPeerId(peerId);
                    return request('chats.get', { peerId: target === 'me' ? null : target, toSelf: target === 'me' });
                },
                open: function (peerId) {
                    var target = toPeerId(peerId);
                    return request('chats.open', { peerId: target === 'me' ? null : target, toSelf: target === 'me' });
                }
            }),
            account: freeze({
                current: function () { return request('account.current', {}); }
            }),
            storage: storage,
            settings: settings,
            http: freeze({
                fetch: function (url, options) {
                    requireString(url, 'url');
                    var opts = optionalObject(options, 'options');
                    var headers = {};
                    if (opts.headers && typeof opts.headers === 'object') {
                        var names = Object.keys(opts.headers);
                        for (var i = 0; i < names.length; i++) { headers[names[i]] = String(opts.headers[names[i]]); }
                    }
                    var body = opts.body;
                    if (body !== undefined && body !== null && typeof body !== 'string') { body = JSON.stringify(body); }
                    return request('http.fetch', {
                        url: url,
                        method: typeof opts.method === 'string' ? opts.method.toUpperCase() : 'GET',
                        headers: headers,
                        body: typeof body === 'string' ? body : null,
                        timeout: typeof opts.timeout === 'number' ? opts.timeout : null
                    }).then(function (response) {
                        var text = typeof response.body === 'string' ? response.body : '';
                        return freeze({
                            status: response.status,
                            ok: response.status >= 200 && response.status < 300,
                            url: response.url,
                            headers: freeze(response.headers || {}),
                            text: function () { return text; },
                            json: function () { return JSON.parse(text); }
                        });
                    });
                }
            }),
            ui: freeze({
                toast: function (text, options) {
                    var opts = optionalObject(options, 'options');
                    host.toast(requireString(text, 'text').slice(0, 200), typeof opts.duration === 'number' ? opts.duration : 0);
                },
                alert: function (title, text) {
                    return request('ui.alert', { title: requireString(title, 'title'), text: text === undefined ? null : String(text) });
                },
                confirm: function (title, text, options) {
                    var opts = optionalObject(options, 'options');
                    return request('ui.confirm', {
                        title: requireString(title, 'title'),
                        text: text === undefined ? null : String(text),
                        ok: typeof opts.ok === 'string' ? opts.ok : null,
                        cancel: typeof opts.cancel === 'string' ? opts.cancel : null
                    });
                },
                prompt: function (title, text, options) {
                    var opts = optionalObject(options, 'options');
                    return request('ui.prompt', {
                        title: requireString(title, 'title'),
                        text: text === undefined ? null : String(text),
                        placeholder: typeof opts.placeholder === 'string' ? opts.placeholder : null,
                        defaultValue: typeof opts['default'] === 'string' ? opts['default'] : null,
                        ok: typeof opts.ok === 'string' ? opts.ok : null,
                        cancel: typeof opts.cancel === 'string' ? opts.cancel : null
                    });
                },
                share: function (value) {
                    var opts = typeof value === 'string' ? { text: value } : optionalObject(value, 'value');
                    return request('ui.share', {
                        text: typeof opts.text === 'string' ? opts.text : null,
                        url: typeof opts.url === 'string' ? opts.url : null
                    });
                },
                haptic: function (kind) { host.haptic(requireString(kind, 'kind')); },
                definePages: function (pages) {
                    if (!Array.isArray(pages)) { throw typeError('pages must be an array'); }
                    if (!host.pagesDefine(JSON.stringify(pages))) { throw new Error('Invalid page definition or permission not granted'); }
                },
                createPage: createPage,
                openPage: function (pageId, options) {
                    return request('ui.openPage', { pageId: requireString(pageId, 'pageId'), style: pageStyle(options) });
                },
                presentPage: function (pageId, options) {
                    var opts = optionalObject(options, 'options');
                    return request('ui.openPage', { pageId: requireString(pageId, 'pageId'), style: typeof opts.style === 'string' ? pageStyle(opts) : 'sheet' });
                },
                openURL: function (url) {
                    return request('browser.open', { url: requireString(url, 'url') });
                }
            }),
            browser: freeze({
                open: function (url) { return request('browser.open', { url: requireString(url, 'url') }); }
            }),
            app: freeze({
                info: function () {
                    return freeze({
                        language: device.language,
                        systemVersion: device.systemVersion,
                        appVersion: device.appVersion,
                        isDark: !!device.isDark
                    });
                },
                currentAccount: function () { return request('account.current', {}); },
                openChat: function (peerId) {
                    var target = toPeerId(peerId);
                    return request('chats.open', { peerId: target === 'me' ? null : target, toSelf: target === 'me' });
                },
                openURL: function (url) { return request('browser.open', { url: requireString(url, 'url') }); },
                haptic: function (kind) { host.haptic(requireString(kind, 'kind')); },
                share: function (value) {
                    var opts = typeof value === 'string' ? { text: value } : optionalObject(value, 'value');
                    return request('ui.share', {
                        text: typeof opts.text === 'string' ? opts.text : null,
                        url: typeof opts.url === 'string' ? opts.url : null
                    });
                }
            }),
            integrations: freeze({
                settings: freeze({
                    register: function (definition) {
                        return registerIntegration(settingsShortcuts, definition, function (json) { return host.settingsShortcutsDefine(json); });
                    }
                }),
                contextMenu: freeze({
                    register: function (definition) {
                        return registerIntegration(contextActions, definition, function (json) { return host.contextActionsDefine(json); });
                    }
                })
            }),
            ai: freeze({
                createChat: createAIChat,
                ask: function (prompt, options) {
                    var opts = optionalObject(options, 'options');
                    var history = Array.isArray(opts.history) ? opts.history : [];
                    return request('ai.ask', { prompt: requireString(prompt, 'prompt'), history: history });
                },
                openArtifact: function (artifactId) {
                    return request('ai.openArtifact', { artifactId: requireString(artifactId, 'artifactId') });
                }
            }),
            clipboard: freeze({
                read: function () { return request('clipboard.read', {}); },
                write: function (text) { host.clipboardWrite(requireString(text, 'text')); }
            }),
            crypto: cryptoApi,
            util: freeze({
                sleep: function (ms) { return request('util.sleep', { ms: Number(ms) || 0 }); }
            })
        });

        function publish(name, value) {
            Object.defineProperty(globalThis, name, { value: value, writable: false, configurable: false, enumerable: true });
        }

        publish('aorus', aorus);
        publish('console', console);
        publish('setTimeout', function (callback, delay) { return schedule.apply(undefined, [callback, delay, false].concat(Array.prototype.slice.call(arguments, 2))); });
        publish('setInterval', function (callback, delay) { return schedule.apply(undefined, [callback, delay, true].concat(Array.prototype.slice.call(arguments, 2))); });
        publish('clearTimeout', cancel);
        publish('clearInterval', cancel);

        host.registerDispatcher(freeze({
            dispatch: function (event, payload) { emit(event, payload === undefined ? undefined : freeze(payload)); },
            runOutgoing: runOutgoing,
            timerFire: timerFire,
            resolve: function (id, json) { settle(id, false, parseJSON(json, undefined)); },
            reject: function (id, message) { settle(id, true, message); },
            settingsChanged: function (json) {
                var values = parseJSON(json, {});
                settingsCache = (values && typeof values === 'object' && !Array.isArray(values)) ? values : {};
                emit('settingsChanged', settings.all());
            },
            hasHooks: function () { return handlers.send.length > 0 || commandOrder.length > 0; },
            // What the plugin actually registered, for the card that answers "why did my
            // command do nothing". Reading it changes nothing.
            commandNames: function () { return commandOrder.slice(); },
            commandPrefix: function () { return prefix; },
            eventNames: function () {
                var names = [];
                for (var i = 0; i < KNOWN_EVENTS.length; i++) {
                    if (handlers[KNOWN_EVENTS[i]].length > 0) { names.push(KNOWN_EVENTS[i]); }
                }
                return names;
            }
        }));
    })(globalThis.__aorusHost);
    delete globalThis.__aorusHost;
    """
}
