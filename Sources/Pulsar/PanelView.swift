import SwiftUI

enum Theme {
    static let accent = LinearGradient(colors: [Color(red: 0.62, green: 0.38, blue: 1.0), Color(red: 0.2, green: 0.85, blue: 1.0)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
    static let violet = Color(red: 0.62, green: 0.38, blue: 1.0)
    static let cyan = Color(red: 0.2, green: 0.85, blue: 1.0)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.09)
    static let dim = Color.white.opacity(0.55)
}

struct PanelView: View {
    @EnvironmentObject var engine: LightEngine
    @State private var loginOn = LoginItem.enabled
    @State private var hooksOn = AgentHooks.connected
    @State private var hookError: String?

    var body: some View {
        VStack(spacing: 14) {
            header
            if !engine.hasLogo || !engine.logo.available { noLogoBanner }
            effectPicker
            controls
            logoCard
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(GlowBackground(live: engine.live))
        .onAppear { engine.panelVisible = true }
        .onDisappear { engine.panelVisible = false }
        .preferredColorScheme(.dark)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            LiveOrb(live: engine.live, enabled: engine.enabled)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("pulsar").font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { engine.enabled }, set: { engine.enabled = $0 }))
                .toggleStyle(.switch).tint(Theme.violet).labelsHidden()
        }
    }

    private var statusLine: String {
        // Keep every line short enough to fit the header (~30 characters).
        guard engine.enabled else { return "Off · ⌥-click icon to turn on" }
        switch engine.effect {
        case .steady: return "Steady glow"
        case .breathe: return "Slow breathing"
        case .pulse: return "Steady pulse"
        case .heartbeat: return "Heartbeat · \(engine.heartBPM) BPM"
        case .music:
            if !engine.listening { return "Needs audio access" }
            return engine.bpm.map { "On the beat · \($0) BPM" } ?? "Listening for a beat…"
        case .battery:
            guard let p = engine.batteryPercent else { return "Reading battery…" }
            return "Battery \(Int(p * 100))%" + (engine.charging ? " · charging" : "")
        case .morse: return engine.morsePlaying ? "Sending Morse…" : "Type a message, press play"
        case .agents:
            switch engine.agentState {
            case .off: return hooksOn ? "Waiting for an agent" : "Connect Claude Code below"
            case .idle: return "Agent idle"
            case .working: return "Agent working…"
            case .alert: return "Agent needs you"
            case .done: return "Agent finished"
            }
        }
    }

    private var noLogoBanner: some View {
        Label("No glowing logo found on this Mac. Pulsar needs an M5 Pro/Max MacBook Pro with the PROLED display.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(.orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    // MARK: effects

    private var effectPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Effect.allCases) { e in
                let on = engine.effect == e
                Button { withAnimation(.snappy) { engine.effect = e } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: e.symbol).font(.system(size: 16, weight: .semibold))
                            .symbolEffect(.pulse, isActive: on && e == .music && engine.listening)
                        Text(e.title).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(on ? .white : Theme.dim)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? AnyShapeStyle(Theme.accent.opacity(0.85)) : AnyShapeStyle(Theme.card))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? .clear : Theme.stroke))
                    .shadow(color: on ? Theme.violet.opacity(0.5) : .clear, radius: 10)
                }
                .buttonStyle(.plain)
                .help(e.blurb)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SliderRow(icon: "sun.max", title: engine.effect == .battery ? "Max brightness" : "Brightness",
                      value: $engine.brightness, presets: [0.25, 0.5, 0.75, 1.0])
            switch engine.effect {
            case .battery:
                batteryGauge
            case .breathe:
                SliderRow(icon: "metronome", title: "Pace", value: $engine.breatheSpeed, left: "Calm", right: "Lively")
            case .pulse:
                SliderRow(icon: "metronome", title: "Tempo", value: $engine.pulseSpeed, left: "Slow", right: "Fast")
            case .heartbeat:
                SliderRow(icon: "heart", title: "Heart rate · \(engine.heartBPM) BPM", value: $engine.heartRate, left: "Resting", right: "Racing", showValue: false)
            case .morse:
                morseControls
            case .music:
                SliderRow(icon: "bolt", title: "Punch", value: $engine.beatIntensity, left: "Soft", right: "Hard")
                SliderRow(icon: "ear", title: "Sensitivity", value: $engine.beatSensitivity, left: "Kicks only", right: "Every hit")
                ToggleRow(icon: "circle.lefthalf.filled", title: "Strobe", subtitle: "Dim between beats", isOn: $engine.beatStrobe)
            case .agents:
                agentControls
            default: EmptyView()
            }
        }
        .padding(14)
        .frame(height: 244, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }

    private var batteryGauge: some View {
        let p = engine.batteryPercent ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: engine.charging ? "battery.100percent.bolt" : "battery.75percent")
                    .frame(width: 18).foregroundStyle(Theme.cyan)
                Text("Battery \(Int(p * 100))%").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Logo at \(Int((p * engine.brightness * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.accent).frame(width: g.size.width * p * engine.brightness)
                }
            }
            .frame(height: 6)
            Text(engine.charging ? "Charging: the logo ripples gently" : "Dims as the battery runs down")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
    }

    private var morseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Message", text: $engine.morseText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    .onSubmit { engine.playMorse() }
                Button { engine.morsePlaying ? engine.stopMorse() : engine.playMorse() } label: {
                    Image(systemName: engine.morsePlaying ? "stop.fill" : "play.fill").frame(width: 28, height: 24)
                }
                .buttonStyle(.borderedProminent).tint(Theme.violet).controlSize(.small)
            }
            Text(Morse.preview(engine.morseText))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                .lineLimit(1).truncationMode(.tail)
            ProgressView(value: engine.morseProgress).tint(Theme.cyan).opacity(engine.morsePlaying ? 1 : 0.25)
            HStack {
                Text("Speed · \(Int(engine.morseWPM)) WPM").font(.system(size: 11, weight: .semibold))
                Slider(value: $engine.morseWPM, in: 4...15, step: 1).tint(Theme.violet).controlSize(.mini)
                Toggle("Loop", isOn: $engine.morseLoop).toggleStyle(.checkbox).font(.system(size: 11))
            }
        }
    }

    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "terminal").frame(width: 18).foregroundStyle(Theme.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code").font(.system(size: 12, weight: .semibold))
                    Text(hooksOn ? "Connected" : "Adds hooks to Claude settings")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button(hooksOn ? "Disconnect" : "Connect") {
                    do { hooksOn ? try AgentHooks.disconnect() : try AgentHooks.connect(); hookError = nil }
                    catch { hookError = error.localizedDescription }
                    hooksOn = AgentHooks.connected
                }
                .buttonStyle(.borderedProminent).tint(hooksOn ? .gray : Theme.violet).controlSize(.small)
            }
            if let e = hookError { Text(e).font(.system(size: 10)).foregroundStyle(.red) }
            Text("Scripts: open -g 'pulsar://agent?state=working'")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).textSelection(.enabled)
        }
    }

    // MARK: logo hardware

    private var logoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(icon: "leaf", title: "Battery saver", subtitle: "Fewer updates when unplugged", isOn: $engine.batterySaver)
            ToggleRow(icon: "bell.badge", title: "Agent alerts", subtitle: "Blink when an agent needs you", isOn: $engine.agentAlertsAnywhere)
            ToggleRow(icon: "laptopcomputer", title: "Lit with lid closed",
                      subtitle: engine.lidStatus ?? "Up to 30 min · not in a bag",
                      isOn: $engine.litWithLidClosed)
            ToggleRow(icon: "battery.50percent", title: "Also on battery",
                      subtitle: "Stops at 20% or if it gets hot", isOn: $engine.lidOnBattery)
                .padding(.leading, 18)
                .disabled(!engine.litWithLidClosed).opacity(engine.litWithLidClosed ? 1 : 0.4)
            HStack {
                Image(systemName: "sun.max.trianglebadge.exclamationmark").frame(width: 18).foregroundStyle(Theme.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Full brightness anywhere").font(.system(size: 12, weight: .semibold))
                    Text(engine.limitLifted ? "Room-light limit removed" : "Lift room-light limit · password")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if engine.limitBusy { ProgressView().controlSize(.mini) }
                Toggle("", isOn: Binding(get: { engine.limitLifted }, set: { engine.setLimitLifted($0) }))
                    .toggleStyle(.switch).controlSize(.mini).tint(Theme.violet).labelsHidden().disabled(engine.limitBusy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { loginOn }, set: { LoginItem.set($0); loginOn = LoginItem.enabled }))
                .toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            Text("⌃⌥⌘L").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.dim).padding(.leading, 8)
        }
    }
}

