import SwiftUI
import AppKit
import Combine

/// Plain AppKit entry point. There's no SwiftUI App/Scene: a scene-less SwiftUI app still
/// needs a placeholder window (e.g. Settings), and macOS would open that empty window
/// whenever Pulsar comes forward to show its panel.
@main
enum Main {
    static func main() {
        Clamshell.runWatchdogIfAsked()   // exits here when launched as the lid watchdog
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no windows
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = LightEngine()

    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.register { [weak self] in self?.engine.toggle() }
        setUpStatusItem()
        // kill / logout send SIGTERM, which skips applicationWillTerminate: clean up anyway.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.engine.shutdown(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    // MARK: menu-bar item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Pulsar · ⌥-click or right-click to switch the logo on/off"

        let host = NSHostingController(rootView: PanelView().environmentObject(engine))
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize   // explicit size: auto-sizing clipped the left edge
        popover.behavior = .transient
        popover.animates = true
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification, object: popover)
            .sink { [weak self] _ in self?.engine.panelVisible = false }.store(in: &bag)

        engine.menu.$enabled.removeDuplicates()
            .sink { [weak self] on in self?.updateIcon(on) }.store(in: &bag)
    }

    private func updateIcon(_ on: Bool) {
        guard let button = statusItem.button else { return }
        if let custom = MenuBarIcon.custom {
            button.image = custom
            button.alphaValue = on ? 1 : 0.4
        } else {
            button.image = on ? PulsarMark.on : PulsarMark.off
            button.alphaValue = 1
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        // NSEvent.modifierFlags is the live keyboard state; the click event's own flags are
        // often empty for status-bar buttons by the time the action fires.
        let live = NSEvent.modifierFlags
        let ev = NSApp.currentEvent
        let option = live.contains(.option) || (ev?.modifierFlags.contains(.option) ?? false)
        if option || ev?.type == .rightMouseUp {       // ⌥-click (or right-click) toggles the logo
            if popover.isShown { popover.performClose(nil) }
            engine.toggle()
            return
        }
        togglePanel()
    }

    private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        engine.panelVisible = true
        if let v = popover.contentViewController?.view { popover.contentSize = v.fittingSize }
        // A background (menu-bar) app must come forward *before* showing a transient
        // popover, otherwise the popover closes the instant it appears.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// pulsar://agent?state=working|idle|alert|done|off   pulsar://toggle   pulsar://effect?name=music
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func param(_ n: String) -> String? { q.first { $0.name == n }?.value }
            switch url.host {
            case "agent": if let s = param("state").flatMap(AgentState.init(rawValue:)) { engine.setAgent(s) }
            case "toggle": engine.toggle()
            case "panel": togglePanel()
            case "effect": if let e = param("name").flatMap(Effect.init(rawValue:)) { engine.effect = e }
            default: break
            }
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var state: MenuState
    static let custom: NSImage? = {
        guard let img = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        img.isTemplate = true
        return img
    }()
    var body: some View {
        if let img = Self.custom {
            Image(nsImage: img).opacity(state.enabled ? 1 : 0.4)
        } else {
            Image(nsImage: state.enabled ? PulsarMark.on : PulsarMark.off)
        }
    }
}

/// Pulsar's menu-bar mark: a shallow horizon arc with three rays rising from it.
enum PulsarMark {
    static let on = make(rays: true)
    static let off = make(rays: false)

    static func make(rays: Bool, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let s = r.width / 18
            func stroke(_ p: NSBezierPath, _ w: CGFloat) {
                p.lineWidth = w * s; p.lineCapStyle = .round; p.lineJoinStyle = .round
                NSColor.black.setStroke(); p.stroke()
            }
            // Horizon: flat top with rounded shoulders.
            let arc = NSBezierPath()
            arc.move(to: NSPoint(x: 3.6 * s, y: 4.2 * s))
            arc.curve(to: NSPoint(x: 6.4 * s, y: 6.6 * s), controlPoint1: NSPoint(x: 4.3 * s, y: 5.6 * s), controlPoint2: NSPoint(x: 5.2 * s, y: 6.6 * s))
            arc.line(to: NSPoint(x: 11.6 * s, y: 6.6 * s))
            arc.curve(to: NSPoint(x: 14.4 * s, y: 4.2 * s), controlPoint1: NSPoint(x: 12.8 * s, y: 6.6 * s), controlPoint2: NSPoint(x: 13.7 * s, y: 5.6 * s))
            stroke(arc, 1.7)
            if rays {
                for (a, b) in [((9.0, 10.0), (9.0, 14.6)), ((6.2, 9.4), (3.9, 11.7)), ((11.8, 9.4), (14.1, 11.7))] {
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: a.0 * s, y: a.1 * s)); p.line(to: NSPoint(x: b.0 * s, y: b.1 * s))
                    stroke(p, 1.7)
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
