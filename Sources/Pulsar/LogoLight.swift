import Foundation
import IOKit
import CoreGraphics

/// Drives the glowing Apple logo on M5 Pro/Max MacBook Pros (PROLED display).
///
/// How the hardware works (verified against the bklb-backlight PWM duty cycle):
/// corebrightnessd derives logo nits from *display* nits through the curve
/// `LEPWMBrightnessNitsMapping` ([[displayNits, logoNits], …]). It only re-evaluates the
/// curve when display brightness changes. So to set the logo we:
///   1. replace the curve with a flat line at the target logo nits, then
///   2. nudge display brightness by a hair and back, which makes corebrightnessd apply it.
/// The original curve is saved and restored on quit (and on next launch after a crash).
final class LogoLight {
    private typealias SetProp = @convention(c) (AnyObject, Selector, AnyObject?, NSString) -> Bool
    private typealias GetBright = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBright = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let mapKey = "LEPWMBrightnessNitsMapping" as NSString
    private static let savedKey = "originalLogoMapping"
    static let maxNits = 1000.0
    static let floorNits = 4.0
    /// Seconds between hardware updates; corebrightnessd fades smoothly between them.
    var updateInterval = 0.15

    private var client: NSObject?
    private var setProp: SetProp?
    private let setSel = NSSelectorFromString("setProperty:forKey:")
    private var getBright: GetBright?
    private var setBright: SetBright?
    private var original: NSArray?
    private var lastNits = -1.0
    private var lastWrite = 0.0
    private(set) var current = 0.0

