import AppKit
import SwiftUI

/// Settings window: device options, sound, Speak-to-Chat, and gesture remapping.
struct SettingsView: View {
    @EnvironmentObject private var hp: Headphones
    @StateObject private var ui = SettingsUI()
    var initialTab: SettingsTab?

    var body: some View {
        TabView(selection: $ui.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "headphones") }.tag(SettingsTab.general)
            SoundTab().tabItem { Label("Sound", systemImage: "slider.vertical.3") }.tag(SettingsTab.sound)
            ControlsTab().tabItem { Label("Controls", systemImage: "hand.tap") }.tag(SettingsTab.controls)
        }
        .frame(width: 560, height: 600)
        .onAppear { if let initialTab { ui.tab = initialTab } }
    }
}

/// Gestures the XM5 has but the app can't use, and why.
struct UnavailableGesture: Identifiable {
    let id = UUID()
    let title: String
    let reason: String

    static let all: [UnavailableGesture] = [
        .init(title: L("Two-finger tap (short)"),
              reason: L("Not a gesture on the WH-1000XM5: the headphones report nothing. Two-finger touch and hold works.")),
        .init(title: L("Stopping the headphones' own volume, assistant, Speak-to-Chat or Quick Attention"),
              reason: L("These happen inside the headphones or over Bluetooth audio, so the Mac can add an action but not cancel theirs. Turn the touch panel off to stop all right-side gestures.")),
        .init(title: L("Quick Access (double / triple press of the NC/AMB button)"),
              reason: L("Set up only in Sony's phone app; it launches Spotify Tap or Endel on the phone.")),
    ]
}

enum SettingsTab: Hashable { case general, sound, controls }

/// View state kept outside SwiftUI's `@State` (the Command Line Tools lack its macro plugin).
final class SettingsUI: ObservableObject {
    @Published var tab = SettingsTab.general
    @Published var confirmPowerOff = false
}

private struct NotConnected: View {
    var body: some View {
        Text("Connect your headphones to change these settings.")
            .foregroundStyle(.secondary)
    }
}

private extension View {
    /// Shows the setting only when the headphones said they support it.
    @ViewBuilder func supported(_ ok: Bool) -> some View {
        if ok { self }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var hp: Headphones
    @ObservedObject private var loginItem = LoginItem.shared
    @ObservedObject private var prefs = PanelPrefs.shared
    @ObservedObject private var micGuard = MicGuard.shared
    @StateObject private var ui = SettingsUI()

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Model", value: hp.modelName ?? hp.name)
                LabeledContent("Firmware", value: hp.firmware ?? "—")
                LabeledContent("Battery", value: hp.battery.map { hp.charging ? String(format: L("%d%% (charging)"), $0) : "\($0)%" } ?? "—")
                LabeledContent("Codec", value: hp.codec ?? "—")
            }

            Section("App") {
                Toggle("Launch SonyMenu at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                Toggle(isOn: $prefs.showSound) {
                    Text("Show sound settings in the menu bar panel")
                    Text("Equalizer, DSEE Extreme, Speak-to-Chat.")
                }
                Toggle(isOn: $prefs.showPlayback) {
                    Text("Show playback controls in the menu bar panel")
                    Text("Previous / Play-Pause / Next and headphone volume.")
                }
                Toggle(isOn: $micGuard.enabled) {
                    Text("Keep the Mac's microphone when the headphones connect")
                    Text("macOS switches to the headphone mic on connect, which makes the sound mono. Apps that choose the headphone mic still get it.")
                }
            }

