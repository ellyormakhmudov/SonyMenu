import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import SwiftUI

/// A gesture on the WH-1000XM5. With the time-series operation log turned on, the
/// headphones report each one by name over the control channel (tested on firmware 2.3.1).
enum Gesture: String, CaseIterable, Identifiable {
    case doubleTap, swipeForward, swipeBackward, swipeUp, swipeDown, hold, twoFingerHold, palm
    case leftPress, leftHold

    var id: String { rawValue }

    /// Name the headphones log for this gesture.
    var eventKey: String {
        switch self {
        case .doubleTap: return "keyRDoubleTap"
        case .swipeForward: return "keyRRightFlick"
        case .swipeBackward: return "keyRLeftFlick"
        case .swipeUp: return "keyRUpFlick"
        case .swipeDown: return "keyRDownFlick"
        case .hold: return "keyRHold"
        case .twoFingerHold: return "keyRTwoFingerHold"
        case .palm: return "opQAStart"
        case .leftPress: return "keyCustomBtn"
        case .leftHold: return "keyCustomBtnHold"
        }
    }

    var isLeft: Bool { self == .leftPress || self == .leftHold }

    var title: String { L(titleKey) }
    private var titleKey: String {
        switch self {
        case .doubleTap: return "Double tap"
        case .swipeForward: return "Swipe forward"
        case .swipeBackward: return "Swipe backward"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .hold: return "Touch and hold"
        case .twoFingerHold: return "Two-finger touch and hold"
        case .palm: return "Cover with palm"
        case .leftPress: return "NC/AMB button: press"
        case .leftHold: return "NC/AMB button: hold 2 s"
        }
    }

    /// What the headphones do on their own.
    var builtIn: String { L(builtInKey) }
    private var builtInKey: String {
        switch self {
        case .doubleTap: return "Play/Pause"
        case .swipeForward: return "Next track"
        case .swipeBackward: return "Previous track"
        case .swipeUp: return "Volume up"
        case .swipeDown: return "Volume down"
        case .hold: return "Voice assistant (if set below)"
        case .twoFingerHold: return "Speak-to-Chat on/off"
        case .palm: return "Quick Attention"
        case .leftPress: return "Switch NC / Ambient"
        case .leftHold: return "Nothing"
        }
    }

    /// Media key the headphones send to the Mac for this gesture. The app can swallow these
    /// (with Accessibility access), so the gesture's own action is replaced, not added to.
    var mediaKey: Int32? {
        switch self {
        case .doubleTap: return MediaKey.play
        case .swipeForward: return MediaKey.next
        case .swipeBackward: return MediaKey.previous
        default: return nil
        }
    }

    /// What the app does for this gesture when it's left on Default. The XM5 often sends its
    /// playback command only to the other multipoint device (or not at all), so SonyMenu plays,
    /// pauses and skips on the Mac itself as soon as the headphones report the gesture.
    var ownedDefault: MacAction? {
        switch self {
        case .doubleTap: return .playPause
        case .swipeForward: return .next
        case .swipeBackward: return .previous
        default: return nil
        }
    }

    var detail: String {
        if mediaKey != nil { return String(format: L("Default: %@ on this Mac. Your choice replaces it."), builtIn) }
        if self == .leftHold { return L("Headphones: nothing. Free for any Mac action.") }
        return String(format: L("Headphones: %@. Your choice runs as well."), builtIn)
    }
}

enum MacAction: String, CaseIterable, Identifiable {
    case keepDefault, nothing, playPause, pause, next, previous, previousSong
    case volumeUp, volumeDown, mute, cycleNoise, noiseCancelling, ambient, speakToChat
    case doubleTapOption, shortcut, openApp

    var id: String { rawValue }

    /// Playback and volume: harmless to repeat, so never rate limited.
    var isMedia: Bool {
        [.keepDefault, .nothing, .playPause, .pause, .next, .previous, .previousSong,
         .volumeUp, .volumeDown, .mute].contains(self)
    }

