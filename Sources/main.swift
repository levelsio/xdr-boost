import Cocoa
import MetalKit
import Carbon.HIToolbox

// MARK: - Kill switch: `xdr-boost --kill` terminates any running instance
if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-f", "xdr-boost"]
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try? proc.run()
    proc.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8) {
        for line in output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != myPID {
                kill(pid, SIGTERM)
            }
        }
    }
    fputs("All xdr-boost instances killed\n", stderr)
    exit(0)
}

class Renderer: NSObject, MTKViewDelegate {
    var commandQueue: MTLCommandQueue
    init(device: MTLDevice) { self.commandQueue = device.makeCommandQueue()! }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let desc = view.currentRenderPassDescriptor,
              let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.endEncoding()
        if let drawable = view.currentDrawable {
            buf.present(drawable)
        }
        buf.commit()
    }
}

class XDRApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayWindow: NSWindow?
    var boostView: MTKView?
    var device: MTLDevice!
    var boostRenderer: Renderer?
    var isActive = false
    var shouldBeActive = false  // tracks user intent across sleep/lock cycles
    var boostLevel: Double = 2.0      // user's chosen level — never mutated by clamping
    var effectiveBoost: Double = 2.0  // actual level after clamping to maxEDR
    var maxEDR: CGFloat = 1.0
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?

    var toggleItem: NSMenuItem!
    var shortcutItem: NSMenuItem!
    var boostItems: [NSMenuItem] = []
    var edrInfoItem: NSMenuItem!

    // Debouncing to prevent overlapping reassert calls
    var pendingReassert: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr); exit(1)
        }
        device = dev
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        guard maxEDR > 1.0 else {
            fputs("Display doesn't support XDR\n", stderr); exit(1)
        }

        if CommandLine.arguments.count > 1, let v = Double(CommandLine.arguments[1]) {
            boostLevel = min(max(v, 1.0), Double(maxEDR))
        }
        effectiveBoost = min(boostLevel, Double(maxEDR))

        setupStatusBar()
        registerGlobalHotkey()
        observeSystemEvents()
        fputs("XDR Boost ready — click menu bar icon or press Ctrl+Option+Cmd+V to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Ctrl+Option+Cmd+V\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
    }

    // MARK: - Global Hotkey (Ctrl+Option+Cmd+V)

    func registerGlobalHotkey() {
        let hotkeyID = EventHotKeyID(signature: OSType(0x58445242), id: 1) // "XDRB"
        var ref: EventHotKeyRef?

        // Ctrl+Option+Cmd+V  (kVK_ANSI_V = 0x09)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey | cmdKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotkeyRef = ref
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
                let app = Unmanaged<XDRApp>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async { app.toggleXDR() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        } else {
            fputs("Could not register global hotkey (Ctrl+Option+Cmd+V)\n", stderr)
        }
    }

    // MARK: - Status Bar

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarIcon()

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Turn On XDR Boost", action: #selector(toggleXDR), keyEquivalent: "b")
        toggleItem.target = self
        menu.addItem(toggleItem)

        shortcutItem = NSMenuItem(title: "⌃⌥⌘V", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        edrInfoItem = NSMenuItem(title: edrInfoText(), action: nil, keyEquivalent: "")
        edrInfoItem.isEnabled = false
        menu.addItem(edrInfoItem)

        let levelHeader = NSMenuItem(title: "Brightness Level", action: nil, keyEquivalent: "")
        levelHeader.isEnabled = false
        menu.addItem(levelHeader)

        let levels: [(String, Double)] = [
            ("1.5x — Subtle", 1.5),
            ("2.0x — Normal", 2.0),
            ("3.0x — Bright", 3.0),
            ("4.0x — Max", 4.0),
        ]

        for (title, level) in levels {
            let item = NSMenuItem(title: title, action: #selector(setBoostLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(level * 100)
            item.state = (level == boostLevel) ? .on : .off
            menu.addItem(item)
            boostItems.append(item)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func edrInfoText() -> String {
        return "EDR Headroom: \(String(format: "%.1f", maxEDR))x"
    }

    func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        if isActive {
            let levelStr = String(format: "%.1f", effectiveBoost)
            button.title = "☀︎ \(levelStr)x"
        } else {
            button.title = "☀"
        }
    }

    // MARK: - System Event Observers

    func observeSystemEvents() {
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter

        // Display config changed (resolution, arrangement, external monitors)
        nc.addObserver(self, selector: #selector(handleDisplayChange),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Space / Mission Control — fires when exiting Mission Control or switching spaces
        wnc.addObserver(self, selector: #selector(handleSpaceChange),
                        name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Screen wake — EDR headroom resets after wake
        wnc.addObserver(self, selector: #selector(handleScreenWake),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Watchdog: every 3 seconds, check overlay health and track EDR headroom.
        // Kept at 3s to avoid contributing to flicker — event observers handle the
        // time-sensitive stuff, the watchdog is purely a safety net.
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.watchdogCheck()
        }
    }

    func watchdogCheck() {
        updateEDRHeadroom()

        guard shouldBeActive else { return }

        // EDR unavailable (e.g. brightness at minimum)
        if maxEDR <= 1.0 {
            if isActive {
                deactivate()
                fputs("Watchdog — EDR unavailable, deactivated\n", stderr)
            }
            return
        }

        // shouldBeActive but not isActive — EDR came back after being unavailable
        if !isActive {
            activate()
            fputs("Watchdog — EDR restored, reactivated\n", stderr)
            return
        }

        // Window exists but got hidden (e.g. after sleep/wake edge case)
        if let window = overlayWindow, !window.isVisible {
            window.orderFrontRegardless()
            fputs("Watchdog — window restored\n", stderr)
        } else if overlayWindow == nil {
            // Window was destroyed — recreate
            isActive = false
            activate()
            fputs("Watchdog — XDR recreated\n", stderr)
        }
    }

    /// Update maxEDR from current screen and adjust effective boost if needed.
    /// Does NOT deactivate/reactivate — just updates the clear color in-place.
    func updateEDRHeadroom() {
        let currentMaxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        // Use epsilon to avoid flapping on float jitter
        guard abs(currentMaxEDR - maxEDR) > 0.05 else { return }

        let oldMax = maxEDR
        maxEDR = currentMaxEDR
        edrInfoItem?.title = edrInfoText()
        fputs("EDR headroom: \(String(format: "%.1f", oldMax))x → \(String(format: "%.1f", maxEDR))x\n", stderr)

        // Recompute effective boost — user's chosen level stays unchanged
        let newEffective = min(boostLevel, max(Double(maxEDR), 1.0))
        if abs(newEffective - effectiveBoost) > 0.05 {
            effectiveBoost = newEffective
            if isActive, let view = boostView {
                view.clearColor = MTLClearColor(red: effectiveBoost, green: effectiveBoost, blue: effectiveBoost, alpha: 1.0)
                updateStatusBarIcon()
                fputs("Effective boost: \(String(format: "%.1f", effectiveBoost))x\n", stderr)
            }
        }
    }

    @objc func handleSpaceChange() {
        guard shouldBeActive, isActive else { return }
        // Debounced reassert after Mission Control / space switch animation
        scheduleReassert(delay: 0.5)
    }

    @objc func handleScreenWake() {
        guard shouldBeActive else { return }
        scheduleReassert(delay: 1.5)
    }

    @objc func handleDisplayChange() {
        let oldMaxEDR = maxEDR
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        edrInfoItem?.title = edrInfoText()

        guard isActive, shouldBeActive else { return }

        // If just the EDR headroom changed (brightness key), update in-place — no flash
        if let window = overlayWindow, let screen = NSScreen.main {
            let frameChanged = window.frame != screen.frame
            let edrChanged = abs(maxEDR - oldMaxEDR) > 0.05

            if frameChanged {
                // Resolution or display arrangement changed — resize overlay
                window.setFrame(screen.frame, display: false)
                if let view = boostView {
                    view.frame = NSRect(origin: .zero, size: screen.frame.size)
                }
                fputs("Display changed — overlay resized\n", stderr)
            }

            if edrChanged {
                effectiveBoost = min(boostLevel, max(Double(maxEDR), 1.0))
                if let view = boostView {
                    view.clearColor = MTLClearColor(red: effectiveBoost, green: effectiveBoost, blue: effectiveBoost, alpha: 1.0)
                }
                updateStatusBarIcon()
            }

            // If EDR is gone, deactivate cleanly
            if maxEDR <= 1.0 {
                deactivate()
                fputs("Display changed — EDR lost\n", stderr)
            }
        }
    }

    /// Debounced reassert — cancels any pending reassert to prevent overlapping calls.
    func scheduleReassert(delay: Double) {
        pendingReassert?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.shouldBeActive else { return }
            self.updateEDRHeadroom()

            if let window = self.overlayWindow {
                window.orderFrontRegardless()
            } else if self.maxEDR > 1.0 {
                self.isActive = false
                self.activate()
                fputs("Reasserted overlay\n", stderr)
            }
        }
        pendingReassert = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        if isActive {
            shouldBeActive = false
            deactivate()
        } else {
            shouldBeActive = true
            activate()
        }
    }

    @objc func setBoostLevel(_ sender: NSMenuItem) {
        boostLevel = Double(sender.tag) / 100.0
        effectiveBoost = min(boostLevel, max(Double(maxEDR), 1.0))
        for item in boostItems {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
        if isActive, let view = boostView {
            view.clearColor = MTLClearColor(red: effectiveBoost, green: effectiveBoost, blue: effectiveBoost, alpha: 1.0)
        }
        updateStatusBarIcon()
    }

    // MARK: - XDR Overlay

    func activate() {
        guard let screen = NSScreen.main, maxEDR > 1.0 else { return }

        effectiveBoost = min(boostLevel, Double(maxEDR))

        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.sharingType = .none
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let boostView = MTKView(frame: frame, device: device)
        boostView.colorPixelFormat = .rgba16Float
        boostView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        boostView.layer?.isOpaque = false
        boostView.preferredFramesPerSecond = 10
        boostView.clearColor = MTLClearColor(red: effectiveBoost, green: effectiveBoost, blue: effectiveBoost, alpha: 1.0)
        if let layer = boostView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        boostRenderer = Renderer(device: device)
        boostView.delegate = boostRenderer

        boostView.wantsLayer = true
        window.contentView = boostView
        window.contentView?.layer?.compositingFilter = "multiply"
        window.orderFrontRegardless()
        overlayWindow = window
        self.boostView = boostView

        isActive = true
        toggleItem.title = "Turn Off XDR Boost"
        updateStatusBarIcon()
        fputs("XDR ON — \(String(format: "%.1f", effectiveBoost))x (headroom: \(String(format: "%.1f", maxEDR))x)\n", stderr)
    }

    func deactivate() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        boostView = nil
        boostRenderer = nil

        isActive = false
        toggleItem.title = "Turn On XDR Boost"
        updateStatusBarIcon()
        fputs("XDR OFF\n", stderr)
    }

    @objc func quit() {
        deactivate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let del = XDRApp()
app.delegate = del
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
app.run()
