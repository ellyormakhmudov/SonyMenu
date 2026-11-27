import AppKit
import Foundation

// Command-line modes (run inside the .app so macOS grants Bluetooth access):
//   --probe [--set nc|ambient|off]  print what the headphones report and exit
//   --dump                          GET every supported setting, write raw replies to ~/Library/Logs/SonyMenu-dump.txt
//   --mediatest                     play/pause and next/previous end to end (quit the menu bar app first)
//   --selftest                      change each setting, read it back, restore it; results in the same file
//   --snapshot <folder>             render the panel and settings with sample data to PNGs
// Without arguments it runs the menu bar app.
let args = CommandLine.arguments

/// Writes to stdout and to ~/Library/Logs/SonyMenu-dump.txt.
@MainActor
func makeReportSink() -> (String) -> Void {
    let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SonyMenu-dump.txt")
    try? Data().write(to: out)
    return { line in
        print(line); fflush(stdout)
        if let h = try? FileHandle(forWritingTo: out) {
            h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close()
        }
    }
}

if args.contains("--dump") {
    MainActor.assumeIsolated {
        let emit = makeReportSink()
        let hp = Headphones()
        hp.log = { emit("• " + $0) }
        hp.onPayload = { t, p in
            emit((t == 0x0E ? "T2 " : "T1 ") + p.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        hp.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--rawset"), i + 1 < args.count {
    // --rawset "d8 d2 00 00": sends one T1 command once connected, logs every reply for 25 s.
    let frames = args[i + 1].split(separator: ";").map { $0.split(separator: " ").compactMap { UInt8($0, radix: 16) } }
    MainActor.assumeIsolated {
        let emit = makeReportSink()
        let hp = Headphones()
        hp.log = { emit("• " + $0) }
        hp.onPayload = { t, p in
            emit((t == 0x0E ? "T2 " : "T1 ") + p.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        hp.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            for bytes in frames {
                emit(">> sending " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                hp.sendRaw(bytes)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { emit(">> read back"); hp.sendRaw([0xD6, 0xD2]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
    }
    RunLoop.main.run()
} else if args.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest(emit: makeReportSink()).run() }
    RunLoop.main.run()
} else if args.contains("--dictatetest") {
    // Real run: starts Dictator like the NC-button hold, speaks a sentence ending in
    // "stop dictation" on the Mac's speakers, and checks what Dictator produced.
    MainActor.assumeIsolated {
        let emit = makeReportSink()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let board = NSPasteboard.general
        let before = board.changeCount
        let l = StopPhraseListener.shared
        var spoke = false
        l.log = { line in
            emit("• " + line)
            if line.hasPrefix("Listening"), !spoke {
                spoke = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    p.arguments = ["-a", "MacBook Pro Speakers", "-r", "170", "Please remember to buy milk tomorrow. Stop dictation."]
                    try? p.run()
                }
            }
            if line.hasPrefix("Removed") || line.hasPrefix("Dictator's text") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let text = board.changeCount != before ? (board.string(forType: .string) ?? "") : "(clipboard unchanged)"
                    emit("Clipboard changed: \(board.changeCount != before), \(text.count) characters, still ends with the phrase: \(StopPhraseListener.endsWithStopPhrase(text))")
                    let ok = line.hasPrefix("Removed") && text.lowercased().contains("milk") && !StopPhraseListener.endsWithStopPhrase(text)
                    emit(ok ? "PASS" : "FAIL")
                    exit(ok ? 0 : 1)
                }
            }
        }
        l.enabled = true
        GestureController.shared.perform(.doubleTapOption)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            emit("FAIL: nothing finished in 40 s; clipboard changed: \(board.changeCount != before)")
            GestureController.doubleTapOption()
            exit(1)
        }
    }
    RunLoop.main.run()
} else if args.contains("--listentest") {
    // Feeds a spoken test file through the real recogniser and checks the phrase is heard.
    MainActor.assumeIsolated {
        let emit = makeReportSink()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dir = FileManager.default.temporaryDirectory
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var cases: [(String, Bool)] = [("please remember to buy milk. stop dictation", true),
                                       ("we should stop here and talk about dinner", false)]
        @MainActor func next() {
            guard !cases.isEmpty else { emit("listen test done"); exit(0) }
            let (sentence, expected) = cases.removeFirst()
            let file = dir.appendingPathComponent("sonymenu-listen-\(cases.count).aiff")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-o", file.path, sentence]
            try? p.run(); p.waitUntilExit()
            let l = StopPhraseListener.shared
            var done = false
            l.log = { emit("  • " + $0) }
            l.testAudio = file
            l.onHeard = {
                done = true
                emit("\(expected ? "PASS" : "FAIL")  \"\(sentence)\": heard the phrase")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
            }
            l.enabled = true
            l.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard !done else { return }
                l.stop()
                emit("\(expected ? "FAIL" : "PASS")  \"\(sentence)\": no phrase heard")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
            }
        }
        _ = say
        next()
    }
    RunLoop.main.run()
} else if args.contains("--mediatest") {
    MainActor.assumeIsolated { MediaTest(emit: makeReportSink()).run() }
    RunLoop.main.run()
} else if args.contains("--probe") {
    MainActor.assumeIsolated {
        let hp = Headphones()
        hp.log = { print("•", $0); fflush(stdout) }
        hp.start()

        var target: SoundMode?
        if let i = args.firstIndex(of: "--set"), i + 1 < args.count {
            switch args[i + 1] {
            case "nc": target = .noiseCancelling
            case "ambient": target = .ambient
            case "off": target = .off
            default: break
            }
        }
        if let target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                print("→ Setting mode \(target)")
                hp.setMode(target)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (target == nil ? 8 : 10)) {
            print("Result: ready=\(hp.isReady) battery=\(hp.battery.map(String.init) ?? "—") mode=\(hp.mode.map { "\($0)" } ?? "—") problem=\(hp.problem ?? "none")")
            exit(0)
        }
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    // Renders the panel and settings in light and dark to PNGs in the given folder.
    MainActor.assumeIsolated { renderSnapshots(to: URL(fileURLWithPath: args[i + 1])) }
} else {
    MainActor.assumeIsolated { SonyMenuApp.main() }
}
