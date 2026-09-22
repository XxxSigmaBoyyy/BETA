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
        "foreground", "background", "settingsChanged", "appSettingsChanged",
        "connectionChanged", "uiAction", "contextAction", "settings.changed", "settings.action", "settings.reset",
        "chatOpened", "chatClosed", "inputChanged", "overlayAction", "pluginMessage", "nativeButtonAction",
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

        function messageReference(value) {
            var ref = optionalObject(value, 'message');
            var peerId = toPeerId(ref.peerId);
            var namespace = Number(ref.namespace);
            var messageId = Number(ref.messageId === undefined ? ref.id : ref.messageId);
            if (peerId === 'me') { throw typeError('message.peerId must identify a chat'); }
            if (!Number.isSafeInteger(namespace) || namespace < -2147483648 || namespace > 2147483647) { throw new RangeError('message.namespace is invalid'); }
            if (!Number.isSafeInteger(messageId) || messageId < -2147483648 || messageId > 2147483647) { throw new RangeError('message.messageId is invalid'); }
            return { peerId: peerId, namespace: namespace, messageId: messageId };
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
            debug: function () { log('debug', arguments); },
            // The same lines the console screen shows, as data. A plugin that draws its own
            // diagnostics page should be able to show what it has been saying.
            history: function (limit) {
                var count = limit === undefined ? 100 : Number(limit);
                if (!Number.isSafeInteger(count) || count < 1 || count > 500) {
                    throw new RangeError('limit must be between 1 and 500');
                }
                return freeze(parseJSON(host.logHistory(count), []));
            }
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
            // An overlay carries the function that was handed to `add*`, so a plugin does not
            // have to subscribe to a stream and work out which of its buttons was pressed.
            // The event is also emitted, for a plugin that prefers to listen.
            if (event === 'pluginMessage') { pluginMessageReceived(payload); }
            if (event === 'nativeButtonAction' && payload && nativeHandlers.hasOwnProperty(payload.id)) {
                try {
                    var pressed = nativeHandlers[payload.id](payload);
                    if (pressed && typeof pressed.then === 'function') {
                        pressed.then(undefined, function (error) { reportError('Button handler for \\'' + payload.id + '\\' rejected', error); });
                    }
                } catch (error) {
                    reportError('Button handler for \\'' + payload.id + '\\' failed', error);
                }
            }
            if (event === 'overlayAction' && payload && overlayHandlers.hasOwnProperty(payload.id)) {
                try {
                    var direct = overlayHandlers[payload.id](payload);
                    if (direct && typeof direct.then === 'function') {
                        direct.then(undefined, function (error) { reportError('Overlay handler for \\'' + payload.id + '\\' rejected', error); });
                    }
                } catch (error) {
                    reportError('Overlay handler for \\'' + payload.id + '\\' failed', error);
                }
            }
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

        function request(kind, payload, onEvent) {
            return new Promise(function (resolve, reject) {
                var id = nextRequestId++;
                pending[id] = { resolve: resolve, reject: reject, onEvent: onEvent };
                host.request(kind, JSON.stringify(payload === undefined ? {} : payload), id);
            });
        }

        function requestEvent(id, json) {
            var entry = pending[id];
            if (!entry || typeof entry.onEvent !== 'function') { return; }
            try { entry.onEvent(parseJSON(json, {})); }
            catch (error) { reportError('AorusAI event handler failed', error); }
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
            has: function (key) { return storageCache.hasOwnProperty(requireString(key, 'key')); },
            // `getJSON`/`setJSON` are the same bucket. Storage already holds JSON values, so
            // these exist to match the shape people write against, and to give a fallback a
            // name rather than leaving it to `|| {}` at every call site.
            getJSON: function (key, fallback) {
                requireString(key, 'key');
                if (!storageCache.hasOwnProperty(key)) { return fallback === undefined ? null : fallback; }
                return JSON.parse(JSON.stringify(storageCache[key]));
            },
            setJSON: function (key, value) { return storage.set(key, value === undefined ? null : value); },
            // Appends to an array, creating it when it is not there, and answers the new
            // length. Doing this by hand is a read, a type check, a push and a write, and
            // the type check is the part people skip.
            push: function (key, value) {
                requireString(key, 'key');
                var current = storageCache.hasOwnProperty(key) ? storageCache[key] : [];
                if (!Array.isArray(current)) { current = []; }
                current = current.slice();
                current.push(value === undefined ? null : value);
                storage.set(key, current);
                return current.length;
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
            addSection: function (section) {
                var value = optionalObject(section, 'section');
                if (!Array.isArray(value.items)) { throw typeError('section.items must be an array'); }
                var fields = settingsSchema.slice();
                fields.push({ key: '__section_' + fields.length, type: 'section', title: requireString(value.title, 'section.title') });
                for (var i = 0; i < value.items.length; i++) {
                    var item = value.items[i];
                    if (item && typeof item.key === 'string' && typeof item.type === 'string') { fields.push(item); }
                }
                settingsSchema = JSON.parse(JSON.stringify(fields));
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
            getPlugin: function (key, fallback) { return settings.get(key, fallback); },
            setPlugin: function (key, value) { settings.set(key, value); },
            toggle: function (key, fallback) {
                var next = !settings.get(key, fallback);
                settings.set(key, next);
                return next;
            },
            remove: function (key) {
                requireString(key, 'key');
                host.settingsWrite(key, 'null');
                delete settingsCache[key];
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

        // ---- formatted text ---------------------------------------------------------------

        // Telegram counts entity offsets in UTF-16 code units, which is not what
        // `String.length` gives you once an emoji is involved — and getting it wrong moves
        // the formatting onto the wrong characters rather than failing. `compose` walks the
        // parts and counts for you.
        var ENTITY_TYPES = ['bold', 'italic', 'underline', 'strikethrough', 'spoiler', 'code', 'pre', 'blockquote', 'text_link', 'custom_emoji'];

        function utf16Length(value) { return String(value).length; }

        function textPart(value, entity) {
            return { __aorusTextPart: true, text: String(value), entity: entity || null };
        }

        function styled(type) {
            return function (value) { return textPart(value, { type: type }); };
        }

        function entityDescriptor(type, offset, length, extra) {
            requireString(type, 'type');
            if (ENTITY_TYPES.indexOf(type) === -1) { throw new Error('Unknown entity type: ' + type); }
            var entity = { type: type, offset: Math.max(0, Math.floor(Number(offset) || 0)), length: Math.max(0, Math.floor(Number(length) || 0)) };
            var options = optionalObject(extra, 'extra');
            if (typeof options.url === 'string') { entity.url = options.url; }
            if (typeof options.language === 'string') { entity.language = options.language; }
            if (typeof options.customEmojiId === 'string') { entity.customEmojiId = options.customEmojiId; }
            if (options.collapsed !== undefined) { entity.collapsed = !!options.collapsed; }
            return entity;
        }

        var textApi = freeze({
            bold: styled('bold'),
            italic: styled('italic'),
            underline: styled('underline'),
            strikethrough: styled('strikethrough'),
            spoiler: styled('spoiler'),
            code: styled('code'),
            pre: function (value, language) {
                return textPart(value, typeof language === 'string' ? { type: 'pre', language: language } : { type: 'pre' });
            },
            blockquote: function (value, collapsed) {
                return textPart(value, { type: 'blockquote', collapsed: !!collapsed });
            },
            link: function (value, url) {
                return textPart(value, { type: 'text_link', url: requireString(url, 'url') });
            },
            customEmoji: function (value, customEmojiId) {
                return textPart(value, { type: 'custom_emoji', customEmojiId: requireString(customEmojiId, 'customEmojiId') });
            },
            entity: entityDescriptor,
            compose: function (parts) {
                if (!Array.isArray(parts)) { throw typeError('parts must be an array'); }
                var text = '';
                var entities = [];
                for (var i = 0; i < parts.length; i++) {
                    var part = parts[i];
                    if (part && part.__aorusTextPart) {
                        var offset = utf16Length(text);
                        var length = utf16Length(part.text);
                        text += part.text;
                        if (part.entity && length > 0) {
                            var entity = { type: part.entity.type, offset: offset, length: length };
                            if (part.entity.url !== undefined) { entity.url = part.entity.url; }
                            if (part.entity.language !== undefined) { entity.language = part.entity.language; }
                            if (part.entity.customEmojiId !== undefined) { entity.customEmojiId = part.entity.customEmojiId; }
                            if (part.entity.collapsed !== undefined) { entity.collapsed = part.entity.collapsed; }
                            entities.push(entity);
                        }
                    } else {
                        text += String(part === undefined || part === null ? '' : part);
                    }
                }
                return { text: text, entities: entities };
            }
        });

        // A send payload may be a plain string or the object `text.compose` returns.
        function textPayload(value, fallbackOptions) {
            if (typeof value === 'string') {
                return { text: value, entities: [] };
            }
            var payload = optionalObject(value, 'text');
            var text = requireString(payload.text, 'text');
            var entities = Array.isArray(payload.entities) ? payload.entities : [];
            var clean = [];
            for (var i = 0; i < entities.length && clean.length < 128; i++) {
                var item = optionalObject(entities[i], 'entity');
                clean.push(entityDescriptor(item.type, item.offset, item.length, item));
            }
            return { text: text, entities: clean };
        }

        // ---- native UI and integrations -------------------------------------------------

        var settingsShortcuts = [];
        var contextActions = [];
        var builderPages = [];
        // What the plugin has drawn over the chat, and who to call when it is tapped. The
        // whole set is republished on every change, because the app holds one list per
        // plugin and an add is the list plus one.
        var overlays = [];
        var overlayHandlers = {};
        var overlaySequence = 0;

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

        // Buttons a plugin puts into Telegram's own containers. Same shape as the overlays:
        // the whole set is republished on every change, the handler goes to `add`, and an
        // add that is not accepted throws instead of handing back an id for nothing.
        var nativeButtons = [];
        var nativeHandlers = {};
        var nativeSequence = 0;
        function publishNativeButtons() {
            var accepted = host.nativeButtonsDefine(JSON.stringify(nativeButtons));
            if (accepted < 0) { throw new Error('Custom UI permission is not granted'); }
            if (accepted !== nativeButtons.length) { throw new Error('Invalid button definition'); }
        }
        function addNativeButton(place, config, handler) {
            if (handler !== undefined && handler !== null) { requireFunction(handler, 'handler'); }
            var value = optionalObject(config, 'config');
            nativeSequence += 1;
            var id = place + '-' + nativeSequence;
            var clean = JSON.parse(JSON.stringify(value));
            clean.place = place;
            clean.id = id;
            var previous = nativeButtons.slice();
            nativeButtons.push(clean);
            try {
                publishNativeButtons();
            } catch (error) {
                nativeButtons = previous;
                throw error;
            }
            if (handler) { nativeHandlers[id] = handler; }
            return id;
        }
        function removeNativeButton(id) {
            requireString(id, 'id');
            var found = false;
            for (var i = nativeButtons.length - 1; i >= 0; i--) {
                if (nativeButtons[i].id === id) { nativeButtons.splice(i, 1); found = true; }
            }
            if (!found) { return false; }
            delete nativeHandlers[id];
            publishNativeButtons();
            return true;
        }

        function overlayConfig(kind, config, id) {
            var value = optionalObject(config, 'config');
            var clean = JSON.parse(JSON.stringify(value));
            clean.kind = kind;
            clean.id = id;
            return clean;
        }

        function publishOverlays() {
            var accepted = host.overlaysDefine(JSON.stringify(overlays));
            if (accepted < 0) { throw new Error('Custom UI permission is not granted'); }
            // Fewer accepted than sent means one was dropped for having nothing to draw. The
            // caller hears about it instead of holding an id for a button that is not there.
            if (accepted !== overlays.length) { throw new Error('Invalid overlay definition'); }
        }

        function addOverlay(kind, config, handler) {
            if (handler !== undefined && handler !== null) { requireFunction(handler, 'handler'); }
            overlaySequence += 1;
            var id = kind + '-' + overlaySequence;
            var previous = overlays.slice();
            overlays.push(overlayConfig(kind, config, id));
            try {
                publishOverlays();
            } catch (error) {
                overlays = previous;
                throw error;
            }
            if (handler) { overlayHandlers[id] = handler; }
            return id;
        }

        function updateOverlay(kind, id, config) {
            requireString(id, 'id');
            for (var i = 0; i < overlays.length; i++) {
                if (overlays[i].id === id) {
                    var previous = overlays.slice();
                    // An update is the same validation as an add, so a change that would not
                    // have been accepted in the first place leaves what is on screen alone.
                    overlays[i] = overlayConfig(kind, config, id);
                    try {
                        publishOverlays();
                    } catch (error) {
                        overlays = previous;
                        throw error;
                    }
                    return true;
                }
            }
            return false;
        }

        function removeOverlay(id) {
            requireString(id, 'id');
            var found = false;
            for (var i = overlays.length - 1; i >= 0; i--) {
                if (overlays[i].id === id) { overlays.splice(i, 1); found = true; }
            }
            if (!found) { return false; }
            delete overlayHandlers[id];
            publishOverlays();
            return true;
        }

        function removeAllOverlays() {
            if (overlays.length === 0) { return 0; }
            var count = overlays.length;
            overlays = [];
            overlayHandlers = {};
            publishOverlays();
            return count;
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
            var threadId = typeof opts.threadId === 'string' ? opts.threadId : host.crypto('uuid', '', '');
            return freeze({
                ask: function (prompt, options) {
                    var text = requireString(prompt, 'prompt');
                    var call = optionalObject(options, 'options');
                    return request('ai.ask', { prompt: text, history: history, threadId: threadId }, call.onEvent).then(function (answer) {
                        history.push({ role: 'user', content: text });
                        if (answer && typeof answer.text === 'string' && answer.text.length > 0) {
                            history.push({ role: 'assistant', content: answer.text });
                        }
                        if (history.length > 20) { history = history.slice(history.length - 20); }
                        return answer;
                    });
                },
                clear: function () { history = []; threadId = host.crypto('uuid', '', ''); },
                messages: function () { return JSON.parse(JSON.stringify(history)); },
                threadId: function () { return threadId; }
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

        // App customization is deliberately key-based. The native host owns the catalog,
        // validates every value and never exposes UserDefaults, selectors or Swift objects.
        var featureApi = freeze({
            list: function () { return request('features.list', {}); },
            get: function (id) { return request('features.get', { id: requireString(id, 'id') }); },
            set: function (id, value) { return request('features.set', { id: requireString(id, 'id'), value: value }); }
        });

        var interfaceApi = freeze({
            list: function () {
                return featureApi.list().then(function (items) {
                    return freeze((items || []).filter(function (item) {
                        return item && (item.category === 'interface' || item.category === 'tabs');
                    }));
                });
            },
            get: featureApi.get,
            set: featureApi.set
        });

        var tabFeatureIds = freeze([
            'hideCallsTab', 'hideContactsTab', 'hideSearchButton',
            'hideTabTitles', 'compactTabBar', 'wallEnabled'
        ]);
        var tabsApi = freeze({
            list: function () {
                return featureApi.list().then(function (items) {
                    return freeze((items || []).filter(function (item) { return item && tabFeatureIds.indexOf(item.id) !== -1; }));
                });
            },
            setVisible: function (tab, visible) {
                requireString(tab, 'tab');
                if (typeof visible !== 'boolean') { throw typeError('visible must be a boolean'); }
                var keys = { calls: 'hideCallsTab', contacts: 'hideContactsTab', wall: 'wallEnabled', search: 'hideSearchButton' };
                if (!keys.hasOwnProperty(tab)) { throw new Error('Unknown tab: ' + tab); }
                return featureApi.set(keys[tab], tab === 'wall' ? visible : !visible);
            },
            setTitlesVisible: function (visible) {
                if (typeof visible !== 'boolean') { throw typeError('visible must be a boolean'); }
                return featureApi.set('hideTabTitles', !visible);
            },
            setCompact: function (compact) {
                if (typeof compact !== 'boolean') { throw typeError('compact must be a boolean'); }
                return featureApi.set('compactTabBar', compact);
            }
        });

        var avatarsApi = freeze({
            isSquare: function () { return featureApi.get('squareAvatars').then(function (item) { return !!(item && item.value); }); },
            setSquare: function (square) {
                if (typeof square !== 'boolean') { throw typeError('square must be a boolean'); }
                return featureApi.set('squareAvatars', square);
            }
        });

        var wallApi = freeze({
            status: function () { return featureApi.get('wallEnabled'); },
            setEnabled: function (enabled) {
                if (typeof enabled !== 'boolean') { throw typeError('enabled must be a boolean'); }
                return featureApi.set('wallEnabled', enabled);
            }
        });

        var proxyApi = freeze({
            status: function () { return request('proxy.status', {}); },
            setEnabled: function (enabled) {
                if (typeof enabled !== 'boolean') { throw typeError('enabled must be a boolean'); }
                return request('proxy.set', { key: 'enabled', value: enabled });
            },
            setStableCalls: function (enabled) {
                if (typeof enabled !== 'boolean') { throw typeError('enabled must be a boolean'); }
                return request('proxy.set', { key: 'stableCalls', value: enabled });
            },
            refresh: function () { return request('proxy.refresh', {}); },
            startAutoSwitch: function () { return request('proxy.autoSwitch', { enabled: true }); },
            stopAutoSwitch: function () { return request('proxy.autoSwitch', { enabled: false }); }
        });

        var accountsApi = freeze({
            list: function () { return request('accounts.list', {}); },
            switchTo: function (accountId) {
                var id = toPeerId(accountId);
                if (id === 'me') { throw typeError('accountId must be a decimal identifier'); }
                return request('accounts.switch', { accountId: id });
            }
        });

        // The plugin's own files. `storage` is one bucket read and written whole, so a plugin
        // keeping anything sizeable there rewrites all of it on every change; this is the
        // other shape. The directory belongs to the plugin and goes when the plugin does.
        var filesApi = freeze({
            writeText: function (name, text) {
                return request('files.write', { name: requireString(name, 'name'), text: requireString(text, 'text') });
            },
            readText: function (name) { return request('files.read', { name: requireString(name, 'name') }); },
            writeJSON: function (name, value) {
                return request('files.write', {
                    name: requireString(name, 'name'),
                    text: JSON.stringify(value === undefined ? null : value)
                });
            },
            readJSON: function (name, fallback) {
                var alternative = fallback === undefined ? null : fallback;
                return request('files.read', { name: requireString(name, 'name') }).then(function (text) {
                    if (typeof text !== 'string') { return alternative; }
                    // A file a plugin wrote by hand, or truncated by a crash, is not a reason
                    // to reject: the caller asked for a value and named what to use instead.
                    try { return JSON.parse(text); } catch (error) { return alternative; }
                });
            },
            append: function (name, text) {
                requireString(name, 'name');
                requireString(text, 'text');
                return request('files.read', { name: name }).then(function (current) {
                    return request('files.write', { name: name, text: (typeof current === 'string' ? current : '') + text });
                });
            },
            exists: function (name) {
                return request('files.info', { name: requireString(name, 'name') }).then(function (info) { return info !== null; });
            },
            info: function (name) { return request('files.info', { name: requireString(name, 'name') }); },
            list: function () { return request('files.list', {}); },
            remove: function (name) { return request('files.remove', { name: requireString(name, 'name') }); },
            clear: function () { return request('files.clear', {}); },
            usage: function () { return request('files.usage', {}); },
            // The person picks the file and the app copies it into the plugin's own
            // directory. A plugin never reaches into anybody's documents; it is handed one
            // file, by name, the same as one it wrote itself.
            pick: function () { return request('files.pick', {}); },
            share: function (name) { return request('files.share', { name: requireString(name, 'name') }); }
        });

        // Words the app draws, replaced. The whole set is republished on every change, so
        // removing one override is publishing the rest — the same shape as the other things
        // a plugin registers.
        var stringOverrides = {};
        function publishStrings() {
            if (!host.stringsDefine(JSON.stringify(stringOverrides))) {
                throw new Error('App customization permission is not granted');
            }
        }
        var stringsApi = freeze({
            override: function (key, value) {
                requireString(key, 'key');
                requireString(value, 'value');
                var previous = stringOverrides[key];
                stringOverrides[key] = value;
                try {
                    publishStrings();
                } catch (error) {
                    if (previous === undefined) { delete stringOverrides[key]; } else { stringOverrides[key] = previous; }
                    throw error;
                }
            },
            restore: function (key) {
                requireString(key, 'key');
                if (!stringOverrides.hasOwnProperty(key)) { return false; }
                delete stringOverrides[key];
                publishStrings();
                return true;
            },
            restoreAll: function () {
                var count = Object.keys(stringOverrides).length;
                if (count === 0) { return 0; }
                stringOverrides = {};
                publishStrings();
                return count;
            },
            all: function () { return freeze(JSON.parse(JSON.stringify(stringOverrides))); }
        });

        // Plugins talking to each other, through the app. A message carries the sender's id,
        // so a plugin always knows who is talking to it, and topics are filtered here rather
        // than making every plugin do it.
        var pluginTopics = {};
        function pluginMessageReceived(event) {
            if (!event || typeof event.topic !== 'string') { return; }
            var list = pluginTopics[event.topic];
            if (!list) { return; }
            var snapshot = list.slice();
            for (var i = 0; i < snapshot.length; i++) {
                try {
                    snapshot[i](event);
                } catch (error) {
                    reportError('Handler for plugin topic \\'' + event.topic + '\\' failed', error);
                }
            }
        }
        var pluginsApi = freeze({
            emit: function (topic, payload) {
                requireString(topic, 'topic');
                if (!host.pluginBroadcast(topic, JSON.stringify(payload === undefined ? null : payload))) {
                    throw new Error('Plugin messaging permission is not granted');
                }
            },
            on: function (topic, handler) {
                requireString(topic, 'topic');
                requireFunction(handler, 'handler');
                if (!pluginTopics.hasOwnProperty(topic)) { pluginTopics[topic] = []; }
                pluginTopics[topic].push(handler);
                return function () {
                    var list = pluginTopics[topic] || [];
                    for (var i = list.length - 1; i >= 0; i--) {
                        if (list[i] === handler) { list.splice(i, 1); }
                    }
                };
            },
            // A fresh array, not a frozen one. `Object.keys` already builds a copy, and
            // freezing it only means the caller cannot sort or filter what it was given —
            // which is what anyone does with a list of topics.
            topics: function () { return Object.keys(pluginTopics); }
        });

        function moderate(action, userPeerId, options) {
            var user = toPeerId(userPeerId);
            if (user === 'me') { throw typeError('userPeerId must identify a person'); }
            var opts = optionalObject(options, 'options');
            var chat = opts.chatPeerId === undefined ? null : toPeerId(opts.chatPeerId);
            if (chat === null || chat === 'me') { throw typeError('options.chatPeerId must identify a group'); }
            return request('moderation.' + action, { chatPeerId: chat, userPeerId: user });
        }

        // The chat that is open right now. Everything here answers while a chat is on screen
        // and rejects the moment none is, which is what "the current chat" means: there is no
        // last one to fall back on, and pretending otherwise would write a draft into a chat
        // nobody is looking at.
        var chatApi = freeze({
            current: function () { return request('chat.current', {}); },
            draft: function () { return request('chat.draft', {}); },
            setDraft: function (text) { return request('chat.setDraft', { text: requireString(text, 'text'), mode: 'set' }); },
            insert: function (text) { return request('chat.setDraft', { text: requireString(text, 'text'), mode: 'insert' }); },
            clear: function () { return request('chat.setDraft', { text: '', mode: 'clear' }); },
            messages: function (options) {
                var opts = optionalObject(options, 'options');
                var limit = opts.limit === undefined ? 50 : Number(opts.limit);
                if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
                    throw new RangeError('limit must be between 1 and 100');
                }
                return request('chat.messages', { limit: limit });
            },
            setTyping: function (enabled) {
                if (typeof enabled !== 'boolean') { throw typeError('enabled must be a boolean'); }
                return request('chat.setTyping', { enabled: enabled });
            },
            markRead: function () { return request('chat.markRead', {}); },
            scrollTo: function (message) {
                var id = (message !== null && typeof message === 'object') ? message.id : message;
                id = Number(id);
                if (!Number.isSafeInteger(id) || id <= 0) { throw typeError('message must be a message or a message id'); }
                return request('chat.scrollTo', { messageId: id });
            }
        });

        var telegramProxyApi = freeze({
            status: function () { return request('telegramProxy.status', {}); },
            setEnabled: function (enabled) {
                if (typeof enabled !== 'boolean') { throw typeError('enabled must be a boolean'); }
                return request('telegramProxy.setEnabled', { enabled: enabled });
            },
            setUseForCalls: function (enabled) {
                if (typeof enabled !== 'boolean') { throw typeError('enabled must be a boolean'); }
                return request('telegramProxy.setUseForCalls', { enabled: enabled });
            },
            add: function (server) {
                var value = optionalObject(server, 'server');
                var type = requireString(value.type, 'server.type').toLowerCase();
                var hostName = requireString(value.host, 'server.host').trim();
                var port = Number(value.port);
                if (type !== 'socks5' && type !== 'mtp') { throw new Error('server.type must be socks5 or mtp'); }
                if (!hostName || hostName.length > 253) { throw new Error('server.host is invalid'); }
                if (!Number.isSafeInteger(port) || port < 1 || port > 65535) { throw new RangeError('server.port must be between 1 and 65535'); }
                return request('telegramProxy.add', {
                    type: type,
                    host: hostName,
                    port: port,
                    username: typeof value.username === 'string' ? value.username : null,
                    password: typeof value.password === 'string' ? value.password : null,
                    secret: typeof value.secret === 'string' ? value.secret : null
                });
            },
            remove: function (index) {
                index = Number(index);
                if (!Number.isSafeInteger(index) || index < 0) { throw new RangeError('index must be a non-negative integer'); }
                return request('telegramProxy.remove', { index: index });
            },
            select: function (index) {
                if (index === null) { return request('telegramProxy.select', { index: null }); }
                index = Number(index);
                if (!Number.isSafeInteger(index) || index < 0) { throw new RangeError('index must be null or a non-negative integer'); }
                return request('telegramProxy.select', { index: index });
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
                    var payload = textPayload(text);
                    var opts = optionalObject(options, 'options');
                    return request('messages.send', {
                        peerId: target === 'me' ? null : target,
                        toSelf: target === 'me',
                        text: payload.text,
                        entities: payload.entities,
                        replyTo: typeof opts.replyTo === 'number' ? opts.replyTo : null,
                        accountId: (typeof opts.accountId === 'string' && /^-?\\d+$/.test(opts.accountId)) ? opts.accountId : (typeof opts.accountId === 'number' && Number.isSafeInteger(opts.accountId) ? String(opts.accountId) : null)
                    });
                },
                edit: function (message, text) {
                    var ref = messageReference(message);
                    ref.text = requireString(text, 'text');
                    return request('messages.edit', ref);
                },
                delete: function (message, options) {
                    var ref = messageReference(message);
                    var opts = optionalObject(options, 'options');
                    ref.forEveryone = !!opts.forEveryone;
                    return request('messages.delete', ref);
                },
                forward: function (message, destinationPeerId) {
                    var ref = messageReference(message);
                    var target = toPeerId(destinationPeerId);
                    if (target === 'me') { throw typeError('toPeerId must identify a chat'); }
                    ref.toPeerId = target;
                    return request('messages.forward', ref);
                },
                react: function (message, reaction) {
                    var ref = messageReference(message);
                    if (reaction !== null) { requireString(reaction, 'reaction'); }
                    ref.reaction = reaction;
                    return request('messages.react', ref);
                },
                // Removes it from this device only. The other side keeps theirs, which is
                // the whole difference from `delete` and the reason it is its own call.
                deleteLocal: function (message) {
                    return request('messages.deleteLocal', messageReference(message));
                },
                visible: function (options) { return chatApi.messages(options); },
                current: function () { return chatApi.current(); }
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
                history: function (peerId, options) {
                    var target = toPeerId(peerId);
                    var opts = optionalObject(options, 'options');
                    var limit = opts.limit === undefined ? 50 : Number(opts.limit);
                    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
                        throw new RangeError('limit must be between 1 and 100');
                    }
                    return request('chats.history', { peerId: target === 'me' ? null : target, toSelf: target === 'me', limit: limit });
                },
                open: function (peerId) {
                    var target = toPeerId(peerId);
                    return request('chats.open', { peerId: target === 'me' ? null : target, toSelf: target === 'me' });
                }
            }),
            chat: chatApi,
            files: filesApi,
            // The same object as the global `console`. Both spellings are in the contract,
            // and a plugin that reaches for the one that was missing got a TypeError in the
            // middle of its own start handler with nothing to say why.
            console: console,
            strings: stringsApi,
            plugins: pluginsApi,
            // A message's attachment: what it is, and the four things anyone ever wants to
            // do with one. `selected` is the message a context action was invoked on, which
            // the plugin already has — it is here because the contract names it.
            media: freeze({
                info: function (message) { return request('media.info', messageReference(message)); },
                forMessage: function (message) { return request('media.info', messageReference(message)); },
                selected: function (message) { return request('media.info', messageReference(message)); },
                download: function (message) { return request('media.download', messageReference(message)); },
                save: function (message) { return request('media.save', messageReference(message)); },
                saveToFiles: function (message) { return request('media.saveToFiles', messageReference(message)); },
                share: function (message) { return request('media.share', messageReference(message)); }
            }),
            // Acting on somebody in a group. The app asks first, and Telegram's own rights
            // decide: without them the answer is `{ ok: false }` rather than an error,
            // because "you are not an admin" is an answer to the question.
            moderation: freeze({
                ban: function (userPeerId, options) { return moderate('ban', userPeerId, options); },
                kick: function (userPeerId, options) { return moderate('kick', userPeerId, options); },
                restrict: function (userPeerId, options) { return moderate('restrict', userPeerId, options); },
                unban: function (userPeerId, options) { return moderate('unban', userPeerId, options); }
            }),
            // Someone, rather than a conversation. `chats.get` answers about a chat; this
            // answers about a person, which is the same lookup and a different question.
            users: freeze({
                me: function () { return request('account.current', {}); },
                get: function (peerId) {
                    var target = toPeerId(peerId);
                    if (target === 'me') { return request('account.current', {}); }
                    return request('users.get', { peerId: target });
                },
                resolve: function (username) {
                    return request('users.get', { username: requireString(username, 'username').replace(/^@/, '') });
                },
                search: function (query, options) {
                    var opts = optionalObject(options, 'options');
                    var limit = opts.limit === undefined ? 20 : Number(opts.limit);
                    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) {
                        throw new RangeError('limit must be between 1 and 50');
                    }
                    return request('users.search', { query: requireString(query, 'query'), limit: limit });
                },
                // The person chooses. A plugin that needs to know who to act on asks the app
                // to ask, instead of being handed the address book.
                select: function (options) {
                    var opts = optionalObject(options, 'options');
                    return request('users.pick', { title: typeof opts.title === 'string' ? opts.title : null });
                }
            }),
            navigation: freeze({
                openChat: function (peerId) {
                    var target = toPeerId(peerId);
                    return request('chats.open', { peerId: target === 'me' ? null : target, toSelf: target === 'me' });
                },
                openProfile: function (peerId) {
                    var target = toPeerId(peerId);
                    if (target === 'me') { throw typeError('peerId must identify a person or a chat'); }
                    return request('navigation.openProfile', { peerId: target });
                },
                openUrl: function (url) { return request('browser.open', { url: requireString(url, 'url') }); },
                openTelegramLink: function (url) { return request('telegram.openLink', { url: requireString(url, 'url') }); },
                openSettings: function (section) {
                    return request('navigation.openSettings', { section: section === undefined ? null : requireString(section, 'section') });
                }
            }),
            // What this plugin is, and what it may do. A plugin that can ask stops having to
            // call something and read the refusal to find out whether it is allowed to.
            runtime: freeze({
                pluginId: info.id,
                apiVersion: '\(apiVersion)',
                permissions: function () { return freeze(host.grantedPermissions()); },
                hasPermission: function (name) { return host.hasPermission(requireString(name, 'name')); }
            }),
            theme: freeze({
                current: function () { return request('theme.current', {}); },
                setAccentColor: function (color) {
                    return request('theme.setAccent', { color: requireString(color, 'color') });
                },
                resetAccentColor: function () { return request('theme.setAccent', { color: null }); }
            }),
            account: freeze({
                current: function () { return request('account.current', {}); }
            }),
            accounts: accountsApi,
            features: featureApi,
            interface: interfaceApi,
            tabs: tabsApi,
            avatars: avatarsApi,
            wall: wallApi,
            proxy: proxyApi,
            telegramProxy: telegramProxyApi,
            telegram: freeze({
                openLink: function (url) { return request('telegram.openLink', { url: requireString(url, 'url') }); }
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
                },
                addFloatingButton: function (config, handler) { return addOverlay('floatingButton', config, handler); },
                updateFloatingButton: function (id, config) { return updateOverlay('floatingButton', id, config); },
                removeFloatingButton: removeOverlay,
                addChatPanel: function (config, handler) { return addOverlay('chatPanel', config, handler); },
                updateChatPanel: function (id, config) { return updateOverlay('chatPanel', id, config); },
                removeChatPanel: removeOverlay,
                // A strip directly above the composer. The same data as a panel; the
                // difference is only where it sits.
                addInputAccessory: function (config, handler) { return addOverlay('inputAccessory', config, handler); },
                updateInputAccessory: function (id, config) { return updateOverlay('inputAccessory', id, config); },
                removeInputAccessory: removeOverlay,
                overlays: function () { return freeze(JSON.parse(JSON.stringify(overlays))); },
                // A word in the chat's title bar. One at a time across every plugin: two
                // labels stacked there would leave a chat nobody can read the name of.
                addChatListHeaderButton: function (config, handler) { return addNativeButton('chatListHeader', config, handler); },
                removeChatListHeaderButton: removeNativeButton,
                nativeButtons: function () { return freeze(JSON.parse(JSON.stringify(nativeButtons))); },
                setChatHeaderBadge: function (text, color) {
                    requireString(text, 'text');
                    if (color !== undefined && color !== null) { requireString(color, 'color'); }
                    if (!host.headerBadge(text, color === undefined ? null : color)) {
                        throw new Error('Custom UI permission is not granted');
                    }
                },
                clearChatHeaderBadge: function () {
                    if (!host.headerBadge(null, null)) {
                        throw new Error('Custom UI permission is not granted');
                    }
                },
                removeAllOverlays: removeAllOverlays,
                showSheet: function (options) {
                    var opts = typeof options === 'string' ? { text: options } : optionalObject(options, 'options');
                    return request('ui.alert', {
                        title: typeof opts.title === 'string' ? opts.title : '',
                        text: typeof opts.text === 'string' ? opts.text : null,
                        ok: typeof opts.buttonTitle === 'string' ? opts.buttonTitle : null
                    });
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
                },
                // Whether the app is in front, and whether it is behind the lock. A plugin
                // with a timer wants to know before it draws something nobody can see.
                state: function () { return request('app.state', {}); },
                openSettings: function (section) {
                    return request('navigation.openSettings', { section: section === undefined ? null : requireString(section, 'section') });
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
                    return request('ai.ask', { prompt: requireString(prompt, 'prompt'), history: history, threadId: opts.threadId || null }, opts.onEvent);
                },
                openArtifact: function (artifactId) {
                    return request('ai.openArtifact', { artifactId: requireString(artifactId, 'artifactId') });
                }
            }),
            text: textApi,
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
            requestEvent: requestEvent,
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
