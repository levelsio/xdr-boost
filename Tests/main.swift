import Foundation
import CoreGraphics

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.00001 }

let baseline = GammaTable(red: [0, 0.002, 0.05, 0.2, 0.8, 0.9, 1],
                          green: [0, 0.001, 0.04, 0.18, 0.7, 0.8, 0.9],
                          blue: [0, 0.003, 0.06, 0.22, 0.9, 0.95, 1])
let boosted = baseline.scaled(by: 1.5)
check(zip(boosted.red, boosted.red.dropFirst()).allSatisfy { $0 < $1 },
      "distinct highlights remain distinct above SDR white")
check(close(boosted.red.last!, 1.5), "white enters extended range")
check(boosted.red[0] == 0 && boosted.green[0] == 0 && boosted.blue[0] == 0,
      "zero black remains exactly zero in all channels")
check(close(boosted.red[1] / boosted.red[4], 0.0025) && close(boosted.red[3] / boosted.red[4], 0.25),
      "shadow and midtone proportions are preserved")
check(close(boosted.green[4], 1.05) && close(boosted.blue[4], 1.35),
      "distinct channel calibration is preserved")
check(baseline.scaled(by: 1).red == baseline.red, "unity preserves the captured curve exactly")
check(baseline.red == [0, 0.002, 0.05, 0.2, 0.8, 0.9, 1], "saved baseline is not mutated")
check(close(baseline.scaled(by: 1.1).red[4], 0.88), "level changes do not compound")
check(baseline.isUnboosted && !boosted.isUnboosted, "already boosted calibration is rejected")
check(!GammaTable(red: [.nan, 1], green: [0, 1], blue: [0, 1]).isUnboosted,
      "nonfinite calibration is rejected")

// Model only the OS boundary; exercise the real session's ownership, write
// sizes, failure/retry logic, and calibration effects without changing a display.
final class MemoryGammaAccess: GammaAccess {
    var current: GammaTable
    var failNextWrite = false
    init() {
        let ramp = (0..<1024).map { Float($0) / 1023 * 0.8 }
        current = GammaTable(red: ramp, green: ramp, blue: ramp)
    }
    func capacity(display: CGDirectDisplayID) -> UInt32 { 1024 }
    func read(display: CGDirectDisplayID, capacity: UInt32) -> GammaTable? {
        if capacity == 1024 { return current }
        let ramp = (0..<Int(capacity)).map { Float($0) / Float(capacity - 1) * current.red.last! }
        return GammaTable(red: ramp, green: ramp, blue: ramp)
    }
    func write(_ table: GammaTable, display: CGDirectDisplayID) -> CGError {
        if failNextWrite { failNextWrite = false; return .failure }
        current = table
        return .success
    }
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-owned-display",
   let ownedDisplay = UInt32(CommandLine.arguments[2]) {
    exit(GammaSession(display: ownedDisplay, access: MemoryGammaAccess()) == nil ? 0 : 1)
}
let display = UInt32(0xFFFF0000) | (UInt32(getpid()) & 0xFFFF)
let memory = MemoryGammaAccess()
let original = memory.current
var session = GammaSession(display: display, access: memory)
check(session != nil, "capture an unboosted dimmed calibration")
check(session?.apply(gain: 1.1) == true && memory.current.red.count == 256 && close(memory.current.red.last!, 0.88),
      "boost uses the extended 256-entry write path")
check(GammaSession(display: display, access: memory) == nil,
      "another session cannot capture a dimmed but already owned display")
let competing = Process()
competing.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
competing.arguments = ["--probe-owned-display", String(display)]
competing.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": "/tmp/"]) { _, new in new }
competing.standardOutput = FileHandle.nullDevice
do {
    try competing.run()
    competing.waitUntilExit()
    check(competing.terminationStatus == 0, "another process with a different TMPDIR shares display ownership")
} catch {
    check(false, "launch competing process: \(error)")
}
memory.failNextWrite = true
check(session?.restore() == false && close(memory.current.red.last!, 0.88),
      "failed restoration preserves retry state")
check(GammaSession(display: display, access: memory) == nil,
      "ownership is retained after restoration fails")
check(session?.restore() == true && memory.current.red == original.red && memory.current.red.count == 1024,
      "retry restores the entire native calibration")
session = nil
var next = GammaSession(display: display, access: memory)
check(next != nil, "ownership is released after a restored session ends")
check(next?.apply(gain: .infinity) == false && next?.apply(gain: 3) == false && memory.current.red == original.red,
      "invalid gains never change the display")
next = nil
exit(failures == 0 ? 0 : 1)
