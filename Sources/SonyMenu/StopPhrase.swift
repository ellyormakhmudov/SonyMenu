import AppKit
import AVFoundation
import CoreAudio
import Speech

/// While Dictator's hands-free dictation runs (started by a headphone gesture), listens on the
/// Mac's built-in microphone for "stop dictation". Then it presses Option once, which makes
/// Dictator finish and paste, and removes the phrase from the pasted text.
///
/// The built-in mic is used on purpose: opening the headphones' Bluetooth mic would switch them
/// to call quality. Recognition runs on this Mac; nothing is recorded or sent anywhere.
@MainActor
final class StopPhraseListener {
    static let shared = StopPhraseListener()
    var log: (String) -> Void = { _ in }
    /// Test mode: report hearing the phrase instead of pressing keys.
    var onHeard: (() -> Void)?
    /// Test mode: read this audio file instead of the microphone.
    var testAudio: URL?

    private(set) var isListening = false
    private var session: AVCaptureSession?
    private var sink: SampleSink?
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var generation: UUID?
    private let audioQueue = DispatchQueue(label: "local.sonymenu.stopphrase")
    private var timeout: DispatchWorkItem?
    /// The longest a dictation can run before we stop listening for the phrase.
    private let maxListen: TimeInterval = 10 * 60

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dictation.stopPhrase") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dictation.stopPhrase") }
    }

    /// Ends with "stop dictation" (any case, trailing punctuation allowed). A plain "stop"
    /// in the middle of what you say doesn't count.
    nonisolated static func endsWithStopPhrase(_ text: String) -> Bool {
        text.range(of: #"(?<![\w-])stop\s+dictation[\s.!?,]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// How many characters at the end of `text` are the phrase (with the space or punctuation
    /// before it), so they can be deleted. 0 when the text doesn't end with it.
    nonisolated static func phraseSuffixLength(_ text: String) -> Int {
        guard let r = text.range(of: #"[\s,]*(?<![\w-])stop\s+dictation[\s.!?,]*$"#,
                                 options: [.regularExpression, .caseInsensitive]) else { return 0 }
        return text[r].count
    }

    func start() {
        guard enabled, !isListening else { return }
        timeout?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.stop() }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + maxListen, execute: t)
        if testAudio != nil { begin(); return }
        // Only the microphone needs a permission; on-device recognition doesn't.
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                if ok { self.begin() } else { self.log("Stop phrase off: microphone isn't allowed for SonyMenu") }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        timeout?.cancel()
        isListening = false
        generation = nil
        session?.stopRunning()
        feed?.finish()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        session = nil; sink = nil; feed = nil; analyzer = nil
        log("Stopped listening for \"stop dictation\"")
    }

    /// Uses macOS 26's on-device SpeechTranscriber, which works with Siri and Dictation turned
    /// off and without the Speech Recognition permission.
    private func begin() {
        guard SpeechTranscriber.isAvailable else {
            log("Stop phrase off: on-device speech recognition isn't available on this Mac"); return
        }
        let mic = Self.builtInMicrophone()
        guard testAudio != nil || mic != nil else {
            log("Stop phrase off: no built-in microphone (won't use the headphones' mic)"); return
        }
        let generation = UUID()
        self.generation = generation
        isListening = true
        Task { @MainActor in
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
                    throw Problem("English isn't supported by on-device recognition")
                }
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults, .fastResults],
                                                    attributeOptions: [])
                if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    log("Downloading Apple's on-device English speech model (one time)")
                    try await install.downloadAndInstall()
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw Problem("no audio format for on-device recognition")
                }
                guard self.generation == generation else { return }
                let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.start(inputSequence: stream)
                self.analyzer = analyzer
                self.feed = feed
                let sink = SampleSink(target: format, feed: feed)
                self.sink = sink

                if let file = testAudio {
                    let queue = audioQueue
                    queue.async { sink.play(file) }
                    log("Listening for \"stop dictation\" (test audio file)")
                } else if let mic {
                    // A capture session reads this one mic directly, without touching the default input.
                    let session = AVCaptureSession()
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(sink, queue: audioQueue)
                    guard let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input),
                          session.canAddOutput(output) else { throw Problem("couldn't open the built-in microphone") }
                    session.addInput(input)
                    session.addOutput(output)
                    session.startRunning()
                    guard session.isRunning else { throw Problem("the built-in microphone didn't start") }
                    self.session = session
                    log("Listening for \"stop dictation\" (built-in mic, on this Mac)")
                }

                var finished = ""
                for try await result in transcriber.results {
                    guard self.generation == generation, self.isListening else { break }
                    let text = String(result.text.characters)
                    if result.isFinal { finished = String((finished + " " + text).suffix(400)) }
                    let heardSoFar = result.isFinal ? finished : finished + " " + text
                    if self.onHeard != nil { log("heard: \(heardSoFar.trimmingCharacters(in: .whitespaces))") }
                    if Self.endsWithStopPhrase(heardSoFar) { self.heard(); break }
                }
            } catch {
                guard self.generation == generation else { return }
                log("Stop phrase off: \(error.localizedDescription)")
                self.stop()
            }
        }
    }

    private struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func heard() {
        log("Heard \"stop dictation\": finishing dictation")
        stop()
        if let onHeard { onHeard(); return }
        let clipboardBefore = NSPasteboard.general.changeCount
        GestureController.doubleTapOption() // Dictator: the same double tap ends hands-free dictation
        removePhrase(clipboardBefore: clipboardBefore)
    }

    /// Dictator finishes about a second later: with "Copy instead of pasting" on it puts the
    /// words on the clipboard, otherwise it pastes them. Wait for either, then take the phrase
    /// off the end.
    private func removePhrase(clipboardBefore: Int, attempt: Int = 0) {
        guard attempt < 120 else { log("Dictator's text didn't end with the phrase; left it as is"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let board = NSPasteboard.general
            if board.changeCount != clipboardBefore, let text = board.string(forType: .string) {
                let n = Self.phraseSuffixLength(text)
                if n > 0 {
                    let cleaned = String(text.dropLast(n))
                    board.clearContents()
                    board.setString(cleaned, forType: .string)
                    self.log("Removed \"stop dictation\" from the copied text")
                    return
                }
            }
            if let (value, caretAtEnd) = Self.focusedText(), caretAtEnd {
                let n = Self.phraseSuffixLength(value)
                if n > 0 {
                    Self.backspace(n)
                    self.log("Removed \"stop dictation\" from the pasted text")
                    return
                }
            }
            self.removePhrase(clipboardBefore: clipboardBefore, attempt: attempt + 1)
        }
    }

    // MARK: System helpers

    static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s { case .authorized: "allowed"; case .denied: "denied"; case .restricted: "restricted"
        case .notDetermined: "not asked yet"; @unknown default: "unknown" }
    }

    static func tapOption() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: down) else { continue }
            e.type = .flagsChanged
            e.flags = down ? .maskAlternate : []
            e.post(tap: .cghidEventTap)
        }
    }

    static func backspace(_ count: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<min(count, 40) {
            for down in [true, false] {
                CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
    }

    /// The focused text field's text, and whether the caret sits at its end.
    static func focusedText() -> (String, Bool)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let element = el as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        var rangeRef: CFTypeRef?
        var range = CFRange(location: 0, length: 0)
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() {
            AXValueGetValue(r as! AXValue, .cfRange, &range)
        } else {
            return (text, false)
        }
        let utf16Count = (text as NSString).length
        return (text, range.length == 0 && range.location == utf16Count)
    }

    /// The Mac's own microphone (never a Bluetooth one).
    static func builtInMicrophone() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
    }
}

/// Converts microphone audio to the analyzer's format, on the capture queue.
final class SampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let target: AVAudioFormat
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    init(target: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target; self.feed = feed
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.pcmBuffer(sampleBuffer), let out = convert(pcm) else { return }
        feed.yield(AnalyzerInput(buffer: out))
    }

    /// Test mode: plays an audio file in real time, then a few seconds of silence.
    func play(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600),
                  (try? file.read(into: buf)) != nil, buf.frameLength > 0, let out = convert(buf) else { break }
            feed.yield(AnalyzerInput(buffer: out))
            usleep(UInt32(Double(buf.frameLength) / file.processingFormat.sampleRate * 1_000_000))
        }
        if let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(target.sampleRate / 10)) {
            silence.frameLength = silence.frameCapacity
            for _ in 0..<40 { feed.yield(AnalyzerInput(buffer: silence)); usleep(100_000) }
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == target { return input }
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true
            outStatus.pointee = .haveData
            return input
        }
        return (status == .error || out.frameLength == 0) ? nil : out
    }

    static func pcmBuffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                                 into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
