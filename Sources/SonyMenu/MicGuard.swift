import CoreAudio
import Foundation

/// macOS makes a Bluetooth headset the default microphone the moment it connects, which
/// drops the headphones from stereo (A2DP) to the mono call profile (HFP). MicGuard puts
/// the Mac's built-in microphone back right after a Bluetooth input appears. Apps that pick
/// the headphone mic themselves still get it; only the automatic switch on connect is undone.
@MainActor
final class MicGuard: ObservableObject {
    static let shared = MicGuard()
    var log: (String) -> Void = { _ in }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "mic.keepBuiltIn") }
    }

    private var known = Set<AudioDeviceID>()

    private init() {
        enabled = UserDefaults.standard.object(forKey: "mic.keepBuiltIn") as? Bool ?? true
    }

    func start() {
        known = Set(Self.devices())
        // The headphones may have connected before SonyMenu launched (e.g. at login).
        if enabled { restoreBuiltIn(ifDefaultIn: known.filter { Self.isBluetooth($0) && Self.hasInput($0) }) }
        var addr = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
    }

    private func devicesChanged() {
        let now = Set(Self.devices())
        let added = now.subtracting(known).filter { Self.isBluetooth($0) && Self.hasInput($0) }
        known = now
        guard enabled, !added.isEmpty else { return }
        // macOS switches the default input a moment after the device shows up.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restoreBuiltIn(ifDefaultIn: added)
            }
        }
    }

    private func restoreBuiltIn(ifDefaultIn added: Set<AudioDeviceID>) {
        guard enabled, let current = Self.defaultInput(), added.contains(current),
              let builtIn = Self.devices().first(where: { Self.isBuiltIn($0) && Self.hasInput($0) }) else { return }
        var id = builtIn
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        log(status == noErr ? "Microphone: switched back to the built-in mic" : "Microphone: switch failed (\(status))")
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func devices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func isBuiltIn(_ id: AudioDeviceID) -> Bool { transport(id) == kAudioDeviceTransportTypeBuiltIn }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }
}
