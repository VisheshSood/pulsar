import Foundation
import SwiftUI
import IOKit.ps
import IOKit.pwr_mgt

enum Effect: String, CaseIterable, Identifiable {
    case steady, breathe, pulse, heartbeat, music, battery, morse, agents
    var id: String { rawValue }
    var title: String {
        switch self {
        case .steady: "Glow"; case .breathe: "Breathe"; case .pulse: "Pulse"; case .heartbeat: "Heart"
        case .battery: "Charge"; case .music: "Beat"; case .morse: "Morse"; case .agents: "Agents"
        }
    }
    var symbol: String {
        switch self {
        case .steady: "sun.max.fill"; case .breathe: "wind"; case .pulse: "dot.radiowaves.left.and.right"
        case .heartbeat: "heart.fill"; case .battery: "bolt.fill"; case .music: "waveform"
        case .morse: "ellipsis.message.fill"; case .agents: "sparkles"
        }
    }
    var blurb: String {
        switch self {
        case .steady: "A constant glow at your brightness."
        case .breathe: "Slowly swells and fades."
        case .pulse: "A brisk, even throb."
        case .heartbeat: "Lub-dub, then a rest."
        case .morse: "Flashes your message in Morse code."
        case .battery: "Logo brightness matches your battery level. Ripples while charging."
        case .music: "Flashes on every kick drum your Mac plays."
        case .agents: "Mirrors your AI coding agents: calm when idle, pulsing while working, blinking when they need you."
        }
    }
}

enum AgentState: String { case off, idle, working, alert, done }

/// Tiny observable pieces so views only re-render for what they show.
/// (Observing the whole engine made the menu-bar icon redraw on every brightness tick.)
final class LiveLevel: ObservableObject { @Published var value = 0.0 }
final class MenuState: ObservableObject { @Published var enabled = true }

@MainActor
final class LightEngine: ObservableObject {
    // Settings (persisted)
    @AppStorage("effect") var effectRaw = Effect.steady.rawValue { didSet { effectChanged() } }
    @AppStorage("enabled") var enabled = true { didSet { objectWillChange.send(); menu.enabled = enabled; if !enabled { logo.set(0, commit: true) }; syncLid() } }
    @AppStorage("batterySaver") var batterySaver = true { didSet { applyRate() } }
    let live = LiveLevel()
    let menu = MenuState()
    /// Set by the panel; the live glow preview only updates while it's open.
    var panelVisible = false
    private var onBattery = false
    @AppStorage("brightness") var brightness = 1.0
    @AppStorage("breatheSpeed") var breatheSpeed = 0.5
    @AppStorage("beatIntensity") var beatIntensity = 0.8
    @AppStorage("beatStrobe") var beatStrobe = false
    @AppStorage("beatSensitivity") var beatSensitivity = 0.5 { didSet { audio.engine?.sensitivity = sensitivityK } }
    @AppStorage("agentAlertsAnywhere") var agentAlertsAnywhere = true
    @AppStorage("pulseSpeed") var pulseSpeed = 0.5
    @AppStorage("heartRate") var heartRate = 0.35          // 0 → 45 BPM, 1 → 140 BPM
    @AppStorage("morseText") var morseText = "Hello world"
    @AppStorage("morseWPM") var morseWPM = 8.0
    @AppStorage("morseLoop") var morseLoop = true
    @Published private(set) var morsePlaying = false
    @Published private(set) var morseProgress = 0.0
    private var morseStart = 0.0
    private var morseTimeline: [(on: Bool, end: Double)] = []
    private var morseLength = 0.0
    @AppStorage("litWithLidClosed") var litWithLidClosed = false { didSet { syncLid() } }
    @AppStorage("lidOnBattery") var lidOnBattery = false { didSet { syncLid() } }
    @Published private(set) var lidStatus: String?
    @Published private(set) var limitLifted = BrightnessLimit.lifted
    @Published private(set) var limitBusy = false
    private var sleepDisabled = false
    private var watchdog: Process?
    private var assertion: IOPMAssertionID = 0
    private var lidClosedSince: Double?
    private var lidTrippedUntilOpen = false

    // Live state
    private var level = 0.0
    @Published private(set) var listening = false
    @Published private(set) var batteryPercent: Double?
    @Published private(set) var charging = false
    @Published private(set) var agentState: AgentState = .off
    @Published private(set) var bpm: Int?

    let logo = LogoLight()
    let hasLogo = LogoLight.hardwarePresent
    private let audio = AudioTap()
    private var timer: Timer?
    private var t0 = ProcessInfo.processInfo.systemUptime
    private var agentChanged = 0.0
    private var tick = 0

