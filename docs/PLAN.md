# Perch — plan

Perch is a small native macOS app that lives in the **notch** and the **menu bar** and
holds one-click toggles for your development environment. The first toggle replaces
running `sudo pmset -a disablesleep 0|1` by hand.

## Goals

1. Toggle "disable sleep" (keeps the Mac running with the lid closed) from:
   - the **notch** — hover it and it opens into a panel; a badge shows while the Mac is kept awake,
   - the **menu bar** — click for a glass panel, right-click for a quick menu, ⌥-click to toggle,
   - a **global shortcut** — default `⌃⌥⌘S`, can be changed in Settings.
2. Don't ask for a password every time, without giving the app broad root access.
3. A clean, native UI with calm spring animations, in light and dark mode.
4. Make it easy to add more developer toggles later ("modules").

## How the privileged part works

`pmset -a disablesleep` needs root. The options:

| Option | Verdict |
| --- | --- |
| Admin password prompt on every toggle (`do shell script … with administrator privileges`) | Kept as a fallback only; too much friction for daily use |
| `SMAppService` privileged daemon + XPC | Needs a paid Developer ID and notarization; too heavy for a personal tool |
| **Narrow sudoers rule** installed once, after the user approves | **Chosen** |

The one-time setup writes `/etc/sudoers.d/perch`, which allows **only** these exact commands
for your user, with no password:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

Perch then runs `sudo -n /usr/bin/pmset -a disablesleep 1`. The file is written by root inside
the admin prompt, checked with `visudo -c` before it is moved into place, and can be removed
from Settings. Modules declare the root commands they need, so the rule is built from what
the modules ask for. When a future module adds a command, Perch notices that the installed rule
is out of date and offers to update it.

The current state is read with `pmset -g` (no root needed, about 7 ms), checked every 10 s and
whenever a panel opens, so changes made from the Terminal also show up.

## Safety around "stay awake with lid closed"

A closed MacBook that never sleeps can get hot in a bag. Perch adds:

- **Timers**: keep awake for 15 m / 30 m / 1 h / 2 h / 4 h, or until turned off. The end time is
  saved, so the timer still runs out after a relaunch.
- **Battery guard**: turns sleep back on when the Mac runs on battery below a set level (default 15 %).
- **Heat guard**: turns sleep back on when the thermal state is *critical*, or *serious* with the lid closed.
- Optional: turn sleep back on when Perch quits.

Each automatic change shows a short notch message and leaves a note on the module card.

## Architecture

Swift Package (no Xcode project needed; `Package.swift` also opens in Xcode). AppKit hosts
the windows and SwiftUI draws all the UI. Target: macOS 14+ (Observation framework, symbol effects).

```
Sources/Perch/
  App/            main.swift, AppDelegate, AppModel (wires everything together)
  Core/           PerchModule protocol, ModuleRegistry, AutoOffTimer, Preferences,
                  Shell, PrivilegedAccess (sudoers), HotKeys (Carbon), PowerMonitor, HUD, LoginItem
  Modules/
    StayAwake/    pmset disablesleep, timers, battery and heat guards
    ScreenOn/     IOPMAssertion that stops the display from sleeping (no root; shows how to add a module)
  UI/
    DesignSystem/ colors, GlowIcon, PillToggle, DurationChips, cards
    MenuBar/      NSStatusItem + Liquid Glass panel (NSGlassEffectView) + right-click menu
    Notch/        fixed canvas panel + invisible hot zone, NotchShape, staged animation
    Settings/     settings window, shortcut recorder
scripts/          build-app.sh (builds the .app bundle and signs it ad hoc), make-icon.swift
```

### The module contract

Each tool is a class that conforms to `PerchModule`:

```swift
@MainActor protocol PerchModule: AnyObject {
    var id: String { get }                 // stable key for preferences and shortcuts
    var title: String { get }
    var caption: String { get }
    var tint: Color { get }
    var symbol: String { get }             // SF Symbol for the current state
    var isOn: Bool { get }
    var isBusy: Bool { get }
    var statusText: String { get }
    var timer: AutoOffTimer? { get }       // non-nil = supports "on for 30 min"
    var privilegedCommands: [[String]] { get }  // root commands → sudoers rule
    var defaultShortcut: KeyCombo? { get }
    func setOn(_ on: Bool, source: ToggleSource) async
    func refresh() async
}
```

The menu bar panel, notch panel, right-click menu, shortcut settings and sudoers rule are all
built from the registered modules. Adding a tool means writing one class and adding it to
`AppModel.makeModules()`.

### Notch states

Black, like the hardware notch it grows out of.

| State | When | Looks like |
| --- | --- | --- |
| idle | nothing on | hidden inside the hardware notch |
| expanded | hover (0.3 s) or click | a black list: stats line, the main module written out, a line per other module |
| HUD | changed by shortcut or automation | wings beside the camera for 1.5 s: "☀ Stay Awake ··· on · 1h" |
| badge | a module is on | the notch a little wider, the same on both sides: the module's symbol (and a thermometer when the Mac runs hot) left of the camera, the time left on the right when a timer is set. Can be turned off in Settings; nothing ever shows below the notch |

The notch is drawn in a **fixed-size canvas** panel centred on the camera. It never moves or
resizes, so the shape always grows out of the centre and shrinks back into it. The black shape is
Core Animation layers (body plus two small curves where it meets the screen edge), and the
SwiftUI content above it is masked to the same outline. The canvas lets clicks through except
while open, and a small invisible **hot zone** panel over the camera notices hovering and clicks,
so nothing blocks the menu bar.

Opening runs in stages: the notch **stretches sideways from the camera as a line**, then
**drops down**, then the list blurs into focus and the shadow fades in. Closing runs backwards
and never bounces. Width, height and corner radii are separate springs, so a stage can start
while the previous one is still moving, and a new target reverses from wherever the shape is.
All of it runs in the window server at the display's full rate. With Reduce Motion on, every
change is a short cross-fade.

### Design

- Black surfaces for the notch and the menu bar panel, with the same list in both:
  - a monospaced stats line: `awake 1h12m | bat 80% 3h40m | temp cool`, values colored by state,
  - the main module written out: symbol (in its color while on), title, a gray description,
    and a duration track `∞ 15m 30m 1h 2h 4h` whose thumb slides to the choice,
  - one line per other module: a dot in its color while on, and the title.
- Controls are SwiftUI rather than AppKit, because the notch panel never becomes key (it must
  not take your typing focus) and AppKit controls draw dimmed there.
- Settings: a standard preferences window with toolbar tabs and grouped forms.
- System colors for states (orange Stay Awake, blue Screen On, green/yellow/red readings).

## Ideas for later modules

- Kill whatever is listening on a port (`lsof -ti :3000 | xargs kill`)
- Flush DNS cache (root, same sudoers pattern)
- Show hidden files in Finder
- Clear Xcode DerivedData / simulator caches
- Docker / Colima / OrbStack start-stop and status
- Toggle a local proxy or VPN profile
- Keep awake while a chosen process runs (long builds)

## Milestones

1. ✅ Plan
2. ✅ Core: modules, privileged access, pmset, hotkeys, power monitor
3. ✅ Menu bar panel and right-click menu
4. ✅ Notch overlay with animations
5. ✅ Settings, onboarding, app icon, build script
6. ✅ Build, run, check (unit tests, rendered previews, window placement, idle CPU at 0%)

Next: sign with a Developer ID and notarize if Perch is shared with other people. A
`SMAppService` helper could then replace the sudoers rule.
