import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Global ⌃⌥⌘L shortcut to switch the logo on/off.
enum HotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func register(_ handler: @escaping () -> Void) {
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x50554C53), id: 1)   // 'PULS'
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { NSLog("Pulsar: login item: \(error)") }
    }
}

/// Wires Claude Code hooks to pulsar:// URLs. Edits ~/.claude/settings.json only when the user clicks Connect.
enum AgentHooks {
    static let marker = "pulsar://agent"
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static let events: [(String, AgentState)] = [
        ("SessionStart", .idle), ("UserPromptSubmit", .working), ("PreToolUse", .working),
        ("Notification", .alert), ("Stop", .done), ("SessionEnd", .off),
    ]

    static var connected: Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.contains(marker)
    }

    static func command(_ s: AgentState) -> String { "open -g '\(marker)?state=\(s.rawValue)'" }

    static func connect() throws { try edit(add: true) }
    static func disconnect() throws { try edit(add: false) }

    private static func edit(add: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Pulsar", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json isn't a JSON object"])
            }
            root = obj
            let backup = settingsURL.appendingPathExtension("pulsar-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, state) in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.removeAll { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if add { groups.append(["hooks": [["type": "command", "command": command(state)]]]) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }
}
