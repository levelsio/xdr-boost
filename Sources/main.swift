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

enum AutomationAppearanceMode: String {
    case off
    case light
    case dark

    var menuTitle: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light Mode"
        case .dark: return "Dark Mode"
        }
    }
}

struct AutomationSettings {
    static let defaultsPrefix = "automation."
    static let appearanceModeKey = defaultsPrefix + "appearanceMode"
    static let timeEnabledKey = defaultsPrefix + "timeEnabled"
    static let timeStartMinutesKey = defaultsPrefix + "timeStartMinutes"
    static let timeEndMinutesKey = defaultsPrefix + "timeEndMinutes"

    var appearanceMode: AutomationAppearanceMode = .off
    var timeEnabled = false
    var timeStartMinutes = 8 * 60
    var timeEndMinutes = 18 * 60

    var hasActiveRules: Bool {
        appearanceMode != .off || timeEnabled
    }

    static func load() -> AutomationSettings {
        let defaults = UserDefaults.standard
        var settings = AutomationSettings()

        if let raw = defaults.string(forKey: appearanceModeKey),
           let appearanceMode = AutomationAppearanceMode(rawValue: raw) {
            settings.appearanceMode = appearanceMode
        }

        if defaults.object(forKey: timeEnabledKey) != nil {
            settings.timeEnabled = defaults.bool(forKey: timeEnabledKey)
        }

        if defaults.object(forKey: timeStartMinutesKey) != nil {
            settings.timeStartMinutes = defaults.integer(forKey: timeStartMinutesKey)
        }

        if defaults.object(forKey: timeEndMinutesKey) != nil {
            settings.timeEndMinutes = defaults.integer(forKey: timeEndMinutesKey)
        }

        settings.timeStartMinutes = settings.normalized(minutes: settings.timeStartMinutes)
        settings.timeEndMinutes = settings.normalized(minutes: settings.timeEndMinutes)
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
        defaults.set(timeEnabled, forKey: Self.timeEnabledKey)
        defaults.set(normalized(minutes: timeStartMinutes), forKey: Self.timeStartMinutesKey)
        defaults.set(normalized(minutes: timeEndMinutes), forKey: Self.timeEndMinutesKey)
    }

    func normalized(minutes: Int) -> Int {
        let day = 24 * 60
        let mod = minutes % day
        return mod >= 0 ? mod : mod + day
    }
}

class Renderer: NSObject, MTKViewDelegate {
    var commandQueue: MTLCommandQueue

    init(device: MTLDevice) {
        self.commandQueue = device.makeCommandQueue()!
    }

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

class XDRApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var overlayWindow: NSWindow?
    var boostView: MTKView?
    var device: MTLDevice!
    var boostRenderer: Renderer?
    var isActive = false
    var manualRequestedActive = false
    var boostLevel: Double = 2.0
    var maxEDR: CGFloat = 1.0
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?
    var automationSettings = AutomationSettings.load()

    var toggleItem: NSMenuItem!
    var shortcutItem: NSMenuItem!
    var automationStatusItem: NSMenuItem!
    var automationSettingsItem: NSMenuItem!
    var boostItems: [NSMenuItem] = []

