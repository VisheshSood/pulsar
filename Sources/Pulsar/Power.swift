import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Clamshell control via IOPMrootDomain. Keeps the Mac awake with the lid closed so the logo can stay lit.
enum Clamshell {
    private static let kPMSetClamshellSleepState: UInt32 = 12

    /// true when the lid is closed (AppleClamshellState).
    static var lidClosed: Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        return (IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return false }
        defer { IOServiceClose(conn) }
        var input: UInt64 = disabled ? 1 : 0
        let r = IOConnectCallScalarMethod(conn, kPMSetClamshellSleepState, &input, 1, nil, nil)
        if r != KERN_SUCCESS { NSLog("Pulsar: clamshell call failed \(r)") }
        return r == KERN_SUCCESS
    }

    static func sleepNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { return }
        IOPMSleepSystem(port)
        IOServiceClose(port)
    }

    /// Child process that re-enables clamshell sleep if Pulsar exits or crashes while it's disabled.
    static func spawnWatchdog() -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--lid-watchdog", String(getpid())]
        do { try p.run(); return p } catch { NSLog("Pulsar: watchdog failed \(error)"); return nil }
    }

    /// Entry point for the watchdog process: block until the parent dies, then restore sleep.
    static func runWatchdogIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--lid-watchdog"), i + 1 < args.count, let parent = pid_t(args[i + 1]) else { return }
        signal(SIGTERM, SIG_IGN)   // parent sends SIGUSR1 to dismiss us cleanly
        signal(SIGUSR1) { _ in exit(0) }
        let kq = kqueue()
        var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
        var out = kevent()
        if kevent(kq, &ev, 1, nil, 0, nil) == 0 { _ = kevent(kq, nil, 0, &out, 1, nil) }
        setSleepDisabled(false)
        exit(0)
    }
}

enum PowerInfo {
    struct State { var onAC: Bool; var percent: Double?; var charging: Bool }
    static var current: State {
        var s = State(onAC: true, percent: nil, charging: false)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return s }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            s.onAC = type == kIOPMACPowerKey
        }
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                s.percent = Double(cur) / Double(max)
                s.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
                break
            }
        }
        return s
    }
}

/// Lifts macOS's ambient-light limits on the logo by pinning CoreBrightness's lux→nits
/// restriction curves flat (min 12.5 nits, max 1000 nits = the panel's user-accessible max).
/// Root's com.apple.CoreBrightness domain, so macOS asks for the admin password.
enum BrightnessLimit {
    private static let domain = "com.apple.CoreBrightness"
    private static let minKey = "LEPWMLuxToMinNitsRestrictionMapping"
    private static let maxKey = "LEPWMLuxToMaxNitsRestrictionMapping"
    static let minNits = "12.5", maxNits = "1000"

    static var lifted: Bool {
        get { UserDefaults.standard.bool(forKey: "limitLifted") }
        set { UserDefaults.standard.set(newValue, forKey: "limitLifted") }
    }

    private static func flat(_ nits: String) -> String {
        "'<array><real>0</real><real>\(nits)</real></array>' '<array><real>3.4e38</real><real>\(nits)</real></array>'"
    }

    static var liftCommand: String {
        "/usr/bin/defaults write \(domain) \(minKey) -array \(flat(minNits)) && " +
        "/usr/bin/defaults write \(domain) \(maxKey) -array \(flat(maxNits)) && /usr/bin/killall corebrightnessd"
    }

    static var restoreCommand: String {
        "/usr/bin/defaults delete \(domain) \(minKey) 2>/dev/null; " +
        "/usr/bin/defaults delete \(domain) \(maxKey) 2>/dev/null; /usr/bin/killall corebrightnessd; true"
    }

    /// Runs on a background thread; returns false if the user cancelled the password prompt.
    static func set(lifted on: Bool, completion: @escaping (Bool) -> Void) {
        let cmd = (on ? liftCommand : restoreCommand).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = on ? "Pulsar wants to remove the ambient-light brightness limit on your Apple logo."
                        : "Pulsar wants to restore the default brightness limit on your Apple logo."
        let source = "do shell script \"\(cmd)\" with prompt \"\(prompt)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            let ok = NSAppleScript(source: source)?.executeAndReturnError(&err) != nil
            if ok { lifted = on } else { NSLog("Pulsar: limit change failed \(err ?? [:])") }
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
