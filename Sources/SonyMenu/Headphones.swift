import Foundation
import IOBluetooth

enum SoundMode: Equatable {
    case noiseCancelling, ambient, off
}

enum PlaybackState: Equatable { case unknown, playing, paused, stopped }

struct EqPreset: Identifiable, Hashable {
    let id: UInt8
    var name: String { L(nameKey) }
    private var nameKey: String {
        switch id {
        case 0x00: return "Off"
        case 0x10: return "Bright"
        case 0x11: return "Excited"
        case 0x12: return "Mellow"
        case 0x13: return "Relaxed"
        case 0x14: return "Vocal"
        case 0x15: return "Treble Boost"
        case 0x16: return "Bass Boost"
        case 0x17: return "Speech"
        case 0xA0: return "Custom"
        case 0xA1: return "User Setting 1"
        case 0xA2: return "User Setting 2"
        case 0xA3: return "User Setting 3"
        default: return String(format: "Preset 0x%02X", id)
        }
    }
}

/// What the left NC/AMB button cycles through (NcAsm NC_AMB_TOGGLE).
enum NcButtonCycle: UInt8, CaseIterable, Identifiable {
    case all = 0x01, ncAmbient = 0x02, ncOff = 0x03, ambientOff = 0x04
    var id: UInt8 { rawValue }
    var title: String { L(titleKey) }
    private var titleKey: String {
        switch self {
        case .all: return "Noise cancelling → Ambient → Off"
        case .ncAmbient: return "Noise cancelling ↔ Ambient"
        case .ncOff: return "Noise cancelling ↔ Off"
        case .ambientOff: return "Ambient ↔ Off"
        }
    }
}

/// Finds the paired Sony headphones, keeps an RFCOMM channel to them while they are
/// connected, and exposes their state and settings.
@MainActor
final class Headphones: NSObject, ObservableObject {
    // Audio link is up (the menu bar icon is shown).
    @Published var isPresent = false
    // Control channel is open and the headphones have answered.
    @Published private(set) var isReady = false
    @Published private(set) var name = L("Headphones")
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var problem: String?

    // Device info
    @Published private(set) var modelName: String?
    @Published private(set) var firmware: String?
    @Published private(set) var codec: String?
    @Published private(set) var supportT1: Set<UInt8> = []
    @Published private(set) var supportT2: Set<UInt8> = []

    // Noise cancelling / ambient
    @Published private(set) var mode: SoundMode?
    @Published var ambientLevel: Double = 10
    @Published private(set) var focusOnVoice = false
    @Published private(set) var ncButton: NcButtonCycle?

    // Sound
    @Published private(set) var eqPresets: [EqPreset] = []
    @Published private(set) var eqPreset: UInt8?
    @Published private(set) var eqAvailable = true
    /// Clear Bass first, then 400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz, 16 kHz; each −10…+10.
    @Published var eqBands: [Double] = Array(repeating: 0, count: 6)
    @Published private(set) var dsee: Bool?
    /// 0 = priority on sound quality, 1 = stable connection.
    @Published private(set) var connectionPriority: UInt8?

    // Speak-to-Chat
    @Published private(set) var speakToChat: Bool?
    @Published private(set) var stcSensitivity: UInt8?   // 0 auto, 1 high, 2 low
    @Published private(set) var stcTimeout: UInt8?       // 0 short, 1 standard, 2 long, 3 off

    // System
    @Published private(set) var autoPause: Bool?
    @Published private(set) var autoPowerOff: UInt8?
    @Published private(set) var autoPowerOffOptions: [UInt8] = []
    @Published private(set) var voiceAssistant: UInt8?
    @Published private(set) var voiceAssistantOptions: [UInt8] = []
    @Published private(set) var touchPanel: Bool?
    @Published private(set) var multipoint: Bool?
    /// Set when the headphones answered a multipoint change by keeping the old value.
    @Published private(set) var multipointRefused = false
    private var multipointWanted: Bool?
    @Published private(set) var voiceGuidance: Bool?

