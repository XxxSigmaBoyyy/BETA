# AorusGram Plugins — полный справочник

Плагин AorusGram — это **один файл JavaScript**, который выполняется в собственном
изолированном контексте JavaScriptCore. Весь доступ к приложению идёт через один
замороженный объект `aorus`; ничего другого из приложения в контекст не попадает.

Документ описывает то, что есть в сборке, метод за методом. Если чего-то нет здесь —
значит этого нет и в API.

## Содержание

1. [Как это устроено](#1-как-это-устроено)
2. [Быстрый старт](#2-быстрый-старт)
3. [Жизненный цикл](#3-жизненный-цикл)
4. [Разрешения](#4-разрешения)
5. [События](#5-события)
6. [Команды в чате](#6-команды-в-чате)
7. [Перехват исходящих](#7-перехват-исходящих)
8. [Сообщения](#8-сообщения)
9. [Чаты](#9-чаты)
9a. [Открытый чат](#9a-открытый-чат)
10. [Аккаунты](#10-аккаунты)
11. [Нативные экраны](#11-нативные-экраны)
11a. [Кнопки и панели поверх чата](#11a-кнопки-и-панели-поверх-чата)
12. [Форматированный текст](#13a-форматированный-текст)
12. [Интеграции: настройки и контекстное меню](#12-интеграции-настройки-и-контекстное-меню)
13. [Настройки плагина](#13-настройки-плагина)
14. [Хранилище](#14-хранилище)
14a. [Файлы](#14a-файлы)
14b. [Тема](#14b-тема)
15. [Сеть](#15-сеть)
16. [AorusAI](#16-aorusai)
17. [Интерфейс приложения](#17-интерфейс-приложения)
18. [Соединение и прокси](#18-соединение-и-прокси)
19. [Прочее: буфер, крипто, таймеры, консоль](#19-прочее-буфер-крипто-таймеры-консоль)
20. [Диагностика: почему мой плагин не работает](#20-диагностика-почему-мой-плагин-не-работает)
21. [Ограничения](#21-ограничения)
22. [Примеры](#22-примеры)

---

## 1. Как это устроено

У каждого плагина свои `JSVirtualMachine`, `JSContext` и последовательная очередь. Это
значит: один плагин не видит объектов другого, утечка памяти в плагине остаётся в его
собственной куче, и весь JavaScript одного плагина выполняется на одном потоке, который он
ни с кем не делит.

Перед кодом плагина выполняется прелюдия. Она получает единственный объект `__aorusHost`,
члены которого — блоки Swift, строит поверх них публичный API `aorus`, публикует `aorus`,
`console` и четыре функции таймеров как неперезаписываемые глобальные значения, замораживает
всё опубликованное и удаляет `__aorusHost` из глобальной области. После этого единственный
путь из кода плагина в приложение — через замороженный API, и каждый вызов в нём — один из
блоков Swift с уже приведёнными и проверенными аргументами.

JavaScriptCore сам по себе не имеет доступа к файлам, сети и процессам. Поэтому **набор
блоков и есть полный список того, что плагин может сделать**.

Время одного входа в JavaScript ограничено тремя секундами. Если система не даёт установить
этот предел, не запускается ни один плагин — и экран диагностики говорит об этом прямо.

## 2. Быстрый старт

`Настройки → AorusGram → Плагины → +`. Пишете код, **Сохранить**, затем включаете
переключатель и подтверждаете разрешения.

```js
aorus.on('start', function () {
    console.log('Плагин запущен');
});

aorus.commands.register('hello', function (args, context) {
    return 'Привет! ' + (args || '');
}, { description: 'Отвечает приветствием', usage: '.hello [текст]' });
```

Отправьте `.hello мир` в любом чате — текст в поле ввода заменится на ответ команды.

> **Важно.** Сохранение изменённого кода отзывает выданные разрешения и выключает плагин —
> разрешения выдавались коду, которого больше нет. Редактор говорит об этом и предлагает
> кнопку «Разрешить и включить». Пока вы её не нажали, плагин не работает.

## 3. Жизненный цикл

| Момент | Что происходит |
|---|---|
| Включение переключателя | Показывается лист разрешений; после согласия создаётся контекст, выполняется прелюдия, затем код плагина, затем приходит событие `start`. |
| Запуск приложения | Плагины с включённым автозапуском стартуют, когда появляется аккаунтный рантайм. |
| Сохранение кода | Плагин останавливается, разрешения отзываются, переключатель выключается. |
| Выключение переключателя | Приходит `stop`, контекст уничтожается, таймеры и запросы отменяются. |
| Смена аккаунта | Все плагины останавливаются и перезапускаются под новым аккаунтом. |

Состояние между запусками — только `aorus.storage`.

## 4. Разрешения

Разрешение запрашивается тем, что **написано в исходнике**. Сканер ищет конкретные вызовы;
найденные складываются в лист согласия, и плагин не запускается, пока выданное не покрывает
запрошенное. Во время выполнения каждый вызов проверяется ещё раз — сканер только строит
лист, решает всегда рантайм.

| Разрешение | Что открывает | По какому вызову запрашивается |
|---|---|---|
| `network` | HTTP-запросы | `aorus.http` |
| `sendMessages` | Отправка сообщений | `aorus.messages.send` |
| `manageMessages` | Правка, удаление, пересылка, реакции | `aorus.messages.edit/delete/forward/react` |
| `messageHistory` | Чтение истории чата | `aorus.chats.history` |
| `chatMetadata` | Название и идентификатор чата, что видно на экране | `aorus.chats.resolve`, `aorus.chats.get`, `aorus.chat.current`, `aorus.chat.messages` |
| `composer` | Поле ввода открытого чата: чтение, запись, статус печати, прокрутка | `aorus.chat.draft/setDraft/insert/clear/setTyping/markRead/scrollTo`, `aorus.on('inputChanged'…)` |
| `openChats` | Открытие чатов и ссылок Telegram | `aorus.chats.open`, `aorus.app.openChat`, `aorus.telegram.openLink` |
| `accountProfile` | Имя и идентификатор текущего аккаунта | `aorus.account.current`, `aorus.app.currentAccount` |
| `accountSwitching` | Список аккаунтов и переключение | `aorus.accounts.` |
| `dialogs` | Тосты, алерты, подтверждения, ввод, share | `aorus.ui.toast/alert/confirm/prompt/share` |
| `clipboardRead` / `clipboardWrite` | Буфер обмена | `aorus.clipboard.read` / `.write` |
| `incomingMessages` | События входящих, удалённых, изменённых | `aorus.on('message'…)` и родственные |
| `outgoingMessages` | Команды и перехват исходящего текста | `aorus.commands`, `aorus.on('send'…)` |
| `customUI` | Собственные экраны, кнопки и панели поверх чата | `aorus.ui.definePages/createPage/openPage/presentPage`, `aorus.ui.addFloatingButton`, `aorus.ui.addChatPanel` |
| `settingsIntegration` | Ярлык в настройках | `aorus.integrations.settings.register` |
| `contextMenu` | Действие в меню сообщения | `aorus.integrations.contextMenu.register` |
| `inAppBrowser` | Открытие сайтов во встроенном браузере | `aorus.browser.open`, `aorus.ui.openURL`, строки с ссылками |
| `artificialIntelligence` | Запросы к AorusAI | `aorus.ai.` |
| `appCustomization` | Флаги интерфейса, вкладки, аватары, стена | `aorus.features.`, `aorus.interface.`, `aorus.tabs.`, `aorus.avatars.`, `aorus.wall.` |
| `connectionControl` | Состояние соединения AorusGram | `aorus.proxy.` |
| `telegramProxy` | Список и переключение прокси Telegram | `aorus.telegramProxy.` |

Отказ выдать разрешение не ломает приложение: вызов возвращает ошибку с названием
недостающего разрешения, и она видна в консоли плагина.

## 5. События

```js
var off = aorus.on('message', function (event) { /* … */ });
off();                       // отписаться
aorus.once('start', fn);     // один раз
aorus.off('message', fn);    // снять конкретный обработчик
```

| Событие | Когда | Полезная нагрузка |
|---|---|---|
| `start` | Код плагина выполнен | — |
| `stop` | Плагин останавливается | — |
| `message` | Пришло входящее сообщение | `accountId`, `peerId`, `senderId`, `msgId`, `msgNs`, `peerKind`, `text`, `date` |
| `messageDeleted` | Сообщение удалено | идентификаторы сообщения |
| `messageEdited` | Сообщение изменено | идентификаторы и новый текст |
| `send` | Перед отправкой исходящего текста | `{ text, peerId, accountId }` |
| `foreground` / `background` | Приложение вышло на экран или ушло | — |
| `settingsChanged` | Пользователь поменял настройку плагина | все значения |
| `settings.changed` | Изменена одна настройка из секции | `{ key, value }` |
| `settings.action` | Нажата кнопка в секции настроек | `{ key }` |
| `settings.reset` | Настройки плагина сброшены | — |
| `appSettingsChanged` | Изменился флаг интерфейса приложения | `{ key, value }` |
| `connectionChanged` | Изменилось состояние соединения | состояние |
| `uiAction` | Взаимодействие со строкой нативного экрана | `{ pageId, rowId, value }` |
| `contextAction` | Выбрано действие в меню сообщения | `{ actionId, peerId, namespace, messageId, text, source }` |
| `overlayAction` | Нажата кнопка или панель поверх чата | `{ id, peerId }` |
| `chatOpened` | Чат появился на экране | `{ peerId, title, kind, threadId }` |
| `chatClosed` | Чат ушёл с экрана | `{ peerId }` |
| `inputChanged` | Изменился текст в поле ввода | `{ peerId, text, source }` |

Обработчик, который бросил исключение или вернул отклонённый промис, не ломает остальные:
ошибка попадает в консоль плагина с указанием события.

## 6. Команды в чате

```js
aorus.commands.setPrefix('.');           // 1–3 символа, без букв, цифр и пробелов
aorus.commands.register('note', function (args, context) {
    // context: { peerId, accountId, raw, command }
    return 'записал: ' + args;           // строка заменяет введённый текст
}, { description: 'Заметка', usage: '.note <текст>' });

aorus.commands.list();                   // [{ name, description, usage }]
```

Что возвращает обработчик:

- **строка** — заменяет введённый текст, сообщение уходит;
- **`false` или ничего** — команда поглощена, сообщение не отправляется;
- **промис** — команда поглощается сразу, а когда промис завершится строкой, она уходит
  отдельным сообщением.

Требует `outgoingMessages`. Каждая обработанная команда пишет строку в консоль плагина.

## 7. Перехват исходящих

```js
aorus.on('send', function (event) {
    if (event.text === 'stop') { return false; }     // не отправлять
    return event.text.replace(/teh/g, 'the');        // заменить текст
});
```

Перехват синхронный и выполняется до отправки. На все плагины вместе отведено 100 мс: тот,
кто не успел, пропускается, его текст уходит без изменений, а сам плагин **на 20 секунд
исключается из этого пути** и затем пробуется снова. События при этом продолжают приходить —
таймаут в синхронном перехвате не значит, что плагин сломан.

В перехват попадает только обычный текст, написанный человеком: подписи к медиа, пересылки,
служебные и фоновые отправки проходят мимо.

## 8. Сообщения

```js
await aorus.messages.send(peerId, 'текст', { replyTo: 123, accountId: '…' });
await aorus.messages.edit(ref, 'новый текст');
await aorus.messages.delete(ref, { forEveryone: false });
await aorus.messages.forward(ref, targetPeerId);
await aorus.messages.react(ref, '🔥');
```

`ref` — ссылка на сообщение: `{ peerId, namespace, messageId }`. Именно в таком виде
идентификаторы приходят в событиях `message` и `contextAction`, так что ссылку не нужно
собирать руками.

`send` требует `sendMessages`, остальные — `manageMessages`. `peerId` — десятичная строка
или `'me'` для «Избранного».

## 9. Чаты

```js
const chat = await aorus.chats.resolve('@durov');   // { id, title }
const info = await aorus.chats.get(peerId);        // { id, title }
await aorus.chats.open(peerId);                    // открыть чат
const items = await aorus.chats.history(peerId, { limit: 50 });
await aorus.telegram.openLink('tg://resolve?domain=telegram');
```

`history` отдаёт массив сообщений с текстом, автором, датой и ссылкой `ref`, пригодной для
`messages.*`. Требует `messageHistory`.

## 9a. Открытый чат

`aorus.chats.*` адресует чат по идентификатору. `aorus.chat.*` — это тот чат, который прямо
сейчас на экране, и ничего больше.

```js
const chat = await aorus.chat.current();   // { peerId, title, kind, threadId } или null
const text = await aorus.chat.draft();     // что набрано и не отправлено
await aorus.chat.setDraft('готовый ответ');
await aorus.chat.insert(' и ещё немного');
await aorus.chat.clear();
const visible = await aorus.chat.messages({ limit: 30 });
await aorus.chat.setTyping(true);
await aorus.chat.markRead();
await aorus.chat.scrollTo(messageId);      // или scrollTo(message)
```

`kind` — одно из `user`, `bot`, `group`, `channel`, `secret`, `community`. `threadId` есть
только в теме форума.

Когда открытого чата нет, `current()` отвечает `null` — это факт, который плагину нужен, —
а любой вызов, который что-то делает с чатом, отклоняется с сообщением `No chat is open`.
Последний открытый чат не подставляется: писать черновик в чат, на который никто не смотрит,
хуже, чем отказать.

`messages` отдаёт то, что видно на экране, в том же виде, что и `chats.history`: новые в
конце. Это не история — прокрутка меняет ответ.

Событие `inputChanged` приходит на каждое изменение текста и несёт `source`: `user` — набрал
человек, `plugin` — записал сам плагин. Это нужно, чтобы плагин, который отвечает на ввод
записью в поле, не гонял сам себя по кругу:

```js
aorus.on('inputChanged', function (event) {
    if (event.source !== 'user') { return; }
    if (event.text === ':shrug') { aorus.chat.setDraft('¯\\_(ツ)_/¯'); }
});
```

Чтение чата — `chatMetadata`, работа с полем ввода — `composer`. Это разные разрешения:
название чата и то, что человек набрал, но ещё не отправил, — разные вещи. Отправку
сообщений `composer` не даёт, для неё нужен `sendMessages`.

## 10. Аккаунты

```js
const me = await aorus.account.current();     // { id, title }
const all = await aorus.accounts.list();      // [{ id, title, isCurrent }]
await aorus.accounts.switchTo(id);
```

## 11. Нативные экраны

Экран описывается данными; все вью и вся навигация строятся приложением. Ни один объект
UIKit и ни один селектор в JavaScript не передаются.

```js
const page = aorus.ui.createPage({ id: 'main', title: 'Помощник' });
page.section({ title: 'Ответ', footer: 'Подсказка внизу секции' })
    .toggle({ id: 'enabled', title: 'Включено', value: true })
    .multiline({ id: 'prompt', title: 'Запрос', value: '' })
    .slider({ id: 'tone', title: 'Тон', min: 0, max: 10, step: 1, value: 5 })
    .stepper({ id: 'count', title: 'Сколько', min: 1, max: 20, step: 1, value: 3 })
    .select({ id: 'mode', title: 'Режим', value: 'fast',
              options: [{ value: 'fast', title: 'Быстро' }, { value: 'slow', title: 'Точно' }] })
    .link({ id: 'docs', title: 'Документация', url: 'https://example.com' })
    .button({ id: 'run', title: 'Запустить', icon: 'bolt.fill', destructive: false })
    .end()
    .publish();

await page.open({ style: 'sheet' });    // 'push' | 'sheet' | 'fullScreen'
page.update('prompt', 'новое значение');
```

Типы строк: `text`, `button`, `toggle`, `input`, `multiline`, `number`, `select`, `link`,
`slider`, `stepper`.

Взаимодействие приходит событием `uiAction` с `{ pageId, rowId, value }`. Строка `link`
открывается во встроенном браузере и требует `inAppBrowser`.

Границы: до 12 экранов, 16 секций на экран, 32 строки в секции и 128 строк всего;
идентификаторы — латиница, цифры, `_`, `.`, `-`, до 64 символов, и они должны быть
уникальными. Ссылка принимает только `http` и `https`, а адрес проверяется перед открытием:
loopback, локальная сеть и служебные домены AorusGram отклоняются.

## 11a. Кнопки и панели поверх чата

```js
const button = aorus.ui.addFloatingButton(
    { title: 'Перевести', icon: 'globe', backgroundColor: '#0A84FF', position: 'bottomRight', offsetY: -120, draggable: true },
    () => aorus.chat.setDraft(translate(aorus.chat.draft()))
);
aorus.ui.updateFloatingButton(button, { title: 'Готово', backgroundColor: '#30D158' });
aorus.ui.removeFloatingButton(button);

const panel = aorus.ui.addChatPanel({ title: 'Идёт запись', subtitle: 'нажмите, чтобы остановить' }, stop);
aorus.ui.updateChatPanel(panel, { subtitle: 'остановлено' });
aorus.ui.removeChatPanel(panel);

aorus.ui.overlays();          // что сейчас нарисовано
aorus.ui.removeAllOverlays(); // снять всё сразу
```

Поля: `title`, `subtitle` (только панель), `icon` (SF Symbol), `backgroundColor`, `textColor`,
`borderColor`, `borderWidth`, `cornerRadius`, `alpha`, `fontSize`, `shadow`, `displayMode`
(`icon` / `text` / `iconText`), `position` (`topLeft`, `topRight`, `bottomLeft`, `bottomRight`,
`centerLeft`, `centerRight`, `center` — регистр не важен), `offsetX`, `offsetY`, `width`,
`height`, `draggable`, `interactive`.

Числа **ограничиваются, а не отклоняются**: ширина 900 станет 220, `alpha: 4` станет `1`.
Плагин, который просит кнопку в пол-экрана, ошибся, а не нападает, и полезный ответ — самая
большая кнопка, которая всё ещё помещается. Отклоняется только то, что нельзя нарисовать:
кнопка без текста и без иконки — это невидимая зона нажатия, и `add` в этом случае бросает
ошибку, а не возвращает id того, чего нет.

Обработчик передаётся прямо в `add`, поэтому плагину с несколькими кнопками не нужно
разбирать поток событий. Событие `overlayAction` при этом тоже приходит — если так удобнее.

До четырёх элементов на плагин. Живут, пока открыт чат: панели встают под шапкой в порядке
регистрации, кнопки — по своей позиции, с `draggable` их можно перетащить и позиция
запомнится на время сессии. Всё, что не попало по элементу, проходит насквозь в чат.

## 12. Интеграции: настройки и контекстное меню

```js
aorus.integrations.settings.register({
    id: 'open-main',
    title: 'Помощник',
    subtitle: 'Настройки плагина',
    icon: 'sparkles',
    pageId: 'main'          // либо url: 'https://…', но не оба сразу
});

aorus.integrations.contextMenu.register({
    id: 'save-note',
    title: 'Сохранить заметку',
    icon: 'note.text'
});
```

Ярлык появляется **и в настройках AorusGram, и в настройках Telegram** — отдельной строкой
с иконкой и цветом плагина, рядом со входом в AorusGram.

Действие контекстного меню появляется в меню сообщения. При выборе приходит событие
`contextAction` с `actionId` и полной ссылкой на сообщение — `peerId`, `namespace`,
`messageId` и текст, так что сразу можно вызвать `aorus.messages.*`. Одновременно
показывается не более четырёх действий от плагинов, чтобы меню помещалось на экране.

## 13. Настройки плагина

```js
aorus.settings.addSection({
    title: 'Основное',
    items: [
        { type: 'toggle', key: 'enabled', title: 'Включено', default: true },
        { type: 'select', key: 'mode', title: 'Режим', default: 'fast',
          options: [{ value: 'fast', title: 'Быстро' }] },
        { type: 'button', key: 'reset', title: 'Сбросить' }
    ]
});

aorus.settings.getPlugin('enabled', true);
aorus.settings.setPlugin('enabled', false);
aorus.settings.toggle('enabled', true);
aorus.settings.all();
```

Секция появляется подэкраном в карточке плагина. Если плагин не объявил ни одной настройки,
строки «Настройки» в карточке просто нет.

## 13a. Форматированный текст

Смещения entity Telegram считает в кодовых единицах UTF-16 — это не то же самое, что число
символов, как только в строке появляется эмодзи. Ошибка в смещении не падает, а сдвигает
форматирование на соседние символы, поэтому смещения лучше не считать руками:

```js
const payload = aorus.text.compose([
    '💎 ', aorus.text.bold('жирный'), ' ',
    aorus.text.link('сайт', 'https://example.com'), ' ',
    aorus.text.customEmoji('🔥', '5234567890'), ' ',
    aorus.text.pre('code()', 'swift')
]);
await aorus.messages.send('me', payload);
```

| Конструктор | Что даёт |
|---|---|
| `text.bold/italic/underline/strikethrough/spoiler/code(t)` | Оформленный кусок |
| `text.pre(t, language?)` | Блок кода |
| `text.blockquote(t, collapsed?)` | Цитата |
| `text.link(t, url)` | Ссылка (только `http`/`https`) |
| `text.customEmoji(t, id)` | Премиум-эмодзи по числовому id |
| `text.compose(parts)` | `{ text, entities }` со всеми смещениями |
| `text.entity(type, offset, length, extra?)` | Явный дескриптор, если считаете сами |

`aorus.messages.send` принимает и строку, и такой объект. Каждая entity проверяется перед
отправкой: диапазон за пределами текста, ссылка не на веб, нечисловой id эмодзи и
неизвестный тип просто отбрасываются — остальное форматирование не сдвигается.

## 14. Хранилище

```js
aorus.storage.set('key', { any: 'json' });
aorus.storage.get('key', fallback);
aorus.storage.remove('key');
aorus.storage.keys();
aorus.storage.clear();
```

Хранилище у каждого плагина своё, на диске рядом с его кодом, до 1 МБ в сериализованном
виде. Запись сверх лимита отклоняется, а не обрезает данные.

## 14a. Файлы

`storage` — одна корзина, которую читают и пишут целиком: плагин, который держит там
что-то объёмное, переписывает её всю на каждое изменение. Файлы — другая форма.

```js
await aorus.files.writeText('notes.txt', 'первая строка');
await aorus.files.append('notes.txt', '\nвторая');
const text = await aorus.files.readText('notes.txt');   // null, если файла нет

await aorus.files.writeJSON('state.json', { count: 3 });
const state = await aorus.files.readJSON('state.json', {});  // второй аргумент — на случай битого файла

await aorus.files.exists('state.json');
await aorus.files.info('state.json');   // { name, size, modified }
await aorus.files.list();               // [{ name, size, modified }, …]
await aorus.files.remove('state.json'); // true, если файл был
await aorus.files.clear();              // сколько удалено
await aorus.files.usage();              // { count, bytes, maximumBytes, maximumFileBytes, maximumCount }
```

Директория своя у каждого плагина, внутри его собственной папки: удаление плагина удаляет
и файлы, осиротеть им негде. Разрешения нет — это его собственное место, как и `storage`.

Лимиты: 4 МБ на файл, 32 МБ на всё, 256 файлов. Перезапись файла чем-то меньшим проходит
всегда, даже когда квота занята: считается то, что будет лежать после записи.

Имя проверяется, а не чинится: до 64 символов, только буквы, цифры, точка, дефис и
подчёркивание, не начинается с точки и не содержит `..`. Имя, которое пришлось бы
исправлять, — это ошибка, и она возвращается вызывающему. Так путь наружу директории
оказывается непредставим, а не отлавливается чистящей функцией.

## 14b. Тема

```js
const theme = await aorus.theme.current();
// { isDark, name, accent, background, groupedBackground, text, secondaryText, destructive }
```

Цвета в виде `"RRGGBB"` — ровно в том виде, в каком их принимает всё остальное. Нужны,
чтобы нативный экран плагина выглядел как часть приложения, а не как вставка. Разрешения
нет: `aorus.device.isDark` был доступен всегда, это тот же факт подробнее.

## 15. Сеть

```js
const res = await aorus.http.fetch('https://api.example.com/v1', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: { hello: 'world' },      // строка или объект
    timeout: 15
});
if (res.ok) { const data = res.json(); }
```

Только `http` и `https`. Перед запросом адрес резолвится, и запрос отклоняется, если имя
ведёт в loopback, локальную сеть, link-local или на служебные домены AorusGram; то же
проверяется заново на каждом перенаправлении. Сессия отдельная, без cookies и кеша.
Ограничения: тело запроса до 2 МБ, ответ до 5 МБ, заголовки из чёрного списка вырезаются.

## 16. AorusAI

```js
const answer = await aorus.ai.ask('Сформулируй ответ', { history: [] });
// { text, artifacts: [{ id, filename, mime, size, format }] }

const chat = aorus.ai.createChat();
await chat.ask('первый вопрос');
await chat.ask('второй, с учётом первого');
chat.messages();
chat.clear();

await aorus.ai.openArtifact(answer.artifacts[0].id);
```

Один запрос на плагин одновременно. Если ответ требует взаимодействия в полноценном чате
AorusAI, запрос завершается с понятным сообщением, а не подвисает.

## 17. Интерфейс приложения

```js
aorus.features.list();  aorus.features.get(key);  await aorus.features.set(key, true);
aorus.interface.list(); aorus.interface.get(key); await aorus.interface.set(key, true);
aorus.tabs.list();      await aorus.tabs.setVisible('wall', true);
await aorus.tabs.setTitlesVisible(false);  await aorus.tabs.setCompact(true);
aorus.avatars.isSquare();  await aorus.avatars.setSquare(true);
aorus.wall.status();       await aorus.wall.setEnabled(true);
```

Всё это — те же переключатели, что и в настройках AorusGram, и меняются они так же живо.
Требует `appCustomization`.

## 18. Соединение и прокси

```js
aorus.proxy.status();           await aorus.proxy.setEnabled(true);
await aorus.proxy.setStableCalls(true);   await aorus.proxy.refresh();

await aorus.telegramProxy.status();
await aorus.telegramProxy.add({ type: 'socks5', host: '…', port: 1080 });
await aorus.telegramProxy.select(id);
await aorus.telegramProxy.remove(id);
await aorus.telegramProxy.setEnabled(true);
await aorus.telegramProxy.setUseForCalls(true);
```

`aorus.proxy` — соединение AorusGram (`connectionControl`), `aorus.telegramProxy` — список
прокси самого Telegram (`telegramProxy`).

## 19. Прочее: буфер, крипто, таймеры, консоль

```js
const text = await aorus.clipboard.read();
aorus.clipboard.write('текст');

aorus.crypto.sha256('текст');
aorus.crypto.hmacSHA256(key, text);
aorus.crypto.randomUUID();
aorus.crypto.randomBytes(32);
aorus.crypto.base64Encode(text);  aorus.crypto.base64Decode(text);

setTimeout(fn, 500);  setInterval(fn, 1000);  clearTimeout(id);  clearInterval(id);
await aorus.util.sleep(250);

console.log('…'); console.info('…'); console.warn('…'); console.error('…'); console.debug('…');
```

До 64 таймеров на плагин. Все они умирают вместе с контекстом.

## 20. Диагностика: почему мой плагин не работает

В карточке плагина есть строка **Состояние** и за ней экран **Диагностика**. Он отвечает на
вопрос прямо:

- работает ли плагин сейчас, и если нет — почему;
- доступна ли на этой системе изоляция выполнения JavaScript;
- жив ли перехват исходящих;
- какие команды зарегистрированы и с каким префиксом;
- какие события слушаются;
- что выдано против того, что просит код.

Рядом — **Консоль**: всё, что плагин пишет через `console`, и всё, что приложение сообщает о
нём: старт, остановка, отказ в разрешении, каждое нажатие на кнопку плагина и каждое
действие контекстного меню. Она обновляется живьём.

Три самые частые причины «ничего не происходит»:

1. **Код сохранён, но плагин не включён заново.** Сохранение отзывает разрешения. Редактор
   говорит об этом и предлагает кнопку.
2. **Нужного разрешения нет.** Сканер ищет вызов буквально: `aorus.ui.toast(...)` он
   находит, а `var t = aorus.ui.toast; t(...)` — нет. Пишите вызовы полностью.
3. **Плагин не запущен.** Строка «Состояние» скажет это первой.

## 21. Ограничения

- Один вход в JavaScript — не дольше трёх секунд.
- Исходник — до 512 КБ, импортируемый файл — до 2 МБ.
- Хранилище и настройки — по 1 МБ на плагин.
- До 32 незавершённых запросов к приложению одновременно.
- Плагин не имеет доступа к файловой системе, Keychain, лицензии, внутренним компонентам
  AorusAI, VLESS и служебным доменам AorusGram.
- Экспорт плагина не содержит ни выданных разрешений, ни настроек: и то и другое
  принадлежит установке, а не коду.

## 22. Примеры

### Заметки по чатам

```js
function key(accountId, peerId) { return 'note:' + accountId + ':' + peerId; }

aorus.commands.register('note', function (args, context) {
    const k = key(context.accountId, context.peerId);
    if (args) {
        aorus.storage.set(k, args);
        aorus.ui.toast('Заметка сохранена');
        return false;
    }
    const saved = aorus.storage.get(k, '');
    aorus.ui.toast(saved || 'Заметки нет');
    return false;
}, { description: 'Заметка к чату', usage: '.note [текст]' });
```

### Экран с кнопкой

```js
const page = aorus.ui.createPage({ id: 'panel', title: 'Панель' });
page.section({ title: 'Действия' })
    .button({ id: 'ping', title: 'Проверить', icon: 'bolt.fill' })
    .end()
    .publish();

aorus.integrations.settings.register({ id: 'open', title: 'Панель', pageId: 'panel' });

aorus.on('uiAction', function (event) {
    if (event.pageId === 'panel' && event.rowId === 'ping') {
        aorus.ui.toast('Работает');
    }
});
```

### Действие в меню сообщения

```js
aorus.integrations.contextMenu.register({ id: 'copy-id', title: 'Скопировать id', icon: 'doc.on.doc' });

aorus.on('contextAction', function (event) {
    if (event.actionId !== 'copy-id') { return; }
    aorus.clipboard.write(event.peerId + '_' + event.messageId);
    aorus.ui.toast('Скопировано');
});
```