    static var hardwarePresent: Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pwm1/bklb-backlight")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        return entry != 0
    }

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else { return }
        let c = cls.init()
        guard c.responds(to: setSel) else { return }
        client = c
        setProp = unsafeBitCast(c.method(for: setSel), to: SetProp.self)
        if let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
           let g = dlsym(ds, "DisplayServicesGetBrightness"), let s = dlsym(ds, "DisplayServicesSetBrightness") {
            getBright = unsafeBitCast(g, to: GetBright.self)
            setBright = unsafeBitCast(s, to: SetBright.self)
        }
        original = loadOriginal()
        originalMode = copy("LEBacklightMode")
        claim()
    }

    // MARK: manual mode
    // LEBacklightMode = 2 puts the logo under manual (client) control; without it
    // corebrightnessd ignores curve changes. A corebrightnessd restart (e.g. after
    // lifting the brightness limit) resets it, so we re-claim it periodically.
    private var originalMode: AnyObject?
    private var lastClaim = 0.0

    private func copy(_ key: String) -> AnyObject? {
        client?.perform(NSSelectorFromString("copyPropertyForKey:"), with: key as NSString)?.takeRetainedValue()
    }

    private func claim() {
        guard let c = client, let s = setProp else { return }
        lastClaim = ProcessInfo.processInfo.systemUptime
        if (copy("LEBacklightMode") as? NSNumber)?.intValue != 2 {
            _ = s(c, setSel, NSNumber(value: 2), "LEBacklightMode")
            lastNits = -1                     // daemon state was reset: force the next write
        }
    }

    var available: Bool { client != nil && setBright != nil && Self.hardwarePresent }

    /// macOS's stock display-nits → logo-nits curve (read from an M5 Pro MacBook Pro, macOS 27.2).
    static let factoryCurve: NSArray = [
        [0, 0], [0.1, 12.5], [16.84, 12.5], [34.12, 28.62], [50, 45.37],
        [69.11, 65.52], [140, 150], [300, 300], [600, 1000], [Double(Float.greatestFiniteMagnitude), 1000],
    ]

    /// Sets logo brightness 0...1 (perceptual; mapped to nits with a gamma of 2).
    func set(_ value: Double, commit: Bool = false, force: Bool = false) {
        let v = min(max(value, 0), 1)
        // Perceptual curve from floorNits to maxNits; exactly 0 is off.
        let nits = v <= 0.001 ? 0 : ((Self.floorNits + v * v * (Self.maxNits - Self.floorNits)) * 10).rounded() / 10
        let t = ProcessInfo.processInfo.systemUptime
        if t - lastClaim > 3 { claim() }
        if !force && !commit {
            if abs(nits - lastNits) < max(0.4, nits * 0.015) { return }
            // Big jumps are flash edges: send immediately, don't wait for the next slot.
            if t - lastWrite < updateInterval && abs(nits - lastNits) < 150 { return }
        }
        lastNits = nits; lastWrite = t; current = v
        writeCurve([[0, nits], [Double(Float.greatestFiniteMagnitude), nits]])
    }

    /// Puts the original curve back so macOS resumes normal logo behaviour.
    func restore() {
        guard let o = original, let c = client, let s = setProp else { return }
        _ = s(c, setSel, o, Self.mapKey)
        _ = s(c, setSel, originalMode ?? NSNumber(value: 0), "LEBacklightMode")
        nudgeDisplay()                 // apply the original curve…
        usleep(60_000)
        nudgeDisplay(settle: true)     // …and leave the display exactly at the user's level
        lastNits = -1
    }

    // MARK: private

    private func writeCurve(_ curve: NSArray) {
        guard let c = client, let s = setProp else { return }
        _ = s(c, setSel, curve, Self.mapKey)
        nudgeDisplay()
    }

    // One display change per update. Two (up and back) start two overlapping fades in
    // corebrightnessd that fight each other, which is what made the logo jitter.
    // So we alternate the display between the user's level and level+ε (invisible).
    private var baseline: Float = -1
    private var nudged = false
    private var expected: Float = -1
    private let eps: Float = 0.002

    private func nudgeDisplay(settle: Bool = false) {
        guard let g = getBright, let s = setBright else { return }
        let d = CGMainDisplayID()
        var cur: Float = 0
        guard g(d, &cur) == 0 else { return }
        if baseline < 0 || abs(cur - expected) > 0.0005 {
            // First run, or the user / auto-brightness changed the display: adopt it.
            baseline = cur; nudged = false
        }
        let up: Float = baseline < 1 - eps ? eps : -eps
        nudged = settle ? false : !nudged
        let target = nudged ? baseline + up : baseline
        if target == cur && !settle {           // already there: force a change the other way
            nudged.toggle()
        }
        let final = nudged ? baseline + up : baseline
        let r = s(d, final)
        if let path = ProcessInfo.processInfo.environment["PULSAR_TRACE"], let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(String(format: "%.3f nits=%.1f cur=%.4f set=%.4f r=%d\n", ProcessInfo.processInfo.systemUptime, lastNits, cur, final, r).data(using: .utf8)!); try? fh.close()
        }
        expected = final
    }

    private func currentCurve() -> NSArray? {
        client?.perform(NSSelectorFromString("copyPropertyForKey:"), with: Self.mapKey)?.takeRetainedValue() as? NSArray
    }

    /// A flat two-point curve is one of ours; anything else is macOS's real curve.
    private static func isOurs(_ a: NSArray) -> Bool {
        guard a.count == 2, let p0 = a[0] as? NSArray, let p1 = a[1] as? NSArray, p0.count == 2, p1.count == 2 else { return false }
        return (p0[1] as? NSNumber)?.doubleValue == (p1[1] as? NSNumber)?.doubleValue
    }

    private func loadOriginal() -> NSArray? {
        let saved = (UserDefaults.standard.array(forKey: Self.savedKey) as NSArray?) ?? Self.factoryCurve
        guard let cur = currentCurve() else { return saved }
        if Self.isOurs(cur) {
            // Left over from a crash or kill: put macOS's curve back right away.
            writeCurve(saved)
            return saved
        }
        UserDefaults.standard.set(cur, forKey: Self.savedKey)
        return cur
    }
}