    // Playback
    @Published var volume: Double = 15
    @Published private(set) var volumeKnown = false
    @Published private(set) var playback: PlaybackState = .unknown

    var log: (String) -> Void = { _ in }
    /// Every MDR payload received (table 1 and table 2), for `--dump`.
    var onPayload: ((UInt8, [UInt8]) -> Void)?
    /// A gesture or sensor event the headphones logged (see `Gesture.eventKey`).
    var onEvent: ((String) -> Void)?
    /// A setting reply arrived: (command, inquired type). Used by `--selftest`.
    var onReply: ((UInt8, UInt8) -> Void)?

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNote: IOBluetoothUserNotification?
    private var parser = MDR.StreamParser()

    private var seq: UInt8 = 0
    private var queue: [[UInt8]] = []
    private var awaitingAck = false
    private var ackToken = 0

    private var ncType: UInt8 = Cmd.ncDualSeamless
    private var lastNcParams: [UInt8]?
    private var lastNcSetAt = Date.distantPast
    private var openAttempts = 0
    /// The RFCOMM channel reported open (a channel object alone can be stuck opening).
    private var channelOpen = false
    private var writeFailures = 0
    private var ackMisses = 0
    private var batteryTimer: Timer?
    private var stateRequested = false

    private let serviceUUID: IOBluetoothSDPUUID = {
        let hex = MDR.serviceUUID.replacingOccurrences(of: "-", with: "")
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return IOBluetoothSDPUUID(bytes: bytes, length: bytes.count)
    }()

    func supports(_ fn: UInt8) -> Bool { supportT1.contains(fn) }