    var title: String { L(titleKey) }
    private var titleKey: String {
        switch self {
        case .keepDefault: return "Default"
        case .nothing: return "Do nothing"
        case .playPause: return "Play / Pause"
        case .pause: return "Pause (stop playback)"
        case .next: return "Next track"
        case .previous: return "Previous track"
        case .previousSong: return "Previous song (skip back, not restart)"
        case .volumeUp: return "Mac volume up"
        case .volumeDown: return "Mac volume down"
        case .mute: return "Mute / unmute Mac"
        case .cycleNoise: return "Cycle NC / Ambient / Off"
        case .noiseCancelling: return "Noise cancelling"
        case .ambient: return "Ambient sound"
        case .speakToChat: return "Toggle Speak-to-Chat"
        case .doubleTapOption: return "Double-tap Option ⌥ (Dictator, dictation)"
        case .shortcut: return "Press a keyboard shortcut…"
        case .openApp: return "Open an app…"
        }
    }

    /// Actions offered for a gesture. "Do nothing" only makes sense where the app can
    /// swallow the headphones' own command.
    static func options(for g: Gesture) -> [MacAction] {
        allCases.filter { $0 != .keepDefault && ($0 != .nothing || g.mediaKey != nil) }
    }
}

enum MediaKey {
    static let soundUp: Int32 = 0
    static let soundDown: Int32 = 1
    static let mute: Int32 = 7
    static let play: Int32 = 16
    static let next: Int32 = 17
    static let previous: Int32 = 18

    static func name(_ k: Int32) -> String {
        [soundUp: "VOL+", soundDown: "VOL-", mute: "MUTE", play: "PLAY", next: "NEXT", previous: "PREV"][k] ?? "\(k)"
    }
}

/// A recorded key combination, e.g. ⌥Space for a dictation app.
struct Shortcut: Equatable {
    var keyCode: UInt16
    var modifiers: UInt64   // CGEventFlags raw value (device-independent part)
    var display: String
}

/// Remembers the gesture map and runs it.
@MainActor
final class GestureController: ObservableObject {
    static let shared = GestureController()

    @Published private(set) var map: [Gesture: MacAction] = [:]
    @Published private(set) var shortcuts: [Gesture: Shortcut] = [:]
    @Published private(set) var apps: [Gesture: URL] = [:]
    @Published var recording: Gesture?
    /// Also treat the Mac keyboard's media keys as the gesture (instead of passing them on).
    @Published var includeKeyboard: Bool {
        didSet { UserDefaults.standard.set(includeKeyboard, forKey: "gestures.includeKeyboard") }
    }
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var tapActive = false
    @Published private(set) var lastEvent: String?

    weak var headphones: Headphones?
    var log: (String) -> Void = { _ in }

    private var readyWatch: AnyCancellable?
    /// Log every media key (diagnostics), even when no gesture is remapped.
    var observeKeys = UserDefaults.standard.object(forKey: "gestures.observeKeys") as? Bool ?? true
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var recordMonitor: Any?
    /// When each gesture was last reported by the headphones.
    private var recent: [Gesture: Date] = [:]
    private var actionTimes: [Date] = []
    /// Media keys swallowed while waiting to see whether the headphones report a gesture.
    private var pendingKeys: [Int32: DispatchWorkItem] = [:]
    /// When each held media key arrived, to log how late the headphones' report is.
    private var pendingSince: [Int32: Date] = [:]
    /// How long a remapped media key waits for the headphones' report before it's treated as
    /// a keyboard key and passed on. The report usually comes within 0.2 s.
    static var holdWindow: TimeInterval = 0.8
    /// When a default media key last passed through untouched, so a gesture report right after
    /// it doesn't act a second time.
    private var passedAt: [Int32: Date] = [:]
    /// Gesture reports that came before their media key; each one swallows exactly one key.
    private var reportedFirst: [Gesture: Date] = [:]
    /// Test-only gesture map (never saved).
    var testMap: [Gesture: MacAction]?
    /// Marks key events this app posts, so the tap lets them through. Random per launch, so
    /// other processes can't predict it.
    nonisolated fileprivate static let syntheticMark = Int64.random(in: 1...Int64.max)

    private init() {
        let d = UserDefaults.standard
        includeKeyboard = d.bool(forKey: "gestures.includeKeyboard")
        for g in Gesture.allCases {
            map[g] = MacAction(rawValue: d.string(forKey: "gesture.\(g.rawValue)") ?? "") ?? .keepDefault
            if let s = d.dictionary(forKey: "gesture.\(g.rawValue).shortcut"),
               let k = s["key"] as? Int, let m = s["mods"] as? Int, let t = s["display"] as? String {
                shortcuts[g] = Shortcut(keyCode: UInt16(k), modifiers: UInt64(m), display: t)
            }
            if let path = d.string(forKey: "gesture.\(g.rawValue).app") { apps[g] = URL(fileURLWithPath: path) }
        }
    }

