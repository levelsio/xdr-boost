import CoreGraphics
import Foundation
import Darwin

struct GammaTable {
    // Use 256 entries for boosted writes to retain extended values.
    // Save the native table separately for restoration.
    static let boostSampleCount: UInt32 = 256
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]

    static func read(display: CGDirectDisplayID, capacity: UInt32) -> GammaTable? {
        guard capacity > 1 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success,
              count > 1, count <= capacity else { return nil }
        return GammaTable(red: Array(red.prefix(Int(count))),
                          green: Array(green.prefix(Int(count))),
                          blue: Array(blue.prefix(Int(count))))
    }

    var isUnboosted: Bool {
        (red + green + blue).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.01 }
    }

    func scaled(by gain: Float) -> GammaTable {
        // Preserve the captured curve's proportions. Clamping to SDR white
        // would merge highlights; zero black must stay exactly zero.
        GammaTable(red: red.map { $0 * gain }, green: green.map { $0 * gain }, blue: blue.map { $0 * gain })
    }

    func write(display: CGDirectDisplayID) -> CGError {
        guard red.count > 1, red.count == green.count, red.count == blue.count else { return .failure }
        return CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue)
    }
}

private final class DisplayGammaLock {
    private let descriptor: Int32

    init?(display: CGDirectDisplayID) {
        // Use Darwin's canonical user directory, independent of TMPDIR in a
        // Terminal, app launcher, or LaunchAgent environment.
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var directory = [CChar](repeating: 0, count: size)
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR, &directory, directory.count)
        guard written > 0, written <= size else { return nil }
        let path = (String(cString: directory) as NSString).appendingPathComponent("xdr-boost-gamma-\(getuid())-\(display).lock")
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

final class GammaSession {
    let display: CGDirectDisplayID
    private let original: GammaTable
    private let baseline: GammaTable
    private let ownership: DisplayGammaLock
    private var applied = false

    init?(display: CGDirectDisplayID) {
        // Own the display before reading it, including when its calibration is
        // dimmed enough that an existing gain would still have endpoints <= 1.
        guard let ownership = DisplayGammaLock(display: display) else { return nil }
        // Save the full native table for restoration before presenting EDR.
        let capacity = max(CGDisplayGammaTableCapacity(display), GammaTable.boostSampleCount)
        guard let original = GammaTable.read(display: display, capacity: capacity),
              let baseline = GammaTable.read(display: display, capacity: GammaTable.boostSampleCount),
              baseline.red.count == Int(GammaTable.boostSampleCount),
              original.isUnboosted, baseline.isUnboosted else { return nil }
        self.display = display
        self.original = original
        self.baseline = baseline
        self.ownership = ownership
    }

    @discardableResult
    func apply(gain: Float) -> Bool {
        guard gain.isFinite, (1...1.6).contains(gain) else { return false }
        guard baseline.scaled(by: gain).write(display: display) == .success else { return false }
        applied = true
        return true
    }

    @discardableResult
    func restore() -> Bool {
        guard applied else { return true }
        // Retain the snapshot and ownership on failure so callers can retry.
        // Never reset ColorSync on displays this session does not own.
        guard original.write(display: display) == .success else { return false }
        applied = false
        return true
    }
}