    // MARK: - Lifecycle

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceDidConnect(_:device:)))
        if let d = findSonyDevice(connectedOnly: true) {
            attach(d)
        } else {
            log("Headphones not connected, waiting")
        }
    }

    private func findSonyDevice(connectedOnly: Bool) -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { d in
            (!connectedOnly || d.isConnected()) && d.getServiceRecord(for: serviceUUID) != nil
        }
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.getServiceRecord(for: serviceUUID) != nil else { return }
        attach(device)
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.addressString == self.device?.addressString else { return }
        log("Headphones disconnected")
        detach()
    }

    private func attach(_ d: IOBluetoothDevice) {
        if device?.addressString == d.addressString, channel != nil { return }
        device = d
        name = d.name ?? L("Headphones")
        isPresent = true
        problem = nil
        disconnectNote?.unregister()
        disconnectNote = d.register(forDisconnectNotification: self,
                                    selector: #selector(deviceDidDisconnect(_:device:)))
        openAttempts = 0
        // Give the audio profiles a moment to settle before opening the control channel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openChannel() }
    }

    /// Closes the control channel cleanly, so the headphones accept a new one right away.
    func stop() {
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
    }

    private func detach() {
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        disconnectNote?.unregister()
        disconnectNote = nil
        device = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        queue.removeAll()
        awaitingAck = false
        seq = 0
        parser = MDR.StreamParser()
        lastNcParams = nil
        stateRequested = false
        isReady = false
        isPresent = false
        battery = nil
        mode = nil
        codec = nil
        playback = .unknown
    }

    private func openChannel() {
        guard let d = device, channel == nil else { return }
        openAttempts += 1
        guard let record = d.getServiceRecord(for: serviceUUID) else {
            problem = L("Headphones are not responding")
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            problem = L("Control channel not found")
            return
        }
        var ch: IOBluetoothRFCOMMChannel?
        let result = d.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
        if result != kIOReturnSuccess {
            log("Channel did not open: \(String(format: "0x%x", result))")
            retryOpen()
            return
        }
        channel = ch
        channelOpen = false
        log("Opening channel \(channelID)")
        // An async open can hang without ever calling back; don't wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let ch, self.channel === ch, !self.channelOpen else { return }
            self.log("Channel open timed out")
            self.resetChannel()
        }
    }

    /// Drops a broken channel and opens a fresh one.
    private func resetChannel() {
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        channelOpen = false
        isReady = false
        stateRequested = false
        awaitingAck = false
        queue.removeAll()
        parser = MDR.StreamParser()
        seq = 0
        writeFailures = 0
        ackMisses = 0
        retryOpen()
    }

    private func retryOpen() {
        channel = nil
        channelOpen = false
        guard let d = device, d.isConnected() else { return }
        if openAttempts >= 4 {
            problem = L("Couldn't connect to the headphone controls. Is the Sony app open on another device?")
        }
        // Keep trying while the headphones are connected: 2, 4, 8, 16, then every 30 s.
        let delay = min(30.0, 2.0 * pow(2.0, Double(max(0, openAttempts - 1))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.openChannel() }
    }

    fileprivate func channelOpened(_ ch: IOBluetoothRFCOMMChannel, status: IOReturn) {
        guard ch === channel else { return }
        guard status == kIOReturnSuccess else {
            log("Channel failed to open: \(String(format: "0x%x", status))")
            retryOpen()
            return
        }
        log("Channel open")
        channelOpen = true
        openAttempts = 0
        problem = nil
        send([Cmd.getProtocolInfo, 0x00])
        // Some firmwares answer only after the handshake; ask for state anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.channel != nil, !self.stateRequested else { return }
            self.requestSupport()
        }
    }

    fileprivate func channelClosed(_ ch: IOBluetoothRFCOMMChannel) {
        guard ch === channel else { return }
        log("Channel closed")
        if device?.isConnected() == true { resetChannel() } else { detach() }
    }

    // MARK: - Sending

    private func send(_ payload: [UInt8], table2: Bool = false) {
        queue.append((table2 ? [0xFF] : []) + payload)
        pump()
    }

    /// Sends an arbitrary payload (used by `--dump`, which only sends GET requests).
    func sendRaw(_ payload: [UInt8], table2: Bool = false) { send(payload, table2: table2) }

    private func pump() {
        guard !awaitingAck, channel != nil, !queue.isEmpty else { return }
        var payload = queue.removeFirst()
        var type = MDR.DataType.dataMDR
        if payload.first == 0xFF { payload.removeFirst(); type = .dataMDRNo2 }
        write(MDR.pack(type: type, seq: seq, payload: payload))
        awaitingAck = true
        ackToken += 1
        let token = ackToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.awaitingAck, self.ackToken == token else { return }
            self.awaitingAck = false
            self.ackMisses += 1
            if self.ackMisses >= 3 {
                self.log("Headphones stopped answering, reconnecting")
                self.resetChannel()
                return
            }
            self.pump()
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let ch = channel else { return }
        var data = bytes
        let r = data.withUnsafeMutableBytes { ptr in
            ch.writeSync(ptr.baseAddress, length: UInt16(ptr.count))
        }
        guard r == kIOReturnSuccess else {
            log("Write error: \(String(format: "0x%x", r))")
            writeFailures += 1
            if writeFailures >= 2 { log("Control channel broken, reconnecting"); resetChannel() }
            return
        }
        writeFailures = 0
    }

    // MARK: - Receiving

    fileprivate func received(_ bytes: [UInt8]) {
        for frame in parser.feed(bytes) {
            switch frame.type {
            case MDR.DataType.ack.rawValue:
                seq = 1 &- seq
                awaitingAck = false
                ackMisses = 0
                pump()
            case MDR.DataType.dataMDR.rawValue, MDR.DataType.dataMDRNo2.rawValue:
                write(MDR.pack(type: .ack, seq: 1 &- frame.seq, payload: []))
                onPayload?(frame.type, frame.payload)
                if frame.type == MDR.DataType.dataMDR.rawValue { handle(frame.payload) } else { handleT2(frame.payload) }
            default:
                break
            }
        }
    }

    private func hex(_ p: [UInt8]) -> String { p.map { String(format: "%02x", $0) }.joined() }

    private func handle(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        let cmd = p[0], type = p[1]
        switch cmd {
        case Cmd.retProtocolInfo:
            log("Protocol: \(p.count >= 6 ? String(p[2...5].reduce(0) { $0 << 8 | Int($1) }, radix: 16) : "?")")
            requestSupport()

        case Cmd.retSupport:
            guard p.count >= 3 else { return }
            var set = Set<UInt8>()
            var i = 3
            while i + 1 < p.count, set.count < Int(p[2]) { set.insert(p[i]); i += 2 }
            supportT1 = set
            log("Supported functions: \(set.count)")
            requestState()

        case Cmd.retDeviceInfo:
            var i = 2
            if type == 0x01 { modelName = MDR.string(p, at: &i) }
            if type == 0x02 {
                firmware = MDR.string(p, at: &i).map { String($0.filter { $0.isASCII && ($0.isNumber || $0 == ".") }.prefix(16)) }
                log("Firmware \(firmware ?? "?")")
            }

        case Cmd.commonRetStatus, Cmd.commonNtfyStatus:
            if type == Cmd.codecInquiry, p.count >= 3 { codec = Self.codecName(p[2]) }

        case Cmd.powerRetStatus, Cmd.powerNtfyStatus:
            guard p.count >= 4, type == Cmd.powerBattery else { return }
            battery = Int(p[2])
            charging = p[3] == 0x01
            isReady = true
            log("Battery: \(p[2])%\(charging ? ", charging" : "")")

        case Cmd.powerRetCapability:
            if type == Cmd.powerAutoOffWearing, p.count >= 3 {
                autoPowerOffOptions = Array(p.dropFirst(3).prefix(Int(p[2])))
            }
        case Cmd.powerRetParam, Cmd.powerNtfyParam:
            if type == Cmd.powerAutoOffWearing, p.count >= 3 { autoPowerOff = p[2]; reply(cmd, type) }

        case Cmd.ncAsmRetParam, Cmd.ncAsmNtfyParam:
            if type == Cmd.ncAmbToggle {
                if p.count >= 3 { ncButton = NcButtonCycle(rawValue: p[2]); reply(cmd, type) }
                return
            }
            guard p.count >= 7, type == Cmd.ncDualSeamless || type == Cmd.ncDualSeamlessNA else {
                log("Unknown NC format: \(hex(p))")
                return
            }
            ncType = type
            lastNcParams = p
            let newMode: SoundMode = p[3] == 0 ? .off : (p[4] == 0 ? .noiseCancelling : .ambient)
            mode = newMode
            focusOnVoice = p[5] == 0x01
            if p[6] > 0 { ambientLevel = Double(p[6]) }
            isReady = true
            reply(cmd, type)
            log("Mode: \(newMode), level \(p[6]), voice \(focusOnVoice)")

        case Cmd.eqRetCapability:
            // [51, type, bandCount, stepCount, presetCount, (id, name)...]
            guard p.count >= 5 else { return }
            var presets: [EqPreset] = []
            var i = 5
            while i < p.count, presets.count < Int(p[4]) {
                let id = p[i]; i += 1
                _ = MDR.string(p, at: &i)
                presets.append(EqPreset(id: id))
            }
            eqPresets = presets
        case Cmd.eqRetStatus, Cmd.eqNtfyStatus:
            if type == 0x00, p.count >= 3 { eqAvailable = p[2] == 0x00 }
        case Cmd.eqRetParam, Cmd.eqNtfyParam:
            guard type == 0x00, p.count >= 4 else { return }
            eqPreset = p[2]
            let n = Int(p[3])
            if n == 6, p.count >= 4 + n { eqBands = p[4..<(4 + n)].map { Double(Int($0) - 10) } }
            reply(cmd, type)

        case Cmd.gsRetParam, Cmd.gsNtfyParam:
            guard p.count >= 4 else { return }
            if type == Cmd.gsTouchPanel { touchPanel = p[3] == 0x00 }
            if type == Cmd.gsMultipoint {
                let now = p[3] == 0x00
                if let wanted = multipointWanted, cmd == Cmd.gsNtfyParam {
                    multipointWanted = nil
                    multipointRefused = wanted != now
                    if wanted != now { log("Headphones refused to turn multipoint \(wanted ? "on" : "off")") }
                }
                multipoint = now
            }
            reply(cmd, type)

        case Cmd.audioRetParam, Cmd.audioNtfyParam:
            guard p.count >= 3 else { return }
            if type == Cmd.audioConnection { connectionPriority = p[2] }
            if type == Cmd.audioUpscaling { dsee = p[2] == 0x01 }
            reply(cmd, type)

        case Cmd.systemRetCapability:
            if type == Cmd.sysVoiceAssistant, p.count >= 4 {
                voiceAssistantOptions = Array(p.dropFirst(4).prefix(Int(p[3])))
            }
        case Cmd.systemRetParam, Cmd.systemNtfyParam:
            guard p.count >= 3 else { return }
            switch type {
            case Cmd.sysSpeakToChat: speakToChat = p[2] == 0x00
            case Cmd.sysAutoPause: autoPause = p[2] == 0x00
            case Cmd.sysVoiceAssistant: voiceAssistant = p[2]
            default: break
            }
            reply(cmd, type)
        case Cmd.systemRetExtParam, Cmd.systemNtfyExtParam:
            if type == Cmd.sysSpeakToChat, p.count >= 4 {
                stcSensitivity = p[2]; stcTimeout = p[3]; reply(cmd, type)
            }

        case Cmd.playRetParam, Cmd.playNtfyParam:
            if type == Cmd.playVolume, p.count >= 3 { volume = Double(p[2]); volumeKnown = true; reply(cmd, type) }
        case Cmd.playRetStatus, Cmd.playNtfyStatus:
            if type == Cmd.playController, p.count >= 4 {
                playback = [1: .playing, 2: .paused, 3: .stopped][p[3]] ?? .unknown
                reply(cmd, type)
            }

        case Cmd.logNtfyParam:
            // Time-series operation log: what the user just did on the headphones, e.g.
            // "keyRDoubleTap", "keyCustomBtnHold", "opQAStart", "unitWear". Keys come with a
            // one-byte length; "op…" entries with a two-byte length and a trailing zero.
            if type == 0x01, p.count > 3 {
                var i = p[2] == 0 ? 3 : 2
                // Device-provided text: keep it to short plain ASCII before logging or matching.
                let key = String((MDR.string(p, at: &i) ?? "").unicodeScalars
                    .filter { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil) }
                    .prefix(40).map(Character.init))
                log("Headphone event: \(key.isEmpty ? "(raw \(hex(p)))" : key)")
                if !key.isEmpty { onEvent?(key) }
            }

        default:
            break
        }
    }

    private func handleT2(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        switch p[0] {
        case Cmd.retSupport:
            var set = Set<UInt8>()
            var i = 3
            while p.count >= 3, i + 1 < p.count, set.count < Int(p[2]) { set.insert(p[i]); i += 2 }
            supportT2 = set
            if set.contains(Fn.t2VoiceGuidance) { send([Cmd.t2VoiceGuidanceGetParam, Cmd.vgOnOff], table2: true) }
        case Cmd.t2VoiceGuidanceRetParam, Cmd.t2VoiceGuidanceNtfyParam:
            if p[1] == Cmd.vgOnOff, p.count >= 3 { voiceGuidance = p[2] == 0x00; reply(p[0], p[1] | 0x80) }
        default:
            break
        }
    }

    private func reply(_ cmd: UInt8, _ type: UInt8) { onReply?(cmd, type) }

    static func codecName(_ b: UInt8) -> String? {
        switch b {
        case 0x01: return "SBC"
        case 0x02: return "AAC"
        case 0x10: return "LDAC"
        case 0x20: return "aptX"
        case 0x21: return "aptX HD"
        case 0x30: return "LC3"
        default: return nil
        }
    }

    private func requestSupport() {
        guard !stateRequested else { return }
        stateRequested = true
        send([Cmd.getSupport, 0x00])
        send([Cmd.getSupport, 0x00], table2: true)
        send([Cmd.powerGetStatus, Cmd.powerBattery])
        send([Cmd.ncAsmGetParam, ncType])
        // Without a support list (old firmware) keep the original battery + NC behaviour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.channel != nil, self.lastNcParams == nil, self.supportT1.isEmpty else { return }
            self.ncType = Cmd.ncDualSeamlessNA
            self.send([Cmd.ncAsmGetParam, self.ncType])
        }
        if batteryTimer == nil {
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.send([Cmd.powerGetStatus, Cmd.powerBattery]) }
            }
        }
    }

    /// Reads every setting the headphones say they support. GET requests only.
    private func requestState() {
        send([Cmd.getDeviceInfo, 0x01])
        send([Cmd.getDeviceInfo, 0x02])
        if supports(Fn.codec) { send([Cmd.commonGetStatus, Cmd.codecInquiry]) }
        if supports(Fn.ncButton) { send([Cmd.ncAsmGetParam, Cmd.ncAmbToggle]) }
        if supports(Fn.presetEq) {
            send([Cmd.eqGetCapability, 0x00, 0x01])
            send([Cmd.eqGetStatus, 0x00])
            send([Cmd.eqGetParam, 0x00])
        }
        if supports(Fn.connectionMode) { send([Cmd.audioGetParam, Cmd.audioConnection]) }
        if supports(Fn.dsee) { send([Cmd.audioGetParam, Cmd.audioUpscaling]) }
        if supports(Fn.speakToChat) {
            send([Cmd.systemGetParam, Cmd.sysSpeakToChat])
            send([Cmd.systemGetExtParam, Cmd.sysSpeakToChat])
        }
        if supports(Fn.autoPause) { send([Cmd.systemGetParam, Cmd.sysAutoPause]) }
        if supports(Fn.voiceAssistant) {
            send([Cmd.systemGetCapability, Cmd.sysVoiceAssistant])
            send([Cmd.systemGetParam, Cmd.sysVoiceAssistant])
        }
        if supports(Fn.autoPowerOffWearing) {
            send([Cmd.powerGetCapability, Cmd.powerAutoOffWearing])
            send([Cmd.powerGetParam, Cmd.powerAutoOffWearing])
        }
        if supports(Fn.gs1) { send([Cmd.gsGetParam, Cmd.gsTouchPanel]) }
        if supports(Fn.gs2) { send([Cmd.gsGetParam, Cmd.gsMultipoint]) }
        if supports(Fn.playback) {
            send([Cmd.playGetParam, Cmd.playVolume])
            send([Cmd.playGetStatus, Cmd.playController])
        }
        // Wear/remove and similar events, if the firmware reports any, go to the log.
        if supports(Fn.timeSeriesLog) { send([Cmd.logSetStatus, 0x01, 0x00]) }
    }

    /// For `--mediatest`: pretend the control link is up or down.
    func simulateLink(_ up: Bool) { isReady = up; isPresent = true }

    /// Sample state for `--snapshot` renders.
    func loadSampleState(mode: SoundMode) {
        name = "WH-1000XM5"
        battery = 85
        charging = mode != .ambient
        self.mode = mode
        ambientLevel = 14
        focusOnVoice = true
        isPresent = true
        isReady = true
        modelName = "WH-1000XM5"
        firmware = "2.3.1"
        codec = "AAC"
        supportT1 = [Fn.codec, Fn.powerOff, Fn.autoPowerOffWearing, Fn.gs1, Fn.gs2, Fn.presetEq, Fn.ncDual,
                     Fn.ncButton, Fn.playback, Fn.connectionMode, Fn.dsee, Fn.voiceAssistant, Fn.autoPause,
                     Fn.speakToChat]
        supportT2 = [Fn.t2VoiceGuidance]
        ncButton = .ncAmbient
        eqPresets = [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0, 0xA1, 0xA2].map(EqPreset.init)
        eqPreset = 0x16
        eqBands = [3, 2, 1, 0, 1, 2]
        dsee = true
        connectionPriority = 0
        speakToChat = false
        stcSensitivity = 0
        stcTimeout = 1
        autoPause = true
        autoPowerOff = 0x10
        autoPowerOffOptions = [0x10, 0x11]
        voiceAssistant = 0xFF
        voiceAssistantOptions = [0x30, 0x31, 0x32, 0xFF]
        touchPanel = true
        multipoint = true
        voiceGuidance = true
        volume = 15
        volumeKnown = true
        playback = .playing
    }

    // MARK: - Controls (each only after the headphones listed the function as supported)

    func setMode(_ newMode: SoundMode) {
        mode = newMode
        sendNc()
    }

    func setFocusOnVoice(_ on: Bool) {
        focusOnVoice = on
        sendNc()
    }

    /// Call when the level slider is released.
    func commitAmbientLevel() {
        sendNc()
    }

    /// Next mode in the order the left button uses.
    func cycleMode() {
        let order: [SoundMode]
        switch ncButton ?? .all {
        case .all: order = [.noiseCancelling, .ambient, .off]
        case .ncAmbient: order = [.noiseCancelling, .ambient]
        case .ncOff: order = [.noiseCancelling, .off]
        case .ambientOff: order = [.ambient, .off]
        }
        let i = mode.flatMap { order.firstIndex(of: $0) } ?? -1
        setMode(order[(i + 1) % order.count])
    }

    private func sendNc() {
        guard let mode else { return }
        var p = lastNcParams ?? [Cmd.ncAsmRetParam, ncType, 0x01, 0x01, 0x00, 0x00, 0x0A]
        if p[1] == Cmd.ncDualSeamlessNA && p.count < 9 { p += [0x00, 0x00] }
        p[0] = Cmd.ncAsmSetParam
        p[2] = 0x01                                   // value changed (not dragging)
        p[3] = mode == .off ? 0x00 : 0x01             // NC/ASM on
        if mode != .off { p[4] = mode == .ambient ? 0x01 : 0x00 }
        p[5] = focusOnVoice ? 0x01 : 0x00
        p[6] = UInt8(max(1, min(20, ambientLevel.rounded())))
        var stored = p
        stored[0] = Cmd.ncAsmRetParam
        lastNcParams = stored
        lastNcSetAt = Date()
        send(p)
    }

    func setNcButton(_ cycle: NcButtonCycle) {
        guard supports(Fn.ncButton) else { return }
        ncButton = cycle
        send([Cmd.ncAsmSetParam, Cmd.ncAmbToggle, cycle.rawValue])
    }

    func setEqPreset(_ id: UInt8) {
        guard supports(Fn.presetEq) else { return }
        eqPreset = id
        send([Cmd.eqSetParam, 0x00, id, 0x00])
        send([Cmd.eqGetParam, 0x00])
    }

    /// Sends the six band values (Clear Bass + 5 bands). Editing bands selects a custom slot.
    func commitEqBands() {
        guard supports(Fn.presetEq) else { return }
        let custom: Set<UInt8> = [0xA0, 0xA1, 0xA2, 0xA3]
        let target = eqPreset.flatMap { custom.contains($0) ? $0 : nil } ?? 0xA0
        eqPreset = target
        let steps = eqBands.map { UInt8(max(0, min(20, Int($0.rounded()) + 10))) }
        send([Cmd.eqSetParam, 0x00, target, UInt8(steps.count)] + steps)
        send([Cmd.eqGetParam, 0x00])
    }

    func setDsee(_ on: Bool) {
        guard supports(Fn.dsee) else { return }
        dsee = on
        send([Cmd.audioSetParam, Cmd.audioUpscaling, on ? 0x01 : 0x00])
    }

    func setConnectionPriority(_ v: UInt8) {
        guard supports(Fn.connectionMode) else { return }
        connectionPriority = v
        send([Cmd.audioSetParam, Cmd.audioConnection, v])
    }

    func setSpeakToChat(_ on: Bool) {
        guard supports(Fn.speakToChat) else { return }
        speakToChat = on
        send([Cmd.systemSetParam, Cmd.sysSpeakToChat, on ? 0x00 : 0x01, 0x01])
    }

    func setSpeakToChat(sensitivity: UInt8? = nil, timeout: UInt8? = nil) {
        guard supports(Fn.speakToChat) else { return }
        if let sensitivity { stcSensitivity = sensitivity }
        if let timeout { stcTimeout = timeout }
        send([Cmd.systemSetExtParam, Cmd.sysSpeakToChat, stcSensitivity ?? 0, stcTimeout ?? 1])
    }

    func setAutoPause(_ on: Bool) {
        guard supports(Fn.autoPause) else { return }
        autoPause = on
        send([Cmd.systemSetParam, Cmd.sysAutoPause, on ? 0x00 : 0x01])
    }

    func setVoiceAssistant(_ v: UInt8) {
        guard supports(Fn.voiceAssistant) else { return }
        voiceAssistant = v
        send([Cmd.systemSetParam, Cmd.sysVoiceAssistant, v])
    }

    func setAutoPowerOff(_ v: UInt8) {
        guard supports(Fn.autoPowerOffWearing) else { return }
        autoPowerOff = v
        send([Cmd.powerSetParam, Cmd.powerAutoOffWearing, v, 0x00])
    }

    func setTouchPanel(_ on: Bool) {
        guard supports(Fn.gs1) else { return }
        touchPanel = on
        send([Cmd.gsSetParam, Cmd.gsTouchPanel, 0x00, on ? 0x00 : 0x01])
    }

    /// Diagnostics only (--rawset).
    func sendRaw(_ bytes: [UInt8]) { send(bytes) }

    func setMultipoint(_ on: Bool) {
        guard supports(Fn.gs2) else { return }
        multipoint = on
        multipointWanted = on
        multipointRefused = false
        send([Cmd.gsSetParam, Cmd.gsMultipoint, 0x00, on ? 0x00 : 0x01])
    }

    func setVoiceGuidance(_ on: Bool) {
        guard supportT2.contains(Fn.t2VoiceGuidance) else { return }
        voiceGuidance = on
        send([Cmd.t2VoiceGuidanceSetParam, Cmd.vgOnOff, on ? 0x00 : 0x01], table2: true)
    }

    /// Headphone volume, 0…30. Call when the slider is released.
    func commitVolume() {
        guard supports(Fn.playback) else { return }
        send([Cmd.playSetParam, Cmd.playVolume, UInt8(max(0, min(30, volume.rounded())))])
    }

    enum PlayControl: UInt8 { case pause = 0x01, next = 0x02, previous = 0x03, play = 0x07 }

    /// Asks the headphones to send the command to the playing device (AVRCP), like a touch would.
    func playControl(_ c: PlayControl) {
        guard supports(Fn.playback) else { return }
        send([Cmd.playSetStatus, Cmd.playController, 0x00, c.rawValue])
    }

    func togglePlayback() { playControl(playback == .playing ? .pause : .play) }

    func powerOff() {
        guard supports(Fn.powerOff) else { return }
        send([Cmd.powerSetStatus, Cmd.powerOff, 0x01])
    }
}

extension Headphones: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated { channelOpened(rfcommChannel, status: error) }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                       data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { received(bytes) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated { channelClosed(rfcommChannel) }
    }
}