    var effect: Effect {
        get { Effect(rawValue: effectRaw) ?? .steady }
        set { effectRaw = newValue.rawValue }
    }
    private var sensitivityK: Double { 3.2 - 2.0 * beatSensitivity }   // 0 → 3.2 (strict), 1 → 1.2 (eager)

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        effectChanged()
    }

    func shutdown() {
        audio.stop()
        releaseLid()
        logo.restore()
    }

    // MARK: brightness limit

    func setLimitLifted(_ on: Bool) {
        limitBusy = true
        BrightnessLimit.set(lifted: on) { [weak self] _ in
            guard let self else { return }
            self.limitBusy = false
            self.limitLifted = BrightnessLimit.lifted
            // corebrightnessd restarts; push our level again once it's back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.forceWrite = true }
        }
    }

    // MARK: lid closed

    private var forceWrite = false
    static let lidMaxMinutes = 30.0

    private func syncLid() {
        let power = PowerInfo.current
        if onBattery == power.onAC { onBattery = !power.onAC; applyRate() }
        let closed = Clamshell.lidClosed
        if !closed { lidClosedSince = nil; lidTrippedUntilOpen = false }
        else if lidClosedSince == nil { lidClosedSince = now }

        let want = enabled && litWithLidClosed && (power.onAC || lidOnBattery) && !lidTrippedUntilOpen
        if want && !sleepDisabled { holdLid() } else if !want && sleepDisabled { releaseLid() }

        guard sleepDisabled, closed, let since = lidClosedSince else {
            lidStatus = litWithLidClosed && !power.onAC && !lidOnBattery ? "Paused on battery" : nil
            return
        }
        let minutes = (now - since) / 60
        var stop: String?
        if minutes >= Self.lidMaxMinutes { stop = "30-minute limit reached" }
        if !power.onAC, let p = power.percent, p < 0.2 { stop = "Battery below 20%" }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { stop = "Mac is getting hot" }
        if let reason = stop {
            NSLog("Pulsar: lid hold ended: \(reason)")
            lidTrippedUntilOpen = true
            releaseLid()
            lidStatus = reason
            Clamshell.sleepNow()
        } else {
            lidStatus = "Lid closed · \(Int(Self.lidMaxMinutes - minutes)) min left"
        }
    }

    private func holdLid() {
        guard Clamshell.setSleepDisabled(true) else { lidStatus = "macOS refused to keep the Mac awake"; return }
        sleepDisabled = true
        watchdog = Clamshell.spawnWatchdog()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Pulsar keeps the logo lit with the lid closed" as CFString, &assertion)
    }

    private func releaseLid() {
        guard sleepDisabled else { return }
        Clamshell.setSleepDisabled(false)
        sleepDisabled = false
        if let w = watchdog, w.isRunning { kill(w.processIdentifier, SIGUSR1) }
        watchdog = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    func toggle() { enabled.toggle() }

    func setAgent(_ s: AgentState) {
        agentState = s
        agentChanged = now
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Fast effects need quicker hardware updates; slow ones save power.
    /// Battery saver halves the rate on battery; corebrightnessd's fade keeps it smooth.
    private func applyRate() {
        let fast: Bool
        switch effect { case .music, .morse, .heartbeat, .agents: fast = true; default: fast = false }
        var interval = fast ? 0.09 : 0.18
        if batterySaver && onBattery { interval *= fast ? 1.4 : 2.0 }
        logo.updateInterval = interval
    }

    private func effectChanged() {
        objectWillChange.send()
        applyRate()
        if effect == .music {
            listening = audio.start()
            audio.engine?.sensitivity = sensitivityK
        } else if audio.running {
            audio.stop(); listening = false; bpm = nil
        }
    }

    private func step() {
        tick += 1
        let t = now - t0
        var v: Double
        switch effect {
        case .steady: v = 1
        case .breathe: v = breathe(t, hz: 0.06 + 0.34 * breatheSpeed)
        case .battery: v = batteryLevel(t)
        case .music: v = musicLevel()
        case .agents: v = agentLevel(t)
        case .pulse: v = pulse(t, hz: 0.5 + 1.5 * pulseSpeed)
        case .heartbeat: v = heartbeat(t, bpm: 45 + 95 * heartRate)
        case .morse: v = morseLevel()
        }
        // Agent "needs you" blinks can interrupt any effect for a few seconds.
        if effect != .agents, agentAlertsAnywhere, agentState == .alert, now - agentChanged < 4 {
            v = blink(now - agentChanged, hz: 3)
        }
        let out = enabled ? v * brightness : 0
        if tick % 25 == 0 { syncLid() }
        // With the lid closed macOS may switch the logo off; keep re-asserting our level.
        let reassert = forceWrite || (sleepDisabled && lidClosedSince != nil && tick % 13 == 0)
        if enabled { logo.set(out, force: reassert); forceWrite = false }
        level = out
        if panelVisible, abs(out - live.value) > 0.02 || (out == 0 && live.value != 0) { live.value = out }
    }

    // MARK: morse

    var heartBPM: Int { Int((45 + 95 * heartRate).rounded()) }

    func playMorse() {
        let unit = 1.2 / max(morseWPM, 4)            // PARIS standard
        var t = 0.0
        morseTimeline = Morse.segments(for: morseText).map { seg in
            t += Double(seg.units) * unit
            return (seg.on, t)
        }
        guard !morseTimeline.isEmpty else { return }
        morseLength = t + 7 * unit                    // word gap before repeating
        morseStart = now
        morsePlaying = true
        if effect != .morse { effect = .morse }
    }

    func stopMorse() { morsePlaying = false; morseProgress = 0 }

    private func morseLevel() -> Double {
        let idle = Self.flashRest(strobe: true)
        guard morsePlaying, morseLength > 0 else { return idle }
        var e = now - morseStart
        if e >= morseLength {
            if morseLoop { morseStart += morseLength * floor(e / morseLength); e = now - morseStart }
            else { stopMorse(); return idle }
        }
        if tick % 3 == 0 { morseProgress = min(1, e / morseLength) }
        guard let seg = morseTimeline.first(where: { e < $0.end }) else { return 0 }
        return seg.on ? 1 : Self.flashRest(strobe: true)
    }

    // MARK: effect shapes

    /// Quicker, punchier than breathe: sharp rise, slightly longer fall, low floor.
    private func pulse(_ t: Double, hz: Double) -> Double {
        let p = (t * hz).truncatingRemainder(dividingBy: 1)
        let s = p < 0.35 ? p / 0.35 : 1 - (p - 0.35) / 0.65
        return 0.15 + 0.85 * s * s * (3 - 2 * s)
    }

    /// Two beats (lub, slightly softer dub) then a rest, like a heartbeat trace.
    /// Mid-level "off" for flash effects so each pulse has room to climb (see musicLevel).
    static func flashRest(strobe: Bool = false) -> Double { strobe ? 0.3 : 0.5 }

    /// Lub (full) then dub (softer), each held long enough to register through the fade.
    private func heartbeat(_ t: Double, bpm: Double) -> Double {
        let period = 60 / bpm
        let p = t.truncatingRemainder(dividingBy: period)
        let len = min(0.16, period * 0.18), gap = min(0.12, period * 0.12)
        let rest = Self.flashRest()
        if p < len { return 1 }
        if p > len + gap && p < 2 * len + gap { return rest + (1 - rest) * 0.65 }
        return rest
    }

    private func breathe(_ t: Double, hz: Double, lo: Double = 0.08) -> Double {
        let s = 0.5 - 0.5 * cos(2 * .pi * hz * t)
        return lo + (1 - lo) * s * s * (3 - 2 * s)       // smoothstep for a softer peak
    }

    private func blink(_ t: Double, hz: Double) -> Double {
        (t * hz).truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : Self.flashRest(strobe: true)
    }

    private func batteryLevel(_ t: Double) -> Double {
        if tick % 125 == 1 { readBattery() }
        // Same scale as the brightness slider: 70% battery = logo at 70% (of Max brightness).
        let base = max(0.04, batteryPercent ?? 1)
        guard charging else { return base }
        return base * (0.75 + 0.25 * breathe(t, hz: 0.5, lo: 0))
    }

    private func musicLevel() -> Double {
        guard let snap = audio.engine?.snapshot else { return 0.15 }
        let since = now - snap.lastBeat
        if tick % 13 == 0 { bpm = since < 3 ? Int((60 / snap.interval).rounded()) : nil }
        // corebrightnessd fades every change (~1.5% duty per 20 ms), and a rise from near-dark
        // barely starts before it's released. So: rest at a mid glow, jump to full on the kick,
        // hold long enough for the fade to climb, then release. (Measured: rest 300 nits +
        // 150 ms hold → 25%→49% duty; from dark the same flash moved 2%→4%.)
        let rest = Self.flashRest(strobe: beatStrobe)
        if since > 2.5 { return rest * (0.9 + 0.1 * breathe(now, hz: 0.2, lo: 0)) }   // quiet: idle shimmer
        let hold = min(max(0.35 * snap.interval, 0.12), 0.25) * (0.6 + 0.4 * beatIntensity)
        let peak = rest + (1 - rest) * (0.55 + 0.45 * beatIntensity) * (0.7 + 0.3 * snap.strength)
        return since < hold ? peak : rest
    }

    private func agentLevel(_ t: Double) -> Double {
        let dt = now - agentChanged
        switch agentState {
        case .off: return 0.1
        case .idle: return 0.3
        case .working: return 0.25 + 0.75 * breathe(t, hz: 0.9, lo: 0)
        case .alert: return blink(dt, hz: 3)
        case .done:
            if dt < 1.2 { return blink(dt, hz: 5) }
            if dt > 1.2 { DispatchQueue.main.async { if self.agentState == .done { self.agentState = .idle } } }
            return 0.3
        }
    }

    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            batteryPercent = Double(cur) / Double(max)
            charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return
        }
    }
}