    var settingsWindow: NSWindow?
    var appearancePopup: NSPopUpButton?
    var timeEnabledButton: NSButton?
    var startTimePicker: NSDatePicker?
    var endTimePicker: NSDatePicker?
    var validationLabel: NSTextField?
    var saveButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr)
            exit(1)
        }
        device = dev
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        guard maxEDR > 1.0 else {
            fputs("Display doesn't support XDR\n", stderr)
            exit(1)
        }

        if CommandLine.arguments.count > 1, let v = Double(CommandLine.arguments[1]) {
            boostLevel = min(max(v, 1.0), Double(maxEDR))
        }

        setupStatusBar()
        registerGlobalHotkey()
        observeSleepWake()
        evaluateAutomation(reason: "launch")
        fputs("XDR Boost ready — click menu bar icon or press Cmd+Shift+B to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Cmd+Shift+B\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
    }

    // MARK: - Global Hotkey (Cmd+Shift+B)

    func registerGlobalHotkey() {
        let hotkeyID = EventHotKeyID(signature: OSType(0x58445242), id: 1) // "XDRB"
        var ref: EventHotKeyRef?

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
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
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
        statusItem.button?.title = "☀"

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
            item.state = level == boostLevel ? .on : .off
            menu.addItem(item)
            boostItems.append(item)
        }

        menu.addItem(NSMenuItem.separator())

        automationStatusItem = NSMenuItem(title: "Automation: Manual", action: nil, keyEquivalent: "")
        automationStatusItem.isEnabled = false
        menu.addItem(automationStatusItem)

        automationSettingsItem = NSMenuItem(title: "Automation Settings...", action: #selector(openAutomationSettings), keyEquivalent: ",")
        automationSettingsItem.target = self
        menu.addItem(automationSettingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuState()
    }

    func refreshMenuState() {
        statusItem.button?.title = isActive ? "☀︎" : "☀"
        toggleItem.title = isActive ? "Turn Off" : "Turn On"
        automationStatusItem.title = automationStatusText()
    }

    func automationStatusText() -> String {
        guard automationSettings.hasActiveRules else {
            return "Automation: Manual"
        }

        let desiredActive = evaluateRulesOnly()
        return desiredActive ? "Automation: Active" : "Automation: Waiting"
    }

    // MARK: - Watchdog & Display Changes

    func observeSleepWake() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDisplayChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.evaluateAutomation(reason: "watchdog")
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        evaluateAutomation(reason: "display-change")
    }

    // MARK: - Automation

    func desiredActiveState() -> Bool {
        if automationSettings.hasActiveRules {
            return evaluateRulesOnly()
        }
        return manualRequestedActive
    }

    func evaluateRulesOnly() -> Bool {
        var passes = true

        switch automationSettings.appearanceMode {
        case .off:
            break
        case .light:
            passes = passes && currentAppearanceMode() == .light
        case .dark:
            passes = passes && currentAppearanceMode() == .dark
        }

        if automationSettings.timeEnabled {
            let now = currentMinutesSinceMidnight()
            let start = automationSettings.normalized(minutes: automationSettings.timeStartMinutes)
            let end = automationSettings.normalized(minutes: automationSettings.timeEndMinutes)

            if start == end {
                passes = false
            } else if start < end {
                passes = passes && now >= start && now < end
            } else {
                passes = passes && (now >= start || now < end)
            }
        }

        return passes
    }

    func currentAppearanceMode() -> AutomationAppearanceMode {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    func currentMinutesSinceMidnight(date: Date = Date()) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    func evaluateAutomation(reason: String) {
        let desiredActive = desiredActiveState()

        if desiredActive {
            if let window = overlayWindow {
                if !window.isVisible {
                    window.orderFrontRegardless()
                    fputs("Watchdog — window restored\n", stderr)
                }
            } else {
                isActive = false
                maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                if maxEDR > 1.0 {
                    activate()
                    fputs("XDR ON — \(boostLevel)x [\(reason)]\n", stderr)
                }
            }
        } else if isActive {
            deactivate()
            fputs("XDR OFF [\(reason)]\n", stderr)
        } else {
            refreshMenuState()
        }
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        manualRequestedActive = !isActive

        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    @objc func setBoostLevel(_ sender: NSMenuItem) {
        boostLevel = Double(sender.tag) / 100.0
        for item in boostItems {
            item.state = item.tag == sender.tag ? .on : .off
        }
        if isActive, let view = boostView {
            view.clearColor = MTLClearColor(red: boostLevel, green: boostLevel, blue: boostLevel, alpha: 1.0)
        }
    }

    // MARK: - Automation Settings UI

    @objc func openAutomationSettings() {
        if settingsWindow == nil {
            buildAutomationWindow()
        }

        loadControls(from: automationSettings)
        validateAutomationForm()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildAutomationWindow() {
        let rect = NSRect(x: 0, y: 0, width: 360, height: 260)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Automation Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        let contentView = NSView(frame: rect)
        window.contentView = contentView

        let appearanceLabel = label("System Appearance", frame: NSRect(x: 20, y: 205, width: 160, height: 17))
        contentView.addSubview(appearanceLabel)

        let appearancePopup = NSPopUpButton(frame: NSRect(x: 20, y: 172, width: 200, height: 28), pullsDown: false)
        appearancePopup.addItems(withTitles: [
            AutomationAppearanceMode.off.menuTitle,
            AutomationAppearanceMode.light.menuTitle,
            AutomationAppearanceMode.dark.menuTitle,
        ])
        contentView.addSubview(appearancePopup)
        self.appearancePopup = appearancePopup

        let timeEnabledButton = NSButton(checkboxWithTitle: "Use Time Window", target: self, action: #selector(timeWindowChanged))
        timeEnabledButton.frame = NSRect(x: 20, y: 136, width: 160, height: 20)
        contentView.addSubview(timeEnabledButton)
        self.timeEnabledButton = timeEnabledButton

        let startLabel = label("Start", frame: NSRect(x: 20, y: 105, width: 60, height: 17))
        let endLabel = label("End", frame: NSRect(x: 190, y: 105, width: 60, height: 17))
        contentView.addSubview(startLabel)
        contentView.addSubview(endLabel)

        let startPicker = makeTimePicker(frame: NSRect(x: 20, y: 70, width: 130, height: 32))
        let endPicker = makeTimePicker(frame: NSRect(x: 190, y: 70, width: 130, height: 32))
        startPicker.target = self
        startPicker.action = #selector(timeWindowChanged)
        endPicker.target = self
        endPicker.action = #selector(timeWindowChanged)
        contentView.addSubview(startPicker)
        contentView.addSubview(endPicker)
        self.startTimePicker = startPicker
        self.endTimePicker = endPicker

        let validationLabel = NSTextField(labelWithString: "")
        validationLabel.frame = NSRect(x: 20, y: 45, width: 320, height: 16)
        validationLabel.textColor = .systemRed
        contentView.addSubview(validationLabel)
        self.validationLabel = validationLabel

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAutomationSettings))
        cancelButton.frame = NSRect(x: 180, y: 10, width: 80, height: 30)
        contentView.addSubview(cancelButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAutomationSettings))
        saveButton.frame = NSRect(x: 270, y: 10, width: 70, height: 30)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
        self.saveButton = saveButton

        settingsWindow = window
    }

    func label(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        return label
    }

    func makeTimePicker(frame: NSRect) -> NSDatePicker {
        let picker = NSDatePicker(frame: frame)
        picker.datePickerElements = .hourMinute
        picker.datePickerMode = .single
        picker.datePickerStyle = .textFieldAndStepper
        return picker
    }

    func loadControls(from settings: AutomationSettings) {
        appearancePopup?.selectItem(at: appearancePopupIndex(for: settings.appearanceMode))
        timeEnabledButton?.state = settings.timeEnabled ? .on : .off
        startTimePicker?.dateValue = dateForMinutes(settings.timeStartMinutes)
        endTimePicker?.dateValue = dateForMinutes(settings.timeEndMinutes)
        updateTimePickerEnabledState()
    }

    func appearancePopupIndex(for mode: AutomationAppearanceMode) -> Int {
        switch mode {
        case .off: return 0
        case .light: return 1
        case .dark: return 2
        }
    }

    func selectedAppearanceMode() -> AutomationAppearanceMode {
        switch appearancePopup?.indexOfSelectedItem ?? 0 {
        case 1: return .light
        case 2: return .dark
        default: return .off
        }
    }

    func dateForMinutes(_ minutes: Int) -> Date {
        let normalized = automationSettings.normalized(minutes: minutes)
        var components = DateComponents()
        components.hour = normalized / 60
        components.minute = normalized % 60
        return Calendar.current.date(from: components) ?? Date()
    }

    func minutesFromPicker(_ picker: NSDatePicker?) -> Int {
        guard let picker else { return 0 }
        return currentMinutesSinceMidnight(date: picker.dateValue)
    }

    func updateTimePickerEnabledState() {
        let enabled = timeEnabledButton?.state == .on
        startTimePicker?.isEnabled = enabled
        endTimePicker?.isEnabled = enabled
    }

    @objc func timeWindowChanged() {
        updateTimePickerEnabledState()
        validateAutomationForm()
    }

    func validateAutomationForm() {
        let timeEnabled = timeEnabledButton?.state == .on
        let start = minutesFromPicker(startTimePicker)
        let end = minutesFromPicker(endTimePicker)

        if timeEnabled && start == end {
            validationLabel?.stringValue = "Start and end time must be different."
            saveButton?.isEnabled = false
        } else {
            validationLabel?.stringValue = ""
            saveButton?.isEnabled = true
        }
    }

    @objc func cancelAutomationSettings() {
        settingsWindow?.orderOut(nil)
    }

    @objc func saveAutomationSettings() {
        let timeEnabled = timeEnabledButton?.state == .on
        let start = minutesFromPicker(startTimePicker)
        let end = minutesFromPicker(endTimePicker)

        if timeEnabled && start == end {
            validateAutomationForm()
            return
        }

        automationSettings.appearanceMode = selectedAppearanceMode()
        automationSettings.timeEnabled = timeEnabled
        automationSettings.timeStartMinutes = start
        automationSettings.timeEndMinutes = end
        automationSettings.save()

        settingsWindow?.orderOut(nil)
        evaluateAutomation(reason: "settings-save")
    }

    // MARK: - XDR Overlay

    func activate() {
        guard let screen = NSScreen.main else { return }

        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

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

        boostView.wantsLayer = true
        window.contentView = boostView
        window.contentView?.layer?.compositingFilter = "multiply"
        window.orderFrontRegardless()
        overlayWindow = window
        self.boostView = boostView

        isActive = true
        refreshMenuState()
    }

    func deactivate() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        boostView = nil
        boostRenderer = nil
        isActive = false
        refreshMenuState()
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
