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

// Use a high window level that avoids macOS special-casing of .screenSaver during
// Mission Control, while still sitting above all normal app windows and panels.
// .screenSaver (1000) triggers window hiding/reordering during Mission Control and
// can interfere with cursor compositing. Level 200 is well above .popUpMenu (101)
// but safely below any system-reserved levels.
private let kOverlayWindowLevel = NSWindow.Level(rawValue: 200)

class XDRApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayWindow: NSWindow?
    var boostView: MTKView?
    var device: MTLDevice!
    var boostRenderer: Renderer?
    var isActive = false
    var shouldBeActive = false  // tracks user intent across sleep/lock cycles
    var boostLevel: Double = 2.0
    var maxEDR: CGFloat = 1.0
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?

    var toggleItem: NSMenuItem!
    var shortcutItem: NSMenuItem!
    var boostItems: [NSMenuItem] = []

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
            // Install Carbon event handler for hotkey
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
        if let button = statusItem.button {
            button.title = "☀"
        }

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Turn On", action: #selector(toggleXDR), keyEquivalent: "b")
        toggleItem.target = self
        menu.addItem(toggleItem)

        shortcutItem = NSMenuItem(title: "Shortcut: Ctrl+Option+Cmd+V", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

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

    // MARK: - System Event Observers

    func observeSystemEvents() {
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter

        // Display config changed (resolution, arrangement, external monitors)
        nc.addObserver(self, selector: #selector(handleDisplayChange),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Space / Mission Control changes — fires when exiting Mission Control or switching spaces
        wnc.addObserver(self, selector: #selector(handleSpaceChange),
                        name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Screen sleep/wake — EDR headroom resets after wake
        wnc.addObserver(self, selector: #selector(handleScreenWake),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Watchdog: every 1.5 seconds, verify overlay health and track EDR headroom changes
        // (handles brightness keyboard adjustments, sleep/wake, lid close/open, lock/unlock)
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.watchdogCheck()
        }
    }

    func watchdogCheck() {
        // Track EDR headroom changes from keyboard brightness controls
        let currentMaxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        if currentMaxEDR != maxEDR {
            let oldMax = maxEDR
            maxEDR = currentMaxEDR
            fputs("EDR headroom changed: \(oldMax)x → \(maxEDR)x\n", stderr)

            // Clamp boost level if it now exceeds available headroom
            if boostLevel > Double(maxEDR) && maxEDR > 1.0 {
                boostLevel = Double(maxEDR)
                updateBoostMenuState()
                if isActive, let view = boostView {
                    view.clearColor = MTLClearColor(red: boostLevel, green: boostLevel, blue: boostLevel, alpha: 1.0)
                    fputs("Boost clamped to \(boostLevel)x\n", stderr)
                }
            }
        }

        guard shouldBeActive else { return }

        // EDR no longer available (brightness too low or display changed)
        if maxEDR <= 1.0 {
            if isActive {
                deactivate()
                fputs("Watchdog — EDR unavailable, deactivated\n", stderr)
            }
            return
        }

        if let window = overlayWindow {
            // Window exists — make sure it's visible and correctly sized
            if !window.isVisible {
                window.orderFrontRegardless()
                fputs("Watchdog — window restored\n", stderr)
            }
            if let screen = NSScreen.main, window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
                fputs("Watchdog — resized to match screen\n", stderr)
            }
        } else {
            // Window is gone — need to fully recreate
            isActive = false
            if maxEDR > 1.0 {
                activate()
                fputs("Watchdog — XDR recreated\n", stderr)
            }
        }
    }

    @objc func handleSpaceChange() {
        guard shouldBeActive else { return }
        // Short delay to let Mission Control / space switch animation finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reassertOverlay()
        }
    }

    @objc func handleScreenWake() {
        guard shouldBeActive else { return }
        // Delay to let the display fully wake and report correct EDR values
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            self.reassertOverlay()
        }
    }

    /// Re-assert the overlay window after system events (Mission Control, space change, wake).
    /// Recreates it if it was destroyed, otherwise ensures it's visible and correctly sized.
    func reassertOverlay() {
        guard shouldBeActive else { return }
        if let window = overlayWindow {
            if let screen = NSScreen.main {
                window.setFrame(screen.frame, display: false)
            }
            window.orderFrontRegardless()
        } else {
            isActive = false
            maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            if maxEDR > 1.0 {
                activate()
                fputs("Overlay reasserted\n", stderr)
            }
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        if isActive {
            deactivate()
            if maxEDR > 1.0 && shouldBeActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.activate()
                    fputs("Display changed — XDR refreshed\n", stderr)
                }
            }
        }
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
        updateBoostMenuState()
        if isActive, let view = boostView {
            // Update in-place — no teardown, no flash
            view.clearColor = MTLClearColor(red: boostLevel, green: boostLevel, blue: boostLevel, alpha: 1.0)
        }
    }

    func updateBoostMenuState() {
        let currentTag = Int(boostLevel * 100)
        for item in boostItems {
            item.state = (item.tag == currentTag) ? .on : .off
        }
    }

    // MARK: - XDR Overlay

    func activate() {
        guard let screen = NSScreen.main else { return }

        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = kOverlayWindowLevel
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.sharingType = .none  // exclude from screenshots and screen recordings
        window.animationBehavior = .none  // prevent animation glitches during Mission Control
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Single MTKView that both triggers EDR and provides the boost
        let boostView = MTKView(frame: frame, device: device)
        boostView.colorPixelFormat = .rgba16Float
        boostView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        boostView.layer?.isOpaque = false
        boostView.preferredFramesPerSecond = 10
        boostView.clearColor = MTLClearColor(red: boostLevel, green: boostLevel, blue: boostLevel, alpha: 1.0)
        if let layer = boostView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        boostRenderer = Renderer(device: device)
        boostView.delegate = boostRenderer

        // Multiply compositing on the content view layer — composites with
        // the desktop content BEHIND the window, not within it
        boostView.wantsLayer = true
        window.contentView = boostView
        window.contentView?.layer?.compositingFilter = "multiply"
        window.orderFrontRegardless()
        overlayWindow = window
        self.boostView = boostView

        isActive = true
        statusItem.button?.title = "☀︎"
        toggleItem.title = "Turn Off"
        fputs("XDR ON — \(boostLevel)x\n", stderr)
    }

    func deactivate() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        boostView = nil
        boostRenderer = nil

        isActive = false
        statusItem.button?.title = "☀"
        toggleItem.title = "Turn On"
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