            if hp.isReady {
                Section("Connection") {
                    if hp.supports(Fn.connectionMode), let v = hp.connectionPriority {
                        Picker("Bluetooth connection quality", selection: Binding(get: { v }, set: { hp.setConnectionPriority($0) })) {
                            Text("Priority on sound quality").tag(UInt8(0))
                            Text("Priority on stable connection").tag(UInt8(1))
                        }
                    }
                    if hp.supports(Fn.gs2), let mp = hp.multipoint {
                        Toggle(isOn: Binding(get: { mp }, set: { hp.setMultipoint($0) })) {
                            Text("Connect to 2 devices at once (multipoint)")
                            Text("The headphones may reconnect when you change this.")
                        }
                    }
                }

                Section("Power & wearing") {
                    if hp.supports(Fn.autoPowerOffWearing), let v = hp.autoPowerOff {
                        Picker("Automatic power off", selection: Binding(get: { v }, set: { hp.setAutoPowerOff($0) })) {
                            ForEach(hp.autoPowerOffOptions.isEmpty ? [v] : hp.autoPowerOffOptions, id: \.self) { o in
                                Text(Self.powerOffTitle(o)).tag(o)
                            }
                        }
                    }
                    if hp.supports(Fn.autoPause), let on = hp.autoPause {
                        Toggle("Pause music when the headphones are taken off",
                               isOn: Binding(get: { on }, set: { hp.setAutoPause($0) }))
                    }
                    if let vg = hp.voiceGuidance {
                        Toggle("Voice guidance (spoken notifications)",
                               isOn: Binding(get: { vg }, set: { hp.setVoiceGuidance($0) }))
                    }
                    if hp.supports(Fn.powerOff) {
                        Button("Turn off headphones…", role: .destructive) { ui.confirmPowerOff = true }
                            .confirmationDialog("Turn off the headphones?", isPresented: $ui.confirmPowerOff) {
                                Button("Turn Off", role: .destructive) { hp.powerOff() }
                            } message: {
                                Text("Press the power button on the headphones to turn them back on.")
                            }
                    }
                }
            } else {
                Section { NotConnected() }
            }
        }
        .formStyle(.grouped)
    }

    static func powerOffTitle(_ v: UInt8) -> String { L(powerOffKey(v)) }

    private static func powerOffKey(_ v: UInt8) -> String {
        switch v {
        case 0x00: return "After 5 minutes"
        case 0x01: return "After 30 minutes"
        case 0x02: return "After 1 hour"
        case 0x03: return "After 3 hours"
        case 0x04: return "After 15 minutes"
        case 0x10: return "When taken off"
        case 0x11: return "Never"
        default: return String(format: "Option 0x%02X", v)
        }
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @EnvironmentObject private var hp: Headphones
    private let bandNames = ["Clear Bass", "400", "1k", "2.5k", "6.3k", "16k"]

    var body: some View {
        Form {
            if !hp.isReady {
                Section { NotConnected() }
            } else {
                Section("Ambient sound") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Level")
                            Spacer()
                            Text("\(Int(hp.ambientLevel.rounded()))").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $hp.ambientLevel, in: 1...20) { editing in
                            if !editing {
                                if hp.mode != .ambient { hp.setMode(.ambient) } else { hp.commitAmbientLevel() }
                            }
                        }
                    }
                    Toggle("Focus on voice", isOn: Binding(get: { hp.focusOnVoice }, set: { hp.setFocusOnVoice($0) }))
                }

                if hp.supports(Fn.presetEq) {
                    Section {
                        Picker("Preset", selection: Binding(get: { hp.eqPreset ?? 0 }, set: { hp.setEqPreset($0) })) {
                            ForEach(hp.eqPresets) { Text($0.name).tag($0.id) }
                        }
                        HStack(alignment: .bottom, spacing: 14) {
                            ForEach(0..<6, id: \.self) { i in
                                VStack(spacing: 6) {
                                    Text(String(format: "%+d", Int(hp.eqBands[i].rounded())))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    VerticalSlider(value: $hp.eqBands[i], range: -10...10) { hp.commitEqBands() }
                                        .frame(width: 22, height: 130)
                                    Text(bandNames[i])
                                        .font(.caption2)
                                        .foregroundStyle(i == 0 ? .primary : .secondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .frame(maxWidth: .infinity)
                                if i == 0 { Divider().frame(height: 150) }
                            }
                        }
                        .padding(.vertical, 6)
                        Button("Reset bands to 0") {
                            hp.eqBands = Array(repeating: 0, count: 6)
                            hp.commitEqBands()
                        }
                    } header: {
                        Text("Equalizer")
                    } footer: {
                        if !hp.eqAvailable {
                            Text("The headphones report the equalizer as unavailable right now.")
                        } else {
                            Text("Moving a band switches to a custom preset, as in Sony's app. Clear Bass is the left slider.")
                        }
                    }
                }

                if hp.supports(Fn.dsee), let dsee = hp.dsee {
                    Section {
                        Toggle("DSEE Extreme", isOn: Binding(get: { dsee }, set: { hp.setDsee($0) }))
                    } footer: {
                        Text("Restores detail in compressed music. Works only with \"Priority on sound quality\".")
                    }
                }

                if hp.supports(Fn.speakToChat), let stc = hp.speakToChat {
                    Section("Speak-to-Chat") {
                        Toggle("Pause music when I start talking", isOn: Binding(get: { stc }, set: { hp.setSpeakToChat($0) }))
                        Picker("Voice detection sensitivity", selection: Binding(
                            get: { hp.stcSensitivity ?? 0 }, set: { hp.setSpeakToChat(sensitivity: $0) })) {
                            Text("Auto").tag(UInt8(0))
                            Text("High").tag(UInt8(1))
                            Text("Low").tag(UInt8(2))
                        }
                        Picker("Resume music after", selection: Binding(
                            get: { hp.stcTimeout ?? 1 }, set: { hp.setSpeakToChat(timeout: $0) })) {
                            Text("Short (about 5 s)").tag(UInt8(0))
                            Text("Standard (about 15 s)").tag(UInt8(1))
                            Text("Long (about 30 s)").tag(UInt8(2))
                            Text("Don't end automatically").tag(UInt8(3))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A vertical slider that reports when the drag ends.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary).frame(width: 4)
                Capsule().fill(Color.dsAccent).frame(width: 4, height: max(0, h * t))
                Circle()
                    .fill(.white)
                    .shadow(radius: 1, y: 0.5)
                    .frame(width: 16, height: 16)
                    .offset(y: -h * t + 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = 1 - min(max(g.location.y / h, 0), 1)
                    value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                }
                .onEnded { _ in onCommit() })
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { dir in
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? 1 : -1)))
            onCommit()
        }
    }
}

