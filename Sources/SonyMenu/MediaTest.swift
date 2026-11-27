import AppKit
import AVFoundation
import MediaPlayer

/// `--mediatest`: end-to-end check of play/pause and next/previous on this Mac.
///
/// The app becomes the Now Playing app (silent audio + remote command handlers), installs the
/// real media-key tap, then plays out each case: a media key that looks like it came from the
/// headphones (posted without the app's marker, exactly like Bluetooth's), the headphones'
/// gesture report arriving before or after it, keyboard presses, a dropped control link and
/// fast skipping. It counts the commands the player actually receives.
/// Quit the menu bar app first, or its tap reacts to the test keys too.
@MainActor
final class MediaTest {
    private let emit: (String) -> Void
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var got: [String: Int] = [:]
    private var firstAt: Date?
    private var passed = 0, failed = 0
    private let hp = Headphones()
    private let gc = GestureController.shared

    init(emit: @escaping (String) -> Void) { self.emit = emit }

    func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        becomeNowPlaying()
        hp.loadSampleState(mode: .noiseCancelling)
        gc.headphones = hp
        gc.log = { [emit] in emit("    · " + $0) }
        let trusted = AXIsProcessTrusted()
        let tap = trusted && gc.installTapForTest()
        emit("Accessibility: \(trusted ? "granted" : "MISSING"), media key tap: \(tap ? "on" : "off")")
        guard tap else {
            emit("FAIL: the tap is needed for this test. Allow SonyMenu in Accessibility and rerun.")
            exit(1)
        }
        Task { await self.cases(); self.finish() }
    }

    // MARK: Cases

    private func cases() async {
        await wait(1.5) // let macOS make us the Now Playing app

        // "stop dictation" phrase matching (pure logic).
        let phrases: [(String, Bool, Int)] = [
            ("Please buy milk stop dictation", true, 15), ("Stop dictation.", true, 15),
            ("we should stop here and talk", false, 0), ("stop", false, 0),
            ("Stop dictation, then continue", false, 0), ("send it. Stop Dictation!", true, 16),
            ("non-stop dictation", false, 0), ("I said stop", false, 0),
        ]
        for (text, ends, len) in phrases {
            let ok = StopPhraseListener.endsWithStopPhrase(text) == ends && StopPhraseListener.phraseSuffixLength(text) == len
            if ok { passed += 1 } else { failed += 1 }
            emit("\(ok ? "PASS" : "FAIL")  Stop phrase in \"\(text)\": ends=\(StopPhraseListener.endsWithStopPhrase(text)) cut=\(StopPhraseListener.phraseSuffixLength(text))")
        }

        gc.testMap = [:]
        // What the XM5 really does today: reports the gesture, sends no media key to the Mac.
        await check("Double tap (report only) → play/pause", expect: ["toggle": 1], within: 0.2) {
            self.report(.doubleTap, after: 0)
        }
        await check("Swipe forward (report only) → next", expect: ["next": 1], within: 0.2) {
            self.report(.swipeForward, after: 0)
        }
        await check("Swipe backward (report only) → previous", expect: ["previous": 1], within: 0.2) {
            self.report(.swipeBackward, after: 0)
        }
        // If the headphones do send their key too, it must not act twice.
        await check("Double tap, key then report → one toggle", expect: ["toggle": 1], within: 0.2) {
            self.headphoneKey(MediaKey.play); self.report(.doubleTap, after: 0.15)
        }
        await check("Double tap, report then key → one toggle", expect: ["toggle": 1], within: 0.2) {
            self.report(.doubleTap, after: 0); self.headphoneKey(MediaKey.play, after: 0.2)
        }
        await check("Swipe forward, key then report → one next", expect: ["next": 1], within: 0.2) {
            self.headphoneKey(MediaKey.next); self.report(.swipeForward, after: 0.12)
        }
        await check("Keyboard play key passes at once", expect: ["toggle": 1], within: 0.15) {
            self.headphoneKey(MediaKey.play)
        }
        await check("Four double taps → four toggles", expect: ["toggle": 4], within: 0.2) {
            for i in 0..<4 { self.report(.doubleTap, after: Double(i) * 0.7) }
        }
        await check("Five fast swipes forward → five nexts", expect: ["next": 5], within: 0.2) {
            for i in 0..<5 { self.report(.swipeForward, after: Double(i) * 0.4) }
        }
        // Headphones that send their own play/pause/skip over Bluetooth first (opPlay etc.).
        await check("Double tap after opPause → pause, no toggle", expect: ["pause": 1], within: 0.3) {
            self.op("opPause", after: 0); self.report(.doubleTap, after: 0.15)
        }
        await check("Double tap after opPlay → play, no toggle", expect: ["play": 1], within: 0.3) {
            self.op("opPlay", after: 0); self.report(.doubleTap, after: 0.15)
        }
        await check("Four double taps after opPause → never toggles", expect: ["pause": 4], within: 0.3) {
            for i in 0..<4 { self.op("opPause", after: Double(i) * 0.7); self.report(.doubleTap, after: Double(i) * 0.7 + 0.15) }
        }
        await check("Swipe forward after opNext → no second skip", expect: [:], within: 0) {
            self.op("opNext", after: 0); self.report(.swipeForward, after: 0.2)
        }
        await check("Stale opPause (2 s old) is ignored", expect: ["toggle": 1], within: 2.3) {
            self.op("opPause", after: 0); self.report(.doubleTap, after: 2.0)
        }
        hp.simulateLink(false)
        await check("Link down: keyboard key still works", expect: ["previous": 1], within: 0.15) {
            self.headphoneKey(MediaKey.previous)
        }
        hp.simulateLink(true)

        gc.testMap = [.swipeBackward: .previousSong, .doubleTap: .playPause, .swipeForward: .next]
        await check("Previous song: key then report", expect: ["previous": 2], within: 0.6) {
            self.headphoneKey(MediaKey.previous); self.report(.swipeBackward, after: 0.15)
        }
        await check("Previous song: report then key", expect: ["previous": 2], within: 0.6) {
            self.report(.swipeBackward, after: 0); self.headphoneKey(MediaKey.previous, after: 0.15)
        }
        await check("Previous song: report 0.6 s late", expect: ["previous": 2], within: 1.0) {
            self.headphoneKey(MediaKey.previous); self.report(.swipeBackward, after: 0.6)
        }
        await check("Play/pause remapped: no double toggle", expect: ["toggle": 1], within: 0.4) {
            self.headphoneKey(MediaKey.play); self.report(.doubleTap, after: 0.15)
        }
        await check("Keyboard previous key still works", expect: ["previous": 1], within: 1.2) {
            self.headphoneKey(MediaKey.previous)
        }
        await check("Previous song after opPrev → one more previous", expect: ["previous": 1], within: 0.3) {
            self.op("opPrev", after: 0); self.report(.swipeBackward, after: 0.15)
        }
        gc.testMap = [.doubleTap: .pause]
        await check("Pause action pauses (doesn't toggle)", expect: ["pause": 1], within: 0.5) {
            self.headphoneKey(MediaKey.play); self.report(.doubleTap, after: 0.15)
        }

        gc.testMap = [.swipeBackward: .previousSong]
        hp.simulateLink(false)
        await check("Control link down: key passes at once", expect: ["previous": 1], within: 0.25) {
            self.headphoneKey(MediaKey.previous)
        }
        hp.simulateLink(true)
        await check("Link back: previous song again", expect: ["previous": 2], within: 0.6) {
            self.headphoneKey(MediaKey.previous); self.report(.swipeBackward, after: 0.15)
        }
        gc.testMap = nil
    }

    // MARK: Helpers

    /// A media key as the headphones send it: no SonyMenu marker, through the HID tap.
    private func headphoneKey(_ key: Int32, after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for down in [true, false] {
                let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
                guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                  modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  subtype: 8, data1: data1, data2: -1),
                      let cg = ev.cgEvent else { continue }
                cg.post(tap: .cghidEventTap)
            }
        }
    }

    /// The headphones' own gesture report, as it arrives over the control channel.
    private func report(_ g: Gesture, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.gc.handleEvent(g.eventKey) }
    }

    /// A playback command the headphones report having sent over Bluetooth themselves.
    private func op(_ key: String, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.gc.handleEvent(key) }
    }

    private func check(_ name: String, expect: [String: Int], within: Double, _ act: @escaping () -> Void) async {
        got = [:]
        firstAt = nil
        let start = Date()
        act()
        await wait(3.4) // also catch late extra commands
        let ok = got == expect
        let latency = firstAt.map { String(format: "first after %.0f ms", $0.timeIntervalSince(start) * 1000) } ?? "nothing arrived"
        let inTime = expect.isEmpty ? got.isEmpty : (firstAt.map { $0.timeIntervalSince(start) <= within } ?? false)
        let pass = ok && inTime
        if pass { passed += 1 } else { failed += 1 }
        let gotText = got.isEmpty ? "none" : got.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        emit("\(pass ? "PASS" : "FAIL")  \(name): got \(gotText), \(latency)\(pass || ok ? "" : ", wanted \(expect)")")
        await wait(0.4)
    }

    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func finish() {
        emit("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: Now Playing stand-in

    private func becomeNowPlaying() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!
        silence.frameLength = 44100
        try? engine.start()
        node.scheduleBuffer(silence, at: nil, options: .loops)
        node.play()

        let cc = MPRemoteCommandCenter.shared()
        let commands: [(MPRemoteCommand, String)] = [
            (cc.togglePlayPauseCommand, "toggle"), (cc.playCommand, "play"), (cc.pauseCommand, "pause"),
            (cc.nextTrackCommand, "next"), (cc.previousTrackCommand, "previous"),
        ]
        for (command, name) in commands {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.got[name, default: 0] += 1
                    if self?.firstAt == nil { self?.firstAt = Date() }
                }
                return .success
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "SonyMenu media test",
                                                           MPNowPlayingInfoPropertyPlaybackRate: 1.0]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }
}