    func action(for g: Gesture) -> MacAction {
        if let testMap { return testMap[g] ?? .keepDefault }
        return map[g] ?? .keepDefault
    }

    func set(_ action: MacAction, for g: Gesture) {
        map[g] = action
        UserDefaults.standard.set(action.rawValue, forKey: "gesture.\(g.rawValue)")
        if action == .shortcut, shortcuts[g] == nil { startRecording(g) }
        if action == .openApp, apps[g] == nil { chooseApp(for: g) }
        refresh()
    }

    /// Accessibility is needed to swallow media keys and to press shortcuts.
    private var needsAccess: Bool {
        Gesture.allCases.contains { g in
            let a = action(for: g)
            return (g.mediaKey != nil && a != .keepDefault) || a == .shortcut || a == .doubleTapOption
        }
    }

    private var needsTap: Bool {
        Gesture.allCases.contains { $0.mediaKey != nil }
    }

    func start() {
        headphones?.onEvent = { [weak self] key in self?.handleEvent(key) }
        StopPhraseListener.shared.log = { [weak self] in self?.log($0) }
        // The tap runs only while the control link is live, so media keys never wait on the app
        // when it can't match them to a gesture anyway.
        readyWatch = headphones?.$isReady.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        refresh()
        if needsAccess, !accessibilityGranted {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            log("Asked for Accessibility access (needed for gesture remapping)")
        }
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        let linkUp = headphones?.isReady == true || includeKeyboard
        if needsTap || observeKeys, accessibilityGranted, linkUp { installTap() } else { removeTap() }
        if needsAccess, !accessibilityGranted, permissionTimer == nil {
            // Pick the permission up as soon as the user grants it in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    if AXIsProcessTrusted() || !self.needsAccess {
                        t.invalidate(); self.permissionTimer = nil; self.refresh()
                    }
                }
            }
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refresh()
    }

    // MARK: Headphone events

    /// The playback command the headphones just sent over Bluetooth themselves (opPlay, opPause,
    /// opNext, opPrev). It comes about 0.1-0.3 s before the gesture report.
    private var sentOp: (key: String, at: Date)?
    private static let sentOps: Set<String> = ["opPlay", "opPause", "opNext", "opPrev"]

    func handleEvent(_ key: String) {
        if Self.sentOps.contains(key) { sentOp = (key, Date()); return }
        guard let g = Gesture.allCases.first(where: { $0.eventKey == key }) else { return }
        // One action per gesture: ignore a repeat of the same event within 0.3 s.
        if let t = recent[g], Date().timeIntervalSince(t) < 0.3 { return }
        recent[g] = Date()
        let chosen = action(for: g)
        let a = chosen == .keepDefault ? (g.ownedDefault ?? .keepDefault) : chosen
        // At most 5 non-media actions (shortcuts, apps, Option taps) in any 5 seconds, whatever the
        // headphones send. Playback and volume stay unlimited so fast skipping always works.
        if !a.isMedia {
            actionTimes = actionTimes.filter { Date().timeIntervalSince($0) < 5 }
            guard actionTimes.count < 5 else { log("Gesture ignored: too many in 5 s"); return }
            actionTimes.append(Date())
        }
        lastEvent = "\(g.isLeft ? L("Left") : L("Right")): \(g.title) → \(a == .keepDefault ? g.builtIn : a.title)"
        log("Gesture \(g.rawValue) → \(a.rawValue)")
        if chosen == .keepDefault, let mk = g.mediaKey {
            // Default playback: act now, unless the headphones' own key just did it.
            if let t = passedAt.removeValue(forKey: mk), Date().timeIntervalSince(t) < 0.6 {
                log("Media key \(MediaKey.name(mk)) from the headphones already did it")
                return
            }
            reportedFirst[g] = Date()
            if !followHeadphones(a) { perform(a, for: g) }
            return
        }
        if let mk = g.mediaKey {
            if let pending = pendingKeys.removeValue(forKey: mk) {
                pending.cancel() // the swallowed media key was this gesture, not the keyboard
                if let t = pendingSince.removeValue(forKey: mk) {
                    log("Media key \(MediaKey.name(mk)) matched gesture after \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                }
            } else {
                reportedFirst[g] = Date() // its media key is still on the way
            }
        }
        if a != .keepDefault, !followHeadphones(a) { perform(a, for: g) }
    }

    /// When the headphones already sent their own playback command, never toggle on top of it
    /// (that flips play/pause straight back). Play/pause follows their direction with an explicit
    /// play or pause, which is harmless if the player already got theirs; a skip they already sent
    /// isn't repeated. Returns true when that settled the action.
    private func followHeadphones(_ a: MacAction) -> Bool {
        guard let op = sentOp, Date().timeIntervalSince(op.at) < 1.0 else { return false }
        sentOp = nil
        switch (a, op.key) {
        case (.playPause, "opPlay"), (.playPause, "opPause"):
            let c: MediaRemote.Command = op.key == "opPlay" ? .play : .pause
            let ok = MediaRemote.send(c)
            log("Headphones sent \(op.key); sent \(c == .play ? "play" : "pause")\(ok ? "" : " (no player answered)")")
            return true
        case (.next, "opNext"), (.previous, "opPrev"):
            log("Headphones sent \(op.key) themselves; not repeating it")
            return true
        case (.previousSong, "opPrev"):
            log("Headphones sent opPrev; one more previous to reach the previous song")
            Self.play(.previous, else: MediaKey.previous)
            return true
        default:
            return false
        }
    }

    // MARK: Media-key tap

    private func installTap() {
        guard tap == nil else { tapActive = true; return }
        let mask = CGEventMask(1 << 14) // NSEventTypeSystemDefined
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: mediaKeyCallback, userInfo: refcon) else {
            log("Media key tap could not be created")
            tapActive = false
            return
        }
        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapActive = true
        log("Media key tap on")
    }

    private func removeTap() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        runLoopSource = nil
        if tapActive { log("Media key tap off") }
        tapActive = false
    }

    fileprivate func reenable() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Returns true when the key event should be swallowed. A remapped gesture's media key is
    /// held back: if the headphones report the gesture (just before or within 0.7 s), the key is
    /// dropped and the gesture's action runs instead; otherwise it came from the keyboard and is
    /// passed on unchanged.
    func handleMediaKey(_ key: Int32, down: Bool, source: Int64 = 0) -> Bool {
        guard let g = Gesture.allCases.first(where: { $0.mediaKey == key }) else { return false }
        if down { log("Media key \(MediaKey.name(key)) arrived (source \(source))") }
        let a = action(for: g)
        if a == .keepDefault {
            guard down else { return false }
            if let t = reportedFirst.removeValue(forKey: g), Date().timeIntervalSince(t) < 1.0 {
                log("Media key \(MediaKey.name(key)) dropped: gesture already handled")
                return true
            }
            passedAt[key] = Date() // keyboard (or the headphones' own key): pass it on at once
            return false
        }
        // Only hold keys back while the control link is live: without it no gesture report can
        // come, and holding would just delay (or lose) the key.
        guard headphones?.isReady == true || includeKeyboard else {
            if down { log("Media key \(MediaKey.name(key)) passed on: headphone controls not connected") }
            return false
        }
        guard down else { return true } // the matching key-up; re-posts send their own
        if includeKeyboard {
            if recent[g].map({ Date().timeIntervalSince($0) < 1.5 }) != true { perform(a, for: g) }
            return true
        }
        if let t = reportedFirst.removeValue(forKey: g), Date().timeIntervalSince(t) < 1.5 {
            log("Media key \(MediaKey.name(key)) dropped: gesture already handled")
            return true
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingKeys[key] = nil
            self?.pendingSince[key] = nil
            self?.log("Media key \(MediaKey.name(key)) passed on: no gesture reported (keyboard)")
            Self.postKey(key) // nothing from the headphones: it was the keyboard
        }
        pendingKeys[key]?.cancel()
        pendingKeys[key] = work
        pendingSince[key] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdWindow, execute: work)
        return true
    }

    /// Installs the media-key tap regardless of the saved map (for `--mediatest`).
    func installTapForTest() -> Bool { installTap(); return tapActive }

    // MARK: Shortcut and app choice

    func startRecording(_ g: Gesture) {
        stopRecording()
        recording = g
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let g = self.recording else { return e }
                if e.keyCode == 53, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.stopRecording(); return nil // Esc cancels
                }
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
                let s = Shortcut(keyCode: e.keyCode,
                                 modifiers: UInt64(Self.cgFlags(mods).rawValue),
                                 display: Self.describe(mods, e))
                self.shortcuts[g] = s
                UserDefaults.standard.set(["key": Int(s.keyCode), "mods": Int(s.modifiers), "display": s.display],
                                          forKey: "gesture.\(g.rawValue).shortcut")
                self.stopRecording()
                return nil
            }
        }
    }

    func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        recording = nil
    }

    func chooseApp(for g: Gesture) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = L("Choose")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apps[g] = url
        UserDefaults.standard.set(url.path, forKey: "gesture.\(g.rawValue).app")
    }

    private static func cgFlags(_ m: NSEvent.ModifierFlags) -> CGEventFlags {
        var f = CGEventFlags()
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    private static func describe(_ m: NSEvent.ModifierFlags, _ e: NSEvent) -> String {
        var s = ""
        if m.contains(.function) { s += "fn " }
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return s + (names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased())
    }

    // MARK: Actions

    func perform(_ a: MacAction, for g: Gesture? = nil) {
        switch a {
        case .keepDefault, .nothing: break
        // Playback goes straight to the Now Playing app (no media key, so macOS shows no popup);
        // the media key is only the fallback if that isn't available.
        case .playPause: Self.play(.toggle, else: MediaKey.play)
        case .pause: Self.play(.pause, else: MediaKey.play)
        case .next: Self.play(.next, else: MediaKey.next)
        case .previous: Self.play(.previous, else: MediaKey.previous)
        case .previousSong:
            // Most players restart the song on the first "previous"; the second one goes back.
            Self.play(.previous, else: MediaKey.previous)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.play(.previous, else: MediaKey.previous) }
        case .volumeUp: Self.postKey(MediaKey.soundUp)
        case .volumeDown: Self.postKey(MediaKey.soundDown)
        case .mute: Self.postKey(MediaKey.mute)
        case .cycleNoise: headphones?.cycleMode()
        case .noiseCancelling: headphones?.setMode(.noiseCancelling)
        case .ambient: headphones?.setMode(.ambient)
        case .speakToChat:
            if let hp = headphones, let on = hp.speakToChat { hp.setSpeakToChat(!on) }
        case .doubleTapOption:
            let listener = StopPhraseListener.shared
            if listener.isListening {
                listener.stop() // the button finishes dictation itself
                Self.doubleTapOption()
            } else {
                Self.doubleTapOption()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { listener.start() } // after Dictator has the mic
            }
        case .shortcut:
            if let g, let s = shortcuts[g] { Self.press(s) } else { log("No shortcut recorded") }
        case .openApp:
            if let g, let url = apps[g] {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else { log("No app chosen") }
        }
    }

    /// Two quick taps of the Option key, which dictation apps such as Dictator use to start
    /// and stop hands-free dictation.
    static func doubleTapOption() {
        let src = CGEventSource(stateID: .hidSystemState)
        func tapOnce() {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: down) else { continue }
                e.type = .flagsChanged
                e.flags = down ? .maskAlternate : []
                e.post(tap: .cghidEventTap)
            }
        }
        tapOnce()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { tapOnce() }
    }

    static func press(_ s: Shortcut) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: s.keyCode, keyDown: down) else { continue }
            e.flags = CGEventFlags(rawValue: s.modifiers)
            e.post(tap: .cghidEventTap)
        }
    }

    static func play(_ c: MediaRemote.Command, else key: Int32) {
        if !MediaRemote.send(c) { postKey(key) }
    }

    /// Posts a media key press, so browsers (YouTube) and music apps get it via Now Playing.
    static func postKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 8, data1: data1, data2: -1),
                  let cg = ev.cgEvent else { continue }
            cg.setIntegerValueField(.eventSourceUserData, value: syntheticMark)
            cg.post(tap: .cghidEventTap)
        }
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<GestureController>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14,
          event.getIntegerValueField(.eventSourceUserData) != GestureController.syntheticMark,
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let key = Int32((ns.data1 & 0xFFFF_0000) >> 16)
    let state = (ns.data1 & 0xFF00) >> 8
    let source = event.getIntegerValueField(.eventSourceUnixProcessID)
    let swallow = MainActor.assumeIsolated { controller.handleMediaKey(key, down: state == 0xA, source: source) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// MediaRemote (private framework) for a real "pause" that doesn't toggle.
enum MediaRemote {
    enum Command: Int32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    private typealias SendFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let send: SendFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendFn.self)
    }()

    static func send(_ c: Command) -> Bool { send?(c.rawValue, nil) ?? false }
}
