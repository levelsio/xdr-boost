import Cocoa
import MetalKit
import Carbon.HIToolbox

// MARK: - Kill switch: `xdr-boost --kill` terminates any running instance
if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-u", String(getuid()), "-x", "xdr-boost"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.standardError
    do { try proc.run() } catch {
        fputs("Could not find running instances: \(error)\n", stderr); exit(1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    var count = 0
    for value in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }) {
        guard let pid = Int32(value), pid != getpid() else { continue }
        if kill(pid, SIGTERM) == 0 { count += 1 }
    }
    fputs("Sent stop request to \(count) xdr-boost instance(s) owned by this user\n", stderr)
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
    var boostLevel: Double = 2.0
    var maxEDR: CGFloat = 1.0
    let usesGamma = CommandLine.arguments.contains("--gamma") ||
        (Bundle.main.bundleURL.pathExtension == "app" && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
    var gammaSession: GammaSession?
    var activeScreenFrame: NSRect = .zero
    var activeDisplayID: CGDirectDisplayID?
    var signalSources: [DispatchSourceSignal] = []
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?

    var screenshotMonitor: Any?
    var suppressedForScreenshot = false
    var screenshotRestoreTimer: Timer?

    var toggleItem: NSMenuItem!
    var shortcutItem: NSMenuItem!
    var boostItems: [NSMenuItem] = []

    func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var targetScreen: NSScreen? {
        if let id = activeDisplayID {
            return NSScreen.screens.first { displayID($0) == id }
        }
        return NSScreen.main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr); exit(1)
        }
        device = dev
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        guard maxEDR > 1.0 else {
            fputs("Display doesn't support XDR\n", stderr); exit(1)
        }

        if usesGamma { boostLevel = 1.1 }
        if let raw = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }), let v = Double(raw) {
            guard v.isFinite else { fputs("Brightness must be finite\n", stderr); exit(1) }
            if usesGamma && !(1.0...1.6).contains(v) {
                fputs("Gamma gain must be between 1.0 and 1.6\n", stderr); exit(1)
            }
            boostLevel = usesGamma ? v : min(max(v, 1.0), Double(maxEDR))
        }

        setupStatusBar()
        registerGlobalHotkey()
        observeSleepWake()
        observeScreenshots()
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signalSources.append(source)
        }
        fputs("XDR Boost ready — click menu bar icon or press Ctrl+Option+Cmd+V to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Ctrl+Option+Cmd+V\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
        if usesGamma { fputs("Gamma mode — gains are table factors, not measured nits multipliers\n", stderr) }
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

        let levelHeader = NSMenuItem(title: usesGamma ? "Gamma Gain" : "Brightness Level", action: nil, keyEquivalent: "")
        levelHeader.isEnabled = false
        menu.addItem(levelHeader)

        let levels: [(String, Double)] = usesGamma ? [
            ("1.10 — Low", 1.1),
            ("1.25 — Medium", 1.25),
            ("1.50 — High", 1.5),
            ("1.60 — Maximum", 1.6),
        ] : [
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

    // MARK: - Watchdog & Display Changes

    func observeSleepWake() {
        // Display config changed (resolution, arrangement, external monitors)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Watchdog: every 3 seconds, check if XDR should be on but overlay is dead
        // This handles sleep/wake, lid close/open, lock/unlock — all of them
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isActive, let session = self.gammaSession {
                guard session.restore() else { return }
                self.gammaSession = nil
                self.toggleItem.title = "Turn On"
            }
            guard self.shouldBeActive, !self.suppressedForScreenshot else { return }

            if let window = self.overlayWindow {
                // Window exists — just make sure it's visible and in front
                if !window.isVisible {
                    window.orderFrontRegardless()
                    fputs("Watchdog — window restored\n", stderr)
                }
            } else {
                // Window is gone (nil) — need to fully recreate
                self.isActive = false
                self.maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                if self.maxEDR > 1.0 {
                    self.activate()
                    fputs("Watchdog — XDR recreated\n", stderr)
                }
            }
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = targetScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        if isActive {
            guard let screen = targetScreen else { deactivate(); return }

            // Only tear down / recreate when the screen frame actually changed
            // (resolution or arrangement change). Brightness changes just update EDR
            // headroom and should NOT destroy the overlay.
            if activeScreenFrame != screen.frame || maxEDR <= 1 {
                deactivate()
                if maxEDR > 1.0 && shouldBeActive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self, self.shouldBeActive, !self.isActive else { return }
                        self.activate()
                        fputs("Display changed — XDR refreshed\n", stderr)
                    }
                }
            } else {
                if !usesGamma { boostLevel = min(boostLevel, Double(maxEDR)) }
            }
        }
    }

    // MARK: - Screenshot suppression
    //
    // The overlay uses a `multiply` compositing filter, which can't be excluded
    // from screen capture without turning the shot black (see activate()). So to
    // keep screenshots looking normal we briefly hide the overlay while a capture
    // is in progress, then restore it.
    //
    // Detection: a non-consuming global key monitor watches for the system
    // screenshot shortcuts (⌘⇧3/4/5/6). Requires Input Monitoring permission.

    func observeScreenshots() {
        // keyCodes: 3 = 20, 4 = 21, 5 = 23, 6 = 22
        let shotKeys: Set<UInt16> = [20, 21, 23, 22]
        screenshotMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && shotKeys.contains(event.keyCode) {
                self.suppressForScreenshot()
            }
        }
        if screenshotMonitor == nil {
            fputs("Could not install screenshot monitor (grant Input Monitoring permission)\n", stderr)
        }
    }

    func suppressForScreenshot() {
        guard isActive, let window = overlayWindow, !suppressedForScreenshot else { return }
        suppressedForScreenshot = true
        window.orderOut(nil)
        fputs("Screenshot detected — overlay hidden\n", stderr)
        scheduleScreenshotRestore()
    }

    // Matches the interactive screenshot UI process. The bundle id has moved
    // around between macOS versions (e.g. Tahoe), so fall back to the bundle/
    // executable path — otherwise a renamed id breaks detection and the overlay
    // gets restored mid-capture (which is what corrupts ⌘⇧4-Space window shots).
    func isCaptureUI(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier,
           id == "com.apple.screencaptureui" || id == "com.apple.screenshot" {
            return true
        }
        let path = (app.bundleURL ?? app.executableURL)?.path.lowercased() ?? ""
        return path.contains("screencaptureui") || path.contains("screenshot")
    }

    func captureUIIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { isCaptureUI($0) }
    }

    func scheduleScreenshotRestore() {
        screenshotRestoreTimer?.invalidate()
        var ticks = 0
        var sawCaptureUI = false
        // Keep the overlay hidden for the WHOLE capture session. Interactive
        // captures (⌘⇧4 region, ⌘⇧4-Space window pick, ⌘⇧5 panel) spawn the
        // capture UI — wait until we've seen it appear AND go away, so a slow
        // window pick can't trigger an early restore. Instant captures (⌘⇧3/6)
        // never spawn a UI, so a ticks>=3 (~1.2s) grace covers them. The grace
        // also absorbs the brief lag before the UI first shows up. Hard cap
        // (~30s) guarantees the overlay always returns.
        screenshotRestoreTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            ticks += 1
            if self.captureUIIsRunning() {
                sawCaptureUI = true
                return  // stay hidden while the capture UI is up
            }
            let interactiveDone = sawCaptureUI
            let instantDone = !sawCaptureUI && ticks >= 3
            if interactiveDone || instantDone || ticks > 75 {
                timer.invalidate()
                self.screenshotRestoreTimer = nil
                self.restoreAfterScreenshot()
            }
        }
    }

    func restoreAfterScreenshot() {
        guard suppressedForScreenshot else { return }
        suppressedForScreenshot = false
        guard shouldBeActive else { return }
        if overlayWindow != nil {
            overlayWindow?.orderFrontRegardless()
        } else {
            activate()
        }
        fputs("Screenshot done — overlay restored\n", stderr)
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        if !isActive, let pending = gammaSession {
            shouldBeActive = false
            if pending.restore() {
                gammaSession = nil
                toggleItem.title = "Turn On"
            }
            return
        }
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
        for item in boostItems {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
        if isActive, let view = boostView {
            if usesGamma {
                if gammaSession?.apply(gain: Float(boostLevel)) != true {
                    fputs("Could not set display gamma table\n", stderr)
                    shouldBeActive = false
                    deactivate()
                }
                return
            }
            // Update in-place — no teardown, no flash
            view.clearColor = MTLClearColor(red: boostLevel, green: boostLevel, blue: boostLevel, alpha: 1.0)
            view.draw()  // force immediate frame so there's no black gap
        } else {
            shouldBeActive = true
            activate()
        }
    }

    // MARK: - XDR Overlay

    func activate() {
        guard !isActive, let screen = targetScreen else { return }
        let id = displayID(screen)
        if usesGamma {
            if let pending = gammaSession {
                guard pending.restore() else {
                    fputs("Waiting to restore the previous display gamma before reactivating\n", stderr)
                    return
                }
                gammaSession = nil
            }
            guard let session = GammaSession(display: id) else {
                fputs("Could not capture unboosted gamma; turn off other gamma/brightness apps first\n", stderr)
                shouldBeActive = false
                return
            }
            gammaSession = session
        }
        activeDisplayID = id
        activeScreenFrame = screen.frame

        // The small EDR trigger keeps desktop pixels visible in gamma mode.
        let frame = usesGamma ? NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 8, height: 8) : screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        if usesGamma { window.sharingType = .none }
        // Multiply mode must not use sharingType = .none. Its compositing filter
        // is still applied during screen capture, and multiplying by an excluded (black)
        // window makes the entire screenshot/screen go black.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Single MTKView that both triggers EDR and provides the boost
        let boostView = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        boostView.colorPixelFormat = .rgba16Float
        boostView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        boostView.layer?.isOpaque = false
        boostView.preferredFramesPerSecond = 10
        let value = usesGamma ? Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue) : boostLevel
        boostView.clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1.0)
        if let layer = boostView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        boostRenderer = Renderer(device: device)
        boostView.delegate = boostRenderer

        // Multiply compositing on the content view layer — composites with
        // the desktop content BEHIND the window, not within it
        boostView.wantsLayer = true
        window.contentView = boostView
        if !usesGamma { window.contentView?.layer?.compositingFilter = "multiply" }
        window.orderFrontRegardless()
        overlayWindow = window
        self.boostView = boostView

        if usesGamma && gammaSession?.apply(gain: Float(boostLevel)) != true {
            fputs("Could not set display gamma table\n", stderr)
            shouldBeActive = false
            deactivate()
            return
        }

        isActive = true
        statusItem.button?.title = "☀︎"
        toggleItem.title = "Turn Off"
        fputs("XDR ON — \(boostLevel)x\n", stderr)
    }

    func deactivate() {
        if gammaSession?.restore() != false { gammaSession = nil }
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        boostView = nil
        boostRenderer = nil
        activeDisplayID = nil

        isActive = false
        statusItem.button?.title = "☀"
        toggleItem.title = gammaSession == nil ? "Turn On" : "Retry Display Restoration"
        fputs("XDR OFF\n", stderr)
    }

    @objc func quit() {
        shouldBeActive = false
        deactivate()
        guard gammaSession == nil else {
            fputs("Display restoration failed; keeping the app running to retry. Choose Quit again after the display returns.\n", stderr)
            return
        }
        watchdogTimer?.invalidate()
        screenshotRestoreTimer?.invalidate()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldBeActive = false
        deactivate()
        return gammaSession == nil ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        gammaSession?.restore()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let del = XDRApp()
app.delegate = del
// Dispatch signal sources above restore gamma on the main queue. CoreGraphics
// must not be called from a POSIX signal handler.
app.run()
