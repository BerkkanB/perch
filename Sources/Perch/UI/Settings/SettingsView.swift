import SwiftUI

/// The tabs of the Settings window. Each is a grouped form, like System Settings.
enum SettingsTab: CaseIterable {
    case general, agents, shortcuts, stayAwake, permissions

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .shortcuts: "Shortcuts"
        case .stayAwake: "Stay Awake"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .agents: "sparkle"
        case .shortcuts: "command"
        case .stayAwake: "sun.max"
        case .permissions: "lock"
        }
    }

    var height: CGFloat {
        switch self {
        case .general: 400
        case .agents: 272
        case .shortcuts: 196
        case .stayAwake: 268
        case .permissions: 250
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .general: GeneralSettings()
        case .agents: AgentSettings()
        case .shortcuts: ShortcutSettings()
        case .stayAwake: StayAwakeSettings()
        case .permissions: PermissionSettings()
        }
    }
}

struct SettingsPage<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 500, height: tab.height)
    }
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.prefs

        SettingsPage(tab: .general) {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { app.loginItem.isEnabled },
                    set: { app.loginItem.set($0) }
                ))
                if let error = app.loginItem.lastError {
                    Text(error).font(.callout).foregroundStyle(Palette.danger)
                }
                Toggle("Show time left in the menu bar", isOn: $prefs.menuBarShowsCountdown)
            }

            Section("Notch") {
                Toggle("Show Perch in the notch", isOn: $prefs.notchEnabled)
                Group {
                    Toggle("Open when the pointer rests on the notch", isOn: $prefs.notchExpandsOnHover)
                    Toggle("Show what agents are doing beside the camera", isOn: $prefs.notchShowsAgentActivity)
                    Toggle("Show an icon beside the camera while a switch is on", isOn: $prefs.notchShowsBadge)
                    Toggle("Show a brief message when something changes", isOn: $prefs.notchShowsHUD)
                }
                .disabled(!prefs.notchEnabled)
            }

            Section {
                LabeledContent("Version", value: Self.version)
            }
        }
        .onAppear { app.loginItem.refresh() }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

// MARK: Agents

struct AgentSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.prefs
        let claude = app.agents.claude

        SettingsPage(tab: .agents) {
            Section {
                LabeledContent {
                    if claude.isConnected {
                        Button("Disconnect") { claude.disconnect() }
                    } else {
                        Button("Connect") { claude.connect() }
                    }
                } label: {
                    Text("Claude Code")
                    Text(claude.isConnected
                         ? "Connected. Sessions, approvals and usage show in the notch."
                         : "Not connected.")
                }
                if let error = claude.lastError {
                    Text(error).font(.callout).foregroundStyle(Palette.danger)
                }
                if let error = app.agents.serverError {
                    Text(error).font(.callout).foregroundStyle(Palette.danger)
                }
            } header: {
                Text("Coding Agents")
            } footer: {
                Text("Connecting adds hooks and a status line to ~/.claude/settings.json; the previous file is kept in ~/.perch/backups. Sessions started afterwards show up in Perch.")
            }

            Section {
                Toggle(isOn: $prefs.agentApprovalsInNotch) {
                    Text("Ask for approvals in the notch")
                    Text("Otherwise Claude Code asks in its terminal as usual.")
                }
                Toggle("Show a message when an agent finishes", isOn: $prefs.agentShowsFinished)
            }
        }
        .onAppear { claude.refresh() }
    }
}

// MARK: Shortcuts

struct ShortcutSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsPage(tab: .shortcuts) {
            Section {
                ForEach(app.modules, id: \.id) { module in
                    LabeledContent(module.title) {
                        ShortcutRecorder(name: module.id, fallback: module.defaultShortcut)
                    }
                }
                LabeledContent("Open Perch Menu") {
                    ShortcutRecorder(name: AppModel.menuShortcutName, fallback: nil)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Shortcuts work in every app. While recording, press Esc to cancel or Delete to clear.")
            }
        }
    }
}

// MARK: Stay Awake

struct StayAwakeSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.prefs

        SettingsPage(tab: .stayAwake) {
            Section {
                Toggle(isOn: $prefs.batteryGuardEnabled) {
                    Text("When the battery is low")
                    Text("Only while running on battery.")
                }
                Picker("Battery level", selection: $prefs.batteryGuardThreshold) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!prefs.batteryGuardEnabled)
                Toggle(isOn: $prefs.heatGuardEnabled) {
                    Text("When the Mac gets too hot")
                    Text("For example, closed in a bag.")
                }
            } header: {
                Text("Let the Mac Sleep Again")
            }

            Section {
                Toggle(isOn: $prefs.restoreSleepOnQuit) {
                    Text("Turn sleep back on when Perch quits")
                    Text("Always happens while a timer is running.")
                }
            }
        }
    }
}

// MARK: Permissions

struct PermissionSettings: View {
    @Environment(AppModel.self) private var app
    @State private var error: String?
    @State private var showsRule = false

    var body: some View {
        SettingsPage(tab: .permissions) {
            Section {
                LabeledContent {
                    if app.access.isCurrent {
                        Button("Remove…", role: .destructive) { run { try app.access.removeRule() } }
                    } else {
                        Button(app.access.isInstalled ? "Update…" : "Allow…") { run { try app.access.installRule() } }
                    }
                } label: {
                    Text("Password-free switching")
                    Text(status)
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(Palette.danger)
                }

                DisclosureGroup("Rule", isExpanded: $showsRule) {
                    Text(app.access.previewRule)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text("Stored in \(PrivilegedAccess.rulePath). It lets only your user run only the exact commands listed, without a password.")
            }
        }
        .onAppear { app.access.refresh() }
    }

    private var status: String {
        if app.access.isCurrent { return "On. Perch switches sleep without asking for your password." }
        if app.access.isInstalled { return "Needs an update for the current switches." }
        return "Off. macOS asks for your password each time."
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch PrivilegeError.cancelled {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
