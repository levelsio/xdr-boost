import Cocoa
import MetalKit
import Carbon.HIToolbox
import IOKit.ps

// Other running xdr-boost processes. Matches the process name exactly (not `pkill -f`,
// which also hits this very process and anything with "xdr-boost" in its arguments,
// like an editor open on the repo).
func otherInstances() -> [pid_t] {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", "xdr-boost"]
    proc.standardOutput = pipe
    try? proc.run()
    proc.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.split(separator: "\n").compactMap { pid_t($0) }.filter { $0 != getpid() }
}

// MARK: - Kill switch: `xdr-boost --kill` terminates any running instance
if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    for pid in otherInstances() {
        kill(pid, SIGTERM)
    }
    fputs("All xdr-boost instances killed\n", stderr)
    exit(0)
}

// Two instances would fight over the gamma table (and the hotkey), so only run one.
if !otherInstances().isEmpty {
    fputs("xdr-boost is already running (use the menu bar icon, or `xdr-boost --kill`)\n", stderr)
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

typealias GammaTable = (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])

class XDRApp: NSObject, NSApplicationDelegate, ObservableObject {
    static let prefs = UserDefaults(suiteName: "com.xdr-boost")!
    static let maxLevel = 4.0
    static let lowBatteryPercent = 20
    static let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.xdr-boost.agent.plist")

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var triggerWindow: NSWindow?
    var triggerView: MTKView?
    var device: MTLDevice!
    var triggerRenderer: Renderer?
    @Published var isActive = false { didSet { updateStatusIcon() } }
    @Published var shouldBeActive = false  // tracks user intent across sleep/lock cycles
    @Published var boostLevel: Double { didSet { Self.prefs.set(boostLevel, forKey: "level") } }
    @Published var appliedBoost: Double = 1.0  // linear boost currently on screen
    @Published var headroom: Double = 1.0      // panel's current EDR headroom
    @Published var pauseReason: String? { didSet { updateStatusIcon() } }  // power options holding it off
    var maxEDR: CGFloat = 1.0
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?

    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var originalGamma: GammaTable?  // display's own (calibrated) table, captured before boosting

    // Settings (persisted)
    @Published var turnOnAtLaunch: Bool { didSet { Self.prefs.set(turnOnAtLaunch, forKey: "turnOnAtLaunch") } }
    @Published var onlyWhileCharging: Bool {
        didSet { Self.prefs.set(onlyWhileCharging, forKey: "onlyWhileCharging"); enforcePowerPolicy() }
    }
    @Published var lowBatteryOff: Bool {
        didSet { Self.prefs.set(lowBatteryOff, forKey: "lowBatteryOff"); enforcePowerPolicy() }
    }
    @Published var launchAtLogin = FileManager.default.fileExists(atPath: XDRApp.agentURL.path)

    // Power state
    @Published var onBattery = false
    @Published var batteryPercent: Int?  // nil on Macs without a battery

