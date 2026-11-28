<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

<h1 align="center">SonyMenu</h1>

<p align="center">Значок в строке меню macOS для наушников Sony WH-1000XM5 / XM6: заряд, шумоподавление, эквалайзер, Speak-to-Chat и остальные настройки Sony, плюс переназначение жестов. Без приложения Sony и без интернета.</p>

<p align="center"><img src="docs/screenshots/panel-dark-ambient.png" width="270" alt="Панель в строке меню"></p>

<p align="center"><a href="#english">English below</a></p>

---

## Что умеет

**Панель в строке меню** (компактная)
- Заряд, зарядка и текущий кодек (AAC, SBC, LDAC).
- **Шумоподавление / Внешний звук / Выключено**, уровень внешнего звука 1–20 и **Фокус на голосе**.
- Переключатель **Автозапуск**.
- По желанию (Настройки → Основные): эквалайзер, DSEE Extreme, Speak-to-Chat и управление музыкой прямо в панели.

**Окно «Настройки»**
- *Основные*: модель, прошивка, качество Bluetooth-соединения, мультипоинт, автовыключение, пауза при снятии, голосовые подсказки, выключение наушников.
- **Микрофон Mac при подключении** (включено по умолчанию): macOS при подключении берёт микрофон наушников, и звук становится глухим моно. SonyMenu возвращает микрофон MacBook, и музыка остаётся в стерео. Программы, которые сами выберут микрофон наушников (звонки), по-прежнему его получат.
- *Звук*: эквалайзер (пресеты и 5 полос + Clear Bass), DSEE Extreme, Speak-to-Chat с чувствительностью и временем.
- *Управление*: сенсорная панель, что переключает левая кнопка NC/AMB, касание с удержанием и **переназначение жестов**: любой жест на наушниках может запускать действие на Mac — предыдущая песня, диктовка (двойной ⌥), сочетание клавиш, открыть приложение и т.д.

Каждая настройка появляется, только если наушники сообщают, что поддерживают её. Интерфейс на русском или английском — по языку системы.

## Установка

1. Скачайте `SonyMenu.zip` со страницы [Releases](../../releases/latest), распакуйте и перетащите `SonyMenu.app` в «Программы».
2. Приложение не подписано сертификатом Apple: при первом запуске откройте **Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»**, или в Терминале:
   ```bash
   xattr -dr com.apple.quarantine /Applications/SonyMenu.app
   ```
3. Разрешите доступ к Bluetooth. Для переназначения жестов понадобится ещё **Универсальный доступ** (приложение попросит само, только если вы включите переназначение).

Нужна **macOS 26 или новее**, Apple Silicon или Intel. Проверено на WH-1000XM5; XM6 должна работать (тот же протокол), XM4 и старше не поддерживаются.

Сборка из исходников: `./build.sh --install` (нужны инструменты разработчика, `xcode-select --install`). Журнал: `~/Library/Logs/SonyMenu.log` — приложите его к [issue](../../issues), если что-то не работает.

