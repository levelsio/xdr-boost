import Cocoa
import SwiftUI

// MARK: - Menu bar item + popover

extension XDRApp {
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))

        let host = NSHostingController(rootView: PanelView(app: self))
        if #available(macOS 13.0, *) {
            host.sizingOptions = .preferredContentSize
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        updateStatusIcon()
    }

    @objc func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func updateStatusIcon() {
        let name = isActive ? "sun.max.fill" : (pauseReason != nil ? "sun.min" : "sun.max")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "XDR Boost")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var app: XDRApp

    static let presets: [Double] = [1.5, 2, 3, 4]
    // Follows the system accent color (System Settings → Appearance)
    static let glow = LinearGradient(colors: [Color.accentColor.opacity(0.7), .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            boost.padding(16).opacity(app.shouldBeActive ? 1 : 0.6)
            Divider()
            options.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 300)
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(app.isActive ? Self.glow : LinearGradient(colors: [Color.primary.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                Image(systemName: app.isActive ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(app.isActive ? .white : .secondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("XDR Boost").font(.system(size: 14, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("XDR Boost", isOn: Binding(get: { app.shouldBeActive }, set: { app.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    var statusLine: String {
        if let reason = app.pauseReason { return reason }
        if app.isActive { return String(format: "On · %.1f× brighter", app.appliedBoost) }
        return "Off"
    }

    // MARK: Boost

    var boost: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", app.boostLevel))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("×")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("BOOST").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    Text(levelName).font(.system(size: 12, weight: .medium))
                }
            }

            Slider(value: Binding(get: { min(app.boostLevel, XDRApp.maxLevel) },
                                  set: { app.setLevel(($0 * 10).rounded() / 10) }),
                   in: 1...XDRApp.maxLevel)

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { presetButton($0) }
            }

            headroomMeter
        }
    }

    var levelName: String {
        switch app.boostLevel {
        case ..<1.75: return "Subtle"
        case ..<2.5: return "Normal"
        case ..<3.5: return "Bright"
        default: return "Max"
        }
    }

    func presetButton(_ level: Double) -> some View {
        let selected = abs(app.boostLevel - level) < 0.05
        let label = level == level.rounded() ? "\(Int(level))×" : String(format: "%.1f×", level)
        return Button { app.setLevel(level) } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Lighter bar = headroom the panel has right now, solid bar = boost on screen.
    var headroomMeter: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if app.isActive {
                        Capsule().fill(Color.accentColor.opacity(0.25))
                            .frame(width: geo.size.width * fraction(app.headroom))
                        Capsule().fill(Self.glow)
                            .frame(width: geo.size.width * fraction(app.appliedBoost))
                    }
                }
            }
            .frame(height: 5)

            Text(meterCaption)
                .font(.system(size: 11))
                .foregroundColor(isCapped ? .accentColor : .secondary)
        }
    }

    func fraction(_ level: Double) -> CGFloat {
        CGFloat(min(max((level - 1) / (XDRApp.maxLevel - 1), 0), 1))
    }

    var isCapped: Bool { app.isActive && app.appliedBoost < app.boostLevel - 0.05 }

    var meterCaption: String {
        guard app.isActive else {
            return app.pauseReason != nil ? "Resumes when connected to power" : "Normal SDR brightness"
        }
        if isCapped { return String(format: "Limited to %.1f× at this brightness", app.appliedBoost) }
        return String(format: "%.1f× of headroom available", app.headroom)
    }

    // MARK: Options

    var options: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("OPTIONS").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            optionRow("Turn on when the app starts", icon: "power", isOn: $app.turnOnAtLaunch)
            optionRow("Launch at login", icon: "person.crop.circle",
                      isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            if app.batteryPercent != nil {
                optionRow("Only while charging", icon: "bolt.fill", isOn: $app.onlyWhileCharging)
                optionRow("Turn off below \(XDRApp.lowBatteryPercent)% battery", icon: "battery.25",
                          isOn: $app.lowBatteryOff)
            }
        }
    }

    func optionRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    // MARK: Footer

    var footer: some View {
        HStack {
            Text("⌃⌥⌘V to toggle").font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Button("Quit") { app.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}