    override init() {
        let p = Self.prefs
        boostLevel = p.object(forKey: "level") as? Double ?? 2.0
        turnOnAtLaunch = p.bool(forKey: "turnOnAtLaunch")
        onlyWhileCharging = p.bool(forKey: "onlyWhileCharging")
        lowBatteryOff = p.bool(forKey: "lowBatteryOff")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr); exit(1)
        }
        device = dev
        guard let screen = xdrScreen() else {
            fputs("Display doesn't support XDR\n", stderr); exit(1)
        }
        maxEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue

        if CommandLine.arguments.count > 1, let v = Double(CommandLine.arguments[1]) {
            boostLevel = min(max(v, 1.0), Double(maxEDR))
        }

        updatePower()
        setupStatusBar()
        registerGlobalHotkey()
        observeSleepWake()
        if turnOnAtLaunch || CommandLine.arguments.contains("--on") {
            setEnabled(true)
        }
        fputs("XDR Boost ready — click menu bar icon or press Ctrl+Option+Cmd+V to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Ctrl+Option+Cmd+V\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
    }

    // The XDR-capable screen (built-in panel). Unlike NSScreen.main, this doesn't
    // follow keyboard focus between monitors.
    func xdrScreen() -> NSScreen? {
        NSScreen.screens.first { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 }
    }

    func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
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

    // MARK: - Watchdog & Display Changes

    func observeSleepWake() {
        // Display config changed (resolution, arrangement, external monitors)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Space / Mission Control switch — keep the existing trigger, never recreate it
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Watchdog: every second, check if XDR should be on but the trigger window is
        // dead or macOS reset the gamma table (sleep/wake, lid, lock, ColorSync changes)
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updatePower()
            self.updateHeadroom()
            guard self.shouldBeActive, !self.enforcePowerPolicy() else { return }

            if let window = self.triggerWindow {
                if !window.isVisible {
                    window.orderFrontRegardless()
                    fputs("Watchdog — trigger restored\n", stderr)
                }
                self.refreshGamma()
            } else {
                // Trigger is gone (nil) — need to fully recreate
                self.isActive = false
                self.maxEDR = self.xdrScreen()?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                if self.maxEDR > 1.0 {
                    self.activate()
                    fputs("Watchdog — XDR recreated\n", stderr)
                }
            }
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = xdrScreen()?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        updateHeadroom()
        guard isActive else { return }
        guard let screen = xdrScreen(), let window = triggerWindow else {
            // XDR panel went away (e.g. lid closed with external display) — watchdog brings it back
            deactivate()
            return
        }

        // This fires very often (EDR headroom changes post it too), so only rebuild
        // when the panel itself moved or changed identity. Otherwise just re-check gamma.
        if screenID(screen) != displayID || window.frame.origin != screen.frame.origin {
            deactivate()
            if maxEDR > 1.0 && shouldBeActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.activate()
                    fputs("Display changed — XDR refreshed\n", stderr)
                }
            }
        } else {
            refreshGamma()
        }
    }

    @objc func handleSpaceChange() {
        guard isActive, let window = triggerWindow else { return }
        window.orderFrontRegardless()
        refreshGamma()
    }

    // MARK: - Gamma boost
    //
    // The boost is applied as a scaled display transfer (gamma) table. It runs in the
    // display pipeline AFTER WindowServer composites the frame, so Mission Control and
    // Space-switch animations (which bypass window compositing filters) stay boosted,
    // and screenshots/recordings are unaffected. The tiny EDR trigger window keeps the
    // panel in EDR mode so table values above 1.0 map to real extra nits.
    //
    // macOS restores the ColorSync table automatically when the process exits — even on
    // SIGKILL — so the screen can never get stuck boosted.

    // Linear boost actually applied: the chosen level, capped to the panel's current EDR
    // headroom. Going past it would push SDR white beyond what the backlight can show
    // and clip highlights. Headroom shrinks as the brightness keys go up.
    var effectiveBoost: Double {
        let headroom = Double(xdrScreen()?.maximumExtendedDynamicRangeColorComponentValue ?? 0)
        return headroom > 1.0 ? min(boostLevel, headroom) : boostLevel
    }

    // Table values act on the gamma-encoded signal; scale so linear light = effectiveBoost.
    var gammaGain: Float { Float(pow(effectiveBoost, 1.0 / 2.2)) }
    var appliedGain: Float = 0
    var headroomDropSince: Date?

    func readGamma() -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return (Array(r.prefix(n)), Array(g.prefix(n)), Array(b.prefix(n)))
    }

    // WindowServer silently ignores full-capacity (1024) tables but accepts 256 entries,
    // which the hardware interpolates back up — so resample the original to 256.
    static let gammaTableSize = 256

    func scaled(_ channel: [CGGammaValue], by k: Float) -> [CGGammaValue] {
        let n = Self.gammaTableSize, last = channel.count - 1
        return (0..<n).map { i in
            let pos = Float(i) / Float(n - 1) * Float(last)
            let lo = Int(pos), hi = min(lo + 1, last), f = pos - Float(lo)
            return (channel[lo] * (1 - f) + channel[hi] * f) * k
        }
    }

    func applyGamma() {
        if originalGamma == nil { originalGamma = readGamma() }
        guard let t = originalGamma else { return }
        let k = gammaGain
        var r = scaled(t.r, by: k), g = scaled(t.g, by: k), b = scaled(t.b, by: k)
        if CGSetDisplayTransferByTable(displayID, UInt32(r.count), &r, &g, &b) == .success {
            appliedGain = k
            appliedBoost = pow(Double(k), 2.2)
        }
    }

    func gammaIsBoosted() -> Bool {
        guard let t = originalGamma, let cur = readGamma() else { return false }
        return abs((cur.r.last ?? 0) - (t.r.last ?? 0) * appliedGain) < 0.01
    }

    // Keep the table correct: re-apply if macOS reset it, or if the headroom moved
    // enough to change the gain. Rises apply right away; drops only once they've lasted
    // a couple of seconds, so a brief dip (e.g. mid Space switch) can't pulse the boost.
    func refreshGamma() {
        if !gammaIsBoosted() {
            reapplyGamma()
            fputs("Gamma restored\n", stderr)
        } else if gammaGain > appliedGain + 0.005 {
            headroomDropSince = nil
            applyGamma()
        } else if gammaGain < appliedGain - 0.005 {
            let since = headroomDropSince ?? Date()
            headroomDropSince = since
            if Date().timeIntervalSince(since) >= 2 {
                headroomDropSince = nil
                applyGamma()
                fputs("Headroom dropped — boost now \(String(format: "%.2f", effectiveBoost))x\n", stderr)
            }
        } else {
            headroomDropSince = nil
        }
    }

    // macOS replaced our table (wake, ColorSync/calibration change) — adopt its new
    // table as the baseline and boost on top of it. Only adopt tables that look
    // unboosted, so a boosted table can never become the baseline and compound.
    func reapplyGamma() {
        if let cur = readGamma(), (cur.r + cur.g + cur.b).allSatisfy({ $0 <= 1.001 }) {
            originalGamma = cur
        }
        applyGamma()
    }

    func restoreGamma() {
        if originalGamma != nil { CGDisplayRestoreColorSyncSettings() }
        originalGamma = nil
        appliedGain = 0
        appliedBoost = 1.0
    }

    func updateHeadroom() {
        let h = Double(xdrScreen()?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
        if abs(h - headroom) > 0.01 { headroom = h }
    }

    // MARK: - Power options

    func updatePower() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = cur * 100 / max
        }
        let battery = source == kIOPSBatteryPowerValue
        if battery != onBattery { onBattery = battery }
        if percent != batteryPercent { batteryPercent = percent }
    }

    var powerBlock: String? {
        guard onBattery else { return nil }
        if onlyWhileCharging { return "Paused on battery" }
        if lowBatteryOff, let p = batteryPercent, p <= Self.lowBatteryPercent { return "Paused — battery at \(p)%" }
        return nil
    }

    // Holds the boost off while a power option says so, and lets the watchdog bring it
    // back once it doesn't. Returns true while blocked.
    @discardableResult
    func enforcePowerPolicy() -> Bool {
        guard shouldBeActive, let reason = powerBlock else {
            if pauseReason != nil { pauseReason = nil }
            return false
        }
        if pauseReason != reason { pauseReason = reason }
        if isActive {
            deactivate()
            fputs("\(reason)\n", stderr)
        }
        return true
    }

    // MARK: - Launch at login
    //
    // Writes the same launch agent `make launch-agent` installs. It isn't loaded right
    // away (that would start a second copy), it just takes effect at the next login.

    func setLaunchAtLogin(_ on: Bool) {
        let url = Self.agentURL
        if on, let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            let plist: [String: Any] = [
                "Label": "com.xdr-boost",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: url)
            }
        } else if !on {
            try? FileManager.default.removeItem(at: url)
        }
        launchAtLogin = FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        setEnabled(!shouldBeActive)
    }

    func setEnabled(_ on: Bool) {
        shouldBeActive = on
        if !on {
            pauseReason = nil
            deactivate()
        } else if !enforcePowerPolicy() {
            activate()
        }
    }

    // Picking a level also turns the boost on, like the presets in the old menu did.
    func setLevel(_ level: Double) {
        boostLevel = min(max(level, 1.0), Double(maxEDR))
        if isActive {
            // Update in-place — no teardown, no flash
            applyGamma()
        } else if !shouldBeActive {
            setEnabled(true)
        }
    }

    // MARK: - XDR trigger + boost

    func activate() {
        guard !isActive, let screen = xdrScreen() else { return }
        displayID = screenID(screen)

        // 1×1 pt EDR window in the bottom-left corner (hidden under the panel's rounded
        // corner). Its only job is to hold the display in EDR mode.
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 10
        view.clearColor = MTLClearColor(red: 2.0, green: 2.0, blue: 2.0, alpha: 1.0)
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        triggerRenderer = Renderer(device: device)
        view.delegate = triggerRenderer
        window.contentView = view
        window.orderFrontRegardless()
        triggerWindow = window
        triggerView = view

        applyGamma()

        isActive = true
        fputs("XDR ON — \(boostLevel)x (applied \(String(format: "%.2f", effectiveBoost))x)\n", stderr)
    }

    func deactivate() {
        restoreGamma()
        triggerWindow?.orderOut(nil)
        triggerWindow = nil
        triggerView = nil
        triggerRenderer = nil

        isActive = false
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