// MARK: - Controls

private struct ControlsTab: View {
    @EnvironmentObject private var hp: Headphones
    @ObservedObject private var gestures = GestureController.shared

    var body: some View {
        Form {
            if hp.isReady {
                Section("Headphone buttons") {
                    if hp.supports(Fn.gs1), let on = hp.touchPanel {
                        Toggle(isOn: Binding(get: { on }, set: { hp.setTouchPanel($0) })) {
                            Text("Touch sensor control panel (right earcup)")
                            Text("Turn off to ignore all taps and swipes.")
                        }
                    }
                    if hp.supports(Fn.ncButton), let cycle = hp.ncButton {
                        Picker("Left NC/AMB button switches", selection: Binding(get: { cycle }, set: { hp.setNcButton($0) })) {
                            ForEach(NcButtonCycle.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if hp.supports(Fn.voiceAssistant), let va = hp.voiceAssistant {
                        Picker("Right: touch and hold", selection: Binding(get: { va }, set: { hp.setVoiceAssistant($0) })) {
                            Text("Voice assistant of the connected device (Siri)").tag(UInt8(0x30))
                            Text("Does nothing").tag(UInt8(0xFF))
                            if va != 0x30 && va != 0xFF { Text("Set in Sony's app").tag(va) }
                        }
                    }
                }
            }

            gestureSection(L("Right earcup (touch panel)"), Gesture.allCases.filter { !$0.isLeft })
            gestureSection(L("Left earcup (NC/AMB button)"), Gesture.allCases.filter(\.isLeft))

            Section {
                Toggle(isOn: $gestures.includeKeyboard) {
                    Text("Also treat the keyboard's media keys as these gestures")
                    Text("Off: keyboard Play/Next/Previous keys work as usual.")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Media actions go to whatever is playing, including YouTube in Safari or Chrome.")
                    if let e = gestures.lastEvent { Text("Last gesture: \(e)").foregroundStyle(.secondary) }
                }
            }

            Section("Permission") {
                HStack {
                    Image(systemName: gestures.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(gestures.accessibilityGranted ? Color.dsGreen : Color.dsOrange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gestures.accessibilityGranted ? L("Accessibility access granted") : L("Accessibility access needed"))
                        Text("Needed to replace double tap / swipe forward / swipe backward, and to press keyboard shortcuts. If SonyMenu is already switched on in System Settings but this still says needed, switch it off and on again (each new build of the app needs this).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !gestures.accessibilityGranted {
                        Button("Open Settings") { gestures.requestAccessibility() }
                    }
                }
            }

            Section("Not possible on the WH-1000XM5") {
                ForEach(UnavailableGesture.all) { u in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.title)
                        Text(u.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { gestures.refresh() }
        .onDisappear { gestures.stopRecording() }
    }

    private func gestureSection(_ title: String, _ list: [Gesture]) -> some View {
        Section(title) {
            ForEach(list) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Picker(selection: Binding(get: { gestures.action(for: g) }, set: { gestures.set($0, for: g) })) {
                        Text("Default (\(g.builtIn))").tag(MacAction.keepDefault)
                        Divider()
                        ForEach(MacAction.options(for: g)) { Text($0.title).tag($0) }
                    } label: {
                        Text(g.title)
                        Text(g.detail)
                    }
                    if gestures.action(for: g) == .shortcut {
                        HStack {
                            Text(gestures.recording == g ? L("Press the shortcut now (Esc cancels)…")
                                 : String(format: L("Shortcut: %@"), gestures.shortcuts[g]?.display ?? L("none")))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(gestures.recording == g ? L("Cancel") : L("Record…")) {
                                gestures.recording == g ? gestures.stopRecording() : gestures.startRecording(g)
                            }
                        }
                        .font(.callout)
                    }
                    if gestures.action(for: g) == .openApp {
                        HStack {
                            Text(String(format: L("App: %@"), gestures.apps[g]?.deletingPathExtension().lastPathComponent ?? L("none")))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…") { gestures.chooseApp(for: g) }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}
