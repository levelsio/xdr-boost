import Cocoa
import MetalKit

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

    var toggleItem: NSMenuItem!
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
        observeSleepWake()
        fputs("XDR Boost ready — click the menu bar icon to toggle\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
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

        // Sleep — tear down overlay before display goes off
        ws.addObserver(self, selector: #selector(handleSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)

        // Screens off (lid close)
        ws.addObserver(self, selector: #selector(handleSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)

        // Wake — restore overlay
        ws.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.didWakeNotification, object: nil)

        // Screens on (lid open)
        ws.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Display config changed (resolution, arrangement, external monitors)
        nc.addObserver(self, selector: #selector(handleDisplayChange),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func handleSleep() {
        wasActiveBeforeSleep = isActive
        if isActive {
            deactivate()
            fputs("Sleep — XDR paused\n", stderr)
        }
    }

    @objc func handleWake() {
        // Small delay to let the display fully initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            // Refresh max EDR in case display changed
            self.maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            if self.wasActiveBeforeSleep && self.maxEDR > 1.0 {
                self.activate()
                fputs("Wake — XDR restored\n", stderr)
            }
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        if isActive {
            // Recreate overlay to match new screen geometry
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