Спасибо [@VohidovTohirjon](https://github.com/VohidovTohirjon) за настройки Sony, окно настроек и жесты.

Неофициальный проект, не связан с Sony Group Corporation. Лицензия [MIT](LICENSE).

---

<a id="english"></a>

## English

A macOS menu bar app for Sony WH-1000XM5 headphones: battery, noise cancelling, equalizer, Speak-to-Chat and the rest of Sony's settings, plus remappable gestures. No Sony app, no internet. The UI follows the system language (English or Russian).

### Features

**Menu bar panel**
- Battery, charging and the Bluetooth codec in use (AAC, SBC, LDAC).
- Noise Cancelling / Ambient Sound / Off, ambient level 1–20 and Focus on voice.
- Optional (Settings → General): equalizer preset, DSEE Extreme, Speak-to-Chat, and Previous / Play-Pause / Next with headphone volume. Off by default to keep the panel compact.
- Launch at login.

**Settings window** (Settings… in the panel)
- *General*: model, firmware, codec; Bluetooth connection quality (sound vs. stable connection); multipoint; automatic power off; pause when taken off; voice guidance; turn the headphones off.
- **Keep the Mac's microphone on connect** (on by default): macOS makes the headphone mic the default input when they connect, which drops the sound to the mono call profile. SonyMenu switches the input back to the built-in mic so music stays stereo; apps that pick the headphone mic themselves (calls) still get it.
- *Sound*: ambient level and voice focus; equalizer presets, plus a custom 5-band EQ with Clear Bass; DSEE Extreme; Speak-to-Chat with sensitivity and timeout.
- *Controls*: right touch panel on/off; what the left NC/AMB button cycles through; touch and hold → voice assistant or nothing; **gesture remapping** (below).

Every option appears only if the headphones list it as supported. All of them were tested on a WH-1000XM5 (firmware 2.3.1) with `--selftest`.

### Gesture remapping

The WH-1000XM5 reports every touch by name over its control channel (time-series operation log), so SonyMenu sees each gesture and can run a Mac action for it.

| Gesture | Reported as | Headphones' own action | Remap |
| --- | --- | --- | --- |
| Right: double tap | `keyRDoubleTap` | Play/Pause | replaced |
| Right: swipe forward | `keyRRightFlick` | Next track | replaced |
| Right: swipe backward | `keyRLeftFlick` | Previous track | replaced |
| Right: swipe up / down | `keyRUpFlick` / `keyRDownFlick` | volume | added on top |
| Right: touch and hold | `keyRHold` | voice assistant (if set) | added on top |
| Right: two-finger touch and hold | `keyRTwoFingerHold` | Speak-to-Chat on/off | added on top |
| Right: cover with palm | `opQAStart` / `opQAEnd` | Quick Attention | added on top |
| Left: NC/AMB press | `keyCustomBtn` | switch NC / Ambient | added on top |
| Left: NC/AMB hold 2 s | `keyCustomBtnHold` | nothing | free |

"Replaced" gestures reach the Mac as media keys; SonyMenu holds those keys back and runs your action instead. Keyboard media keys still work as usual unless you choose otherwise. The rest happen inside the headphones (or as Bluetooth volume), so your action runs as well. A short two-finger tap isn't a gesture on the XM5.

Actions: Play/Pause, Pause, Next, Previous, Previous song (skip back instead of restarting), Mac volume up/down/mute, cycle NC/Ambient/Off, Noise cancelling, Ambient, toggle Speak-to-Chat, **double-tap Option** (starts and stops dictation apps like Dictator), **press a keyboard shortcut** (recorded once), **open an app**, or do nothing.

Replacing media-key gestures and pressing keys needs **Accessibility** access (System Settings → Privacy & Security). Because the app is ad-hoc signed, each new build needs the permission again: run `tccutil reset Accessibility local.sonymenu`, open SonyMenu, and allow it.

### Compatibility

| Headphones | Status |
| --- | --- |
| WH-1000XM5 | works, tested (firmware 2.3.1) |
| WH-1000XM6 | should work (same protocol), untested |
| WH-1000XM4 and older | not supported (older protocol) |

Requires **macOS 26 or later**. Apple Silicon and Intel.

### Install

From source (needs the Xcode command line tools, `xcode-select --install`):

```bash
git clone https://github.com/ellyormakhmudov/SonyMenu.git
cd SonyMenu
./build.sh --install
```

This builds `build/SonyMenu.app`, copies it to `~/Applications` and launches it. `./build.sh --zip` makes a release archive. The app is ad-hoc signed; if macOS blocks a downloaded copy, run `xattr -dr com.apple.quarantine /Applications/SonyMenu.app`.

### Diagnostics

The app logs to `~/Library/Logs/SonyMenu.log`. These modes must run from the bundle so macOS grants Bluetooth access; they write to `~/Library/Logs/SonyMenu-dump.txt`:

```bash
open ~/Applications/SonyMenu.app --args --dump       # raw replies to every read request
open ~/Applications/SonyMenu.app --args --selftest   # change each setting, read it back, restore it
```

Quit the menu bar app first: only one program can hold the headphones' control channel.

### How it works

Sony headphones take commands over Bluetooth RFCOMM (the "MDR" protocol used by Sony Sound Connect). The protocol is documented in [mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT) and reimplemented here in Swift. [docs/PROTOCOL.md](docs/PROTOCOL.md) lists the exact bytes used and what the XM5 answered.

- `MDR.swift`: framing and command constants.
- `Headphones.swift`: Bluetooth link, state, settings.
- `Panel.swift`, `SettingsView.swift`: the UI.
- `Gestures.swift`: media-key tap and gesture actions.
- `SelfTest.swift`: the `--selftest` mode.

### Disclaimer

Unofficial project, not affiliated with Sony Group Corporation. Sony and WH-1000XM5 are trademarks of their owners. Use at your own risk.
