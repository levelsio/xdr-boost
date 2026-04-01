import Cocoa
import MetalKit
import Carbon.HIToolbox

// MARK: - Kill switch: `xdr-boost --kill` terminates any running instance
if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    proc.arguments = ["-f", "xdr-boost"]
    proc.standardOutput = pipe
    proc.standardError = pipe
    try? proc.run()
    proc.waitUntilExit()
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
    var device: MTLDevice!
    var triggerRenderer: Renderer?
    var boostRenderer: Renderer?
    var isActive = false
    var boostLevel: Double = 2.0
    var maxEDR: CGFloat = 1.0
    var wasActiveBeforeSleep = false
    var hotkeyRef: EventHotKeyRef?

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
        observeSleepWake()
        fputs("XDR Boost ready — click menu bar icon or press Cmd+Shift+B to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Cmd+Shift+B\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
    }

    // MARK: - Global Hotkey (Cmd+Shift+B)

    func registerGlobalHotkey() {
        let hotkeyID = EventHotKeyID(signature: OSType(0x58445242), id: 1) // "XDRB"
        var ref: EventHotKeyRef?

        // Cmd+Shift+B  (kVK_ANSI_B = 0x0B)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(cmdKey | shiftKey),
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
            fputs("Could not register global hotkey (Cmd+Shift+B)\n", stderr)
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

        shortcutItem = NSMenuItem(title: "Shortcut: Cmd+Shift+B", action: nil, keyEquivalent: "")
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

    // MARK: - Sleep/Wake & Display Changes

    func observeSleepWake() {
        let ws = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        let dnc = DistributedNotificationCenter.default()

        ws.addObserver(self, selector: #selector(handleSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleDisplayChange),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Screen lock/unlock — the lock screen kills our overlay
        dnc.addObserver(self, selector: #selector(handleScreenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(handleScreenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc func handleSleep() {
        wasActiveBeforeSleep = isActive
        if isActive {
            deactivate()
            fputs("Sleep — XDR paused\n", stderr)
        }
    }

    @objc func handleScreenLocked() {
        wasActiveBeforeSleep = isActive
        if isActive {
            deactivate()
            fputs("Screen locked — XDR paused\n", stderr)
        }
    }

    @objc func handleScreenUnlocked() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            if self.wasActiveBeforeSleep && self.maxEDR > 1.0 {
                self.activate()
                fputs("Screen unlocked — XDR restored\n", stderr)
            }
        }
    }

    @objc func handleWake() {
        // Wake without lock screen — restore immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            if self.wasActiveBeforeSleep && self.maxEDR > 1.0 && !self.isActive {
                self.activate()
                fputs("Wake — XDR restored\n", stderr)
            }
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        if isActive {
            deactivate()
            if maxEDR > 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.activate()
                    fputs("Display changed — XDR refreshed\n", stderr)
                }
            }
        }
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        if isActive { deactivate() } else { activate() }
    }

    @objc func setBoostLevel(_ sender: NSMenuItem) {
        boostLevel = Double(sender.tag) / 100.0
        for item in boostItems {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
        if isActive {
            deactivate()
            activate()
        }
    }

    // MARK: - XDR Overlay

    func activate() {
        guard let screen = NSScreen.main else { return }

        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let containerView = NSView(frame: frame)
        containerView.wantsLayer = true
        containerView.layer?.isOpaque = false

        // 1x1 EDR trigger
        let triggerView = MTKView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: device)
        triggerView.colorPixelFormat = .rgba16Float
        triggerView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        triggerView.layer?.isOpaque = false
        triggerView.preferredFramesPerSecond = 5
        triggerView.clearColor = MTLClearColor(red: Double(maxEDR), green: Double(maxEDR), blue: Double(maxEDR), alpha: 1.0)
        if let layer = triggerView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        triggerRenderer = Renderer(device: device)
        triggerView.delegate = triggerRenderer

        // Full-screen multiply blend boost
        let boostView = MTKView(frame: frame, device: device)
        boostView.colorPixelFormat = .rgba16Float
        boostView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        boostView.layer?.isOpaque = false
        boostView.preferredFramesPerSecond = 10
        boostView.clearColor = MTLClearColor(red: boostLevel, green: boostLevel, blue: boostLevel, alpha: 1.0)
        if let layer = boostView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.compositingFilter = "multiply"
        }
        boostRenderer = Renderer(device: device)
        boostView.delegate = boostRenderer

        containerView.addSubview(triggerView)
        containerView.addSubview(boostView)
        window.contentView = containerView
        window.orderFrontRegardless()
        overlayWindow = window

        isActive = true
        statusItem.button?.title = "☀︎"
        toggleItem.title = "Turn Off"
        fputs("XDR ON — \(boostLevel)x\n", stderr)
    }

    func deactivate() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        triggerRenderer = nil
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
