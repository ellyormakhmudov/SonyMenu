import AppKit
import Combine
import SwiftUI

/// Borderless glass window that drops down right under the menu bar, like the system Wi-Fi panel.
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Menu bar icon + dropdown panel. The icon is visible only while the headphones are connected.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hp = Headphones()
    private var statusItem: NSStatusItem?
    private var panel: DropdownPanel?
    private var hosting: NSHostingView<AnyView>?
    private var settingsWindow: NSWindow?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SonyMenu.log")

    /// Gap between the menu bar and the panel, and the panel's corner radius.
    private let gap: CGFloat = 6
    private let radius: CGFloat = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? Data().write(to: logURL)
        hp.log = { [logURL] line in
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(stamp) \(line)\n".data(using: .utf8),
                  let h = try? FileHandle(forWritingTo: logURL) else { return }
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: L("Headphones"))
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.isVisible = false
        statusItem = item

        hp.$isPresent
            .removeDuplicates()
            .sink { [weak self] present in
                guard let self else { return }
                self.statusItem?.isVisible = present
                if !present { self.closePanel() }
                self.hp.log("Menu bar icon \(present ? "shown" : "hidden")")
                // `--show`: open the panel by itself once connected (used for screenshots).
                if present, CommandLine.arguments.contains("--show") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.openPanel() }
                }
            }
            .store(in: &bag)

        // Content height changes (e.g. the ambient section appears): keep the top pinned.
        hp.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutPanel() } }
            .store(in: &bag)

        let gestures = GestureController.shared
        gestures.headphones = hp
        gestures.log = { [weak self] in self?.hp.log($0) }
        gestures.start()

        MicGuard.shared.log = { [weak self] in self?.hp.log($0) }
        MicGuard.shared.start()

        hp.start()

        // `--settings`: open the Settings window right away (used for screenshots).
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.openSettings() }
        }
    }

    // MARK: Settings window

    @objc func openSettings() {
        closePanel()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(hp))
            let w = NSWindow(contentViewController: host)
            w.title = L("SonyMenu Settings")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        GestureController.shared.refresh()
    }

    // MARK: Panel

    private func makePanel() -> DropdownPanel {
        let host = NSHostingView(rootView: AnyView(
            PanelView(openSettings: { [weak self] in self?.openSettings() }).environmentObject(hp)))
        hosting = host

        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        glass.contentView = host

        let p = DropdownPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        // The glass draws its own rounded edge; a window shadow would be rectangular.
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        p.contentView = container
        return p
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        layoutPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        statusItem?.button?.highlight(true)

        // Close on a click anywhere else, or on Esc.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.closePanel() }; return nil }
            return event
        }) { monitors.append(m) }
    }

    private func closePanel() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        statusItem?.button?.highlight(false)
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Places the panel just under the icon, left-aligned with it and kept on screen.
    private func layoutPanel() {
        guard let panel, let host = hosting,
              let button = statusItem?.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let menuBarBottom = buttonWindow.frame.minY
        let visible = screen.visibleFrame

        var x = iconFrame.minX - 10
        x = min(x, visible.maxX - size.width - 8)
        x = max(x, visible.minX + 8)
        let y = menuBarBottom - gap - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { panel.invalidateShadow() }
    }
}

enum SonyMenuApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