// MARK: components

/// Only these two views observe the live level, so a brightness tick doesn't re-render the whole panel.
struct GlowBackground: View {
    @ObservedObject var live: LiveLevel
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.09)
            RadialGradient(colors: [Theme.violet.opacity(0.28 * (0.3 + live.value)), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Theme.cyan.opacity(0.14 * (0.3 + live.value)), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 300)
        }
    }
}

struct LiveOrb: View {
    @ObservedObject var live: LiveLevel
    var enabled: Bool
    var body: some View { Orb(level: enabled ? live.value : 0) }
}

struct Orb: View {
    var level: Double
    private static let mark = PulsarMark.make(rays: true, size: 26)
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.62, green: 0.38, blue: 1.0).opacity(0.9 * level), .clear],
                                         center: .center, startRadius: 2, endRadius: 22))
                .blur(radius: 6).scaleEffect(1 + 0.25 * level)
            Image(nsImage: Self.mark).renderingMode(.template)
                .foregroundStyle(.white.opacity(0.25 + 0.75 * level))
                .shadow(color: Color(red: 0.2, green: 0.85, blue: 1.0).opacity(level), radius: 8 * level)
        }
        .animation(.linear(duration: 0.04), value: level)
    }
}

struct SliderRow: View {
    var icon: String, title: String
    @Binding var value: Double
    var left: String? = nil, right: String? = nil
    var presets: [Double] = []
    var showValue = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.cyan)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if presets.isEmpty && showValue {
                    Text("\(Int(value * 100))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                } else {
                    ForEach(presets, id: \.self) { p in
                        let on = abs(value - p) < 0.01
                        Button { withAnimation(.snappy) { value = p } } label: {
                            Text("\(Int(p * 100))")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(on ? .white : Theme.dim)
                                .frame(width: 30, height: 18)
                                .background(Capsule().fill(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.07))))
                        }
                        .buttonStyle(.plain)
                        .help("Set brightness to \(Int(p * 100))%")
                    }
                }
            }
            Slider(value: $value, in: 0...1).tint(Theme.violet).controlSize(.small)
            if let l = left, let r = right {
                HStack { Text(l); Spacer(); Text(r) }.font(.system(size: 9)).foregroundStyle(Theme.dim)
            }
        }
    }
}

struct ToggleRow: View {
    var icon: String, title: String, subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).tint(Theme.violet).labelsHidden()
        }
    }
}
