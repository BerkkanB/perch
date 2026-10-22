import AppKit

/// Debug-only launch flags for checking the real UI:
///   --demo-notch idle|badge|hud|expanded   pins the notch in that state
///   --demo-menu                            opens the menu bar panel
///   --snapshot <dir>                       captures every window and state to PNGs, then quits
@MainActor
enum DemoMode {
    static func apply(
        arguments: [String],
        model: AppModel,
        notch: NotchController,
        statusItem: StatusItemController,
        settings: SettingsWindowController,
        standby: StandByController
    ) {
        #if DEBUG
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if let name = value(after: "--demo-notch"), let phase = phase(named: name) {
            if phase == .hud { showSampleHUD(model) }
            notch.model.forcedPhase = phase
        }
        if arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { statusItem.showPanel() }
        }
        if let directory = value(after: "--snapshot") {
            Task {
                await Snapshotter(directory: directory).run(model: model, notch: notch, statusItem: statusItem, settings: settings, standby: standby)
                exit(0)
            }
        }
        #endif
    }

    #if DEBUG
    static func phase(named name: String) -> NotchModel.Phase? {
        switch name {
        case "idle": .idle
        case "badge": .badge
        case "hud": .hud
        case "expanded": .expanded
        default: nil
        }
    }

    static func showSampleHUD(_ model: AppModel) {
        model.hud.show(HUDMessage(symbol: "sun.max.fill", title: "Stay Awake", value: "On · 1h", tint: Palette.stayAwake), for: 3600)
    }
    #endif
}

#if DEBUG
/// Captures Perch's own windows (no Screen Recording permission needed for your own windows).
@MainActor
private struct Snapshotter {
    let directory: String

    private typealias CaptureFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    func run(model: AppModel, notch: NotchController, statusItem: StatusItemController, settings: SettingsWindowController, standby: StandByController) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        await wait(1200)

        // Notch states.
        for name in ["idle", "badge", "hud", "expanded"] {
            if name == "hud" { DemoMode.showSampleHUD(model) }
            notch.model.forcedPhase = DemoMode.phase(named: name)
            await wait(900)
            capture(notch.canvasWindow, as: "notch-\(name)", background: .menuBar)
        }

        // A secondary module switched on, to check the "on" styling.
        if let other = model.secondary.first {
            await other.setOn(true, source: .ui)
            await wait(500)
            capture(notch.canvasWindow, as: "notch-expanded-both-on", background: .menuBar)
            await other.setOn(false, source: .ui)
        }

        // The badge with a timer and with the heat warning, without running pmset.
        notch.model.forcedPhase = .badge
        model.stayAwake.setPreviewState(isOn: true)
        for (name, timer, hot) in [("plain", false, false), ("timer", true, false), ("hot", false, true), ("timer-hot", true, true)] {
            if timer { model.stayAwake.autoOff.start(duration: 72 * 60) } else { model.stayAwake.autoOff.cancel() }
            model.power.setPreviewThermalState(hot ? .serious : .nominal)
            await wait(700)
            capture(notch.canvasWindow, as: "badge-\(name)", background: .menuBar)
        }
        model.stayAwake.autoOff.cancel()
        model.power.update()
        notch.model.forcedPhase = .expanded

        // Stay Awake shown as on for an hour, without running pmset.
        model.stayAwake.setPreviewState(isOn: true)
        model.stayAwake.autoOff.start(duration: 60 * 60)
        await wait(500)
        capture(notch.canvasWindow, as: "notch-expanded-awake", background: .menuBar)
        model.stayAwake.autoOff.cancel()
        model.stayAwake.setPreviewState(isOn: false)

        // The opening and closing motion, frame by frame.
        notch.model.forcedPhase = .badge
        await wait(900)
        notch.model.forcedPhase = .expanded
        for frame in 0..<10 {
            await wait(35)
            capture(notch.canvasWindow, as: "open-\(frame)", background: .menuBar)
        }
        await wait(600)
        notch.model.forcedPhase = .badge
        for frame in 0..<10 {
            await wait(35)
            capture(notch.canvasWindow, as: "close-\(frame)", background: .menuBar)
        }
        notch.model.forcedPhase = nil
        model.hud.dismiss()

        // Coding agent sessions, from simulated hook events.
        let ghostty = ["__CFBundleIdentifier": "com.mitchellh.ghostty"]
        let terminal = ["__CFBundleIdentifier": "com.apple.Terminal"]
        let agents = model.agents
        agents.simulate(["hook_event_name": "SessionStart", "session_id": "a", "cwd": "/code/auth-service"], environment: ghostty)
        agents.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "a", "prompt": "fix the auth bug in middleware"])
        agents.simulate(["hook_event_name": "PreToolUse", "session_id": "a", "tool_name": "Write", "tool_input": ["file_path": "/code/auth-service/middleware.ts"]])
        agents.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "b", "cwd": "/code/backend", "prompt": "run the server and watch logs"], environment: terminal)
        agents.simulate(["hook_event_name": "PreToolUse", "session_id": "b", "tool_name": "Bash", "tool_input": ["command": "npm run dev"]])
        agents.simulate(["hook_event_name": "Stop", "session_id": "c", "cwd": "/code/queries"], environment: ghostty)
        agents.simulateUsage(AgentUsage(
            fiveHour: .init(usedPercent: 11, resetsAt: .now.addingTimeInterval(4 * 3600 + 60)),
            sevenDay: .init(usedPercent: 2, resetsAt: .now.addingTimeInterval(6 * 3600 + 60))
        ))
        notch.model.forcedPhase = .badge
        await wait(900)
        capture(notch.canvasWindow, as: "glance-working", background: .menuBar)
        notch.model.forcedPhase = .expanded
        await wait(900)
        capture(notch.canvasWindow, as: "notch-agents", background: .menuBar)

        agents.simulate(["hook_event_name": "PermissionRequest", "session_id": "b", "tool_name": "Bash", "tool_input": [
            "command": "npm install lodash --save &&\n  npm run build -- --mode production &&\n  git add -A && git commit -m \"Add lodash and rebuild the production bundle\" &&\n  git push origin main",
            "description": "Install lodash, rebuild and push",
        ]])
        await wait(1500)
        capture(notch.canvasWindow, as: "notch-approval", background: .menuBar)
        notch.model.forcedPhase = .badge
        await wait(900)
        capture(notch.canvasWindow, as: "glance-waiting", background: .menuBar)
        notch.model.forcedPhase = .expanded

        agents.simulate(["hook_event_name": "PermissionRequest", "session_id": "b", "tool_name": "AskUserQuestion", "tool_input": ["questions": [
            [
                "question": "Which version bump should I use for this release?",
                "header": "Version",
                "multiSelect": false,
                "options": [
                    ["label": "Minor (1.4.0)", "description": "New features: the agents panel and StandBy. Nothing that worked before breaks."],
                    ["label": "Patch (1.3.1)", "description": "Only if you'd rather ship the fixes now and the features later."],
                    ["label": "Major (2.0.0)", "description": "Signals a big change, though nothing is incompatible."],
                ],
            ],
            [
                "question": "What should the release notes cover?",
                "header": "Notes",
                "multiSelect": true,
                "options": [
                    ["label": "New features", "description": "Agents in the notch, StandBy, Sleep Now"],
                    ["label": "Fixes", "description": "Session order, long approvals"],
                    ["label": "Known issues", "description": ""],
                ],
            ],
        ]]])
        await wait(900)
        capture(notch.canvasWindow, as: "notch-question", background: .menuBar)

        // Menu bar panel.
        statusItem.showPanel()
        await wait(700)
        capture(statusItem.panelWindow, as: "menu", background: .desktop)
        statusItem.closePanel()

        // StandBy, built off screen so the snapshot doesn't take over the Mac.
        standby.show(onScreen: false)
        await wait(1500)
        capture(standby.contentWindow, as: "standby", background: nil)
        standby.hide()
        for id in ["claude:a", "claude:b", "claude:c"] { agents.dismiss(id) }

        // Settings tabs.
        for tab in SettingsTab.allCases {
            settings.show(tab: tab)
            await wait(700)
            capture(settings.window, as: "settings-\(tab.title.lowercased().replacingOccurrences(of: " ", with: "-"))", background: nil)
        }
        settings.window?.close()
        print("Snapshots written to \(directory)")
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    enum Background { case menuBar, desktop }

    private func capture(_ window: NSWindow?, as name: String, background: Background?) {
        guard let window,
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return }
        let create = unsafeBitCast(symbol, to: CaptureFunction.self)
        // Only this window, without its frame shadow, at full resolution.
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return }

        let size = NSSize(width: image.width, height: image.height)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        switch background {
        case .menuBar:
            NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.80, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor(white: 1, alpha: 0.3).setFill()
            NSRect(x: 0, y: size.height - 64, width: size.width, height: 64).fill() // 32 pt menu bar at 2x
        case .desktop:
            NSGradient(starting: NSColor(calibratedRed: 0.42, green: 0.50, blue: 0.72, alpha: 1),
                       ending: NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.70, alpha: 1))?
                .draw(in: NSRect(origin: .zero, size: size), angle: -45)
        case nil:
            break
        }
        context.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }
}
#endif
