import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                UserChip()
                Logo().padding(.top, 14).padding(.bottom, 18)
                StatusPanel()
                Spacer(minLength: 16)
                ActionColumn()
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WindowControls()
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
        // background, not a ZStack child: a scaledToFill image must not drive the layout size
        .background { Backdrop(image: launcher.background) }
        .background(WindowConfigurator())
        .animation(.easeOut(duration: 0.25), value: launcher.phase)
    }
}

// MARK: - Left column

struct UserChip: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Theme.orange
                Image(systemName: "skateboard")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(launcher.steamLoggedIn ? Theme.green : Color(white: 0.45))
                    .frame(width: 9, height: 9)
                    .offset(x: -3, y: -3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome, \(launcher.displayName)").font(Theme.bold(13))
                Text("Mac Launcher 1.1").font(Theme.medium(11)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12)
            .frame(width: 210, height: 40, alignment: .leading)
            .background(Theme.panel)
        }
        .help(launcher.steamLoggedIn ? "Steam: signed in" : "Steam: offline")
    }
}

struct StatusPanel: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        HStack(spacing: 0) {
            accent.frame(width: 4)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("STATUS").font(Theme.heavy(21))
                    Spacer()
                    Pill(text: pill.0, color: pill.1)
                }
                switch launcher.phase {
                case .welcome: WelcomeStatus()
                case .setup: SetupStatus()
                case .ready: ReadyStatus()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Theme.panel)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pill: (String, Color) {
        switch launcher.phase {
        case .welcome: ("SETUP", Theme.orange)
        case .setup: launcher.setupError == nil ? ("INSTALLING", Theme.blue) : ("ERROR", Theme.red)
        case .ready:
            switch launcher.gameState {
            case .idle: launcher.lastError == nil ? ("READY", Theme.green) : ("ERROR", Theme.red)
            case .starting: ("STARTING", Theme.blue)
            case .running: ("RUNNING", Theme.green)
            }
        }
    }

    private var accent: Color { pill.1 }
}

struct WelcomeStatus: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusRow(icon: .warn, title: "Setup required",
                      detail: "One-time install, about \(launcher.withStudio ? 600 : 400) MB.", large: true)
            Divided()
            StatusRow(icon: .pending, title: "Wine 11", detail: "Windows compatibility layer")
            StatusRow(icon: .pending, title: "Apple GPTK 4.0-2", detail: "DirectX 12 on Metal")
            StatusRow(icon: .pending, title: "ReSkate", detail: "Latest release from GitHub")
            StatusRow(icon: .pending, title: "Steam", detail: "Needed for multiplayer, sign in with a QR code")
            HStack(alignment: .top) {
                StatusRow(icon: launcher.withStudio ? .ok : .pending, title: "ReSkate Studio (optional)",
                          detail: launcher.withStudio ? launcher.studioSource?.lastPathComponent : "Mod and map editor, from ReSkate_Studio.zip")
                Toggle("", isOn: studioToggle).toggleStyle(.switch).tint(Theme.blue).labelsHidden()
            }
            HStack(alignment: .top) {
                StatusRow(icon: launcher.reshade ? .ok : .pending, title: "ReShade (optional)",
                          detail: "Post-processing effects, menu on \(ReShadeKey.name(launcher.reshadeKey))")
                Toggle("", isOn: $launcher.reshade).toggleStyle(.switch).tint(Theme.blue).labelsHidden()
            }
            Text("Already have ReSkate? Pick its folder under GAME FOLDER and nothing gets downloaded twice.")
                .font(Theme.medium(11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Turning Studio on asks for its zip right away; cancelling leaves it off
    private var studioToggle: Binding<Bool> {
        Binding(get: { launcher.withStudio }, set: { on in
            launcher.withStudio = on && (launcher.studioSource != nil || launcher.chooseStudio())
        })
    }
}

struct SetupStatus: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(launcher.setupSteps) { step in
                let status = launcher.status[step] ?? StepStatus()
                StatusRow(icon: RowIcon(status.state), title: step.title, detail: status.detail, progress: status.progress)
            }
            if let error = launcher.setupError {
                Divided()
                Text(error)
                    .font(Theme.medium(12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ReadyStatus: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            Divided()
            if let build = launcher.gameBuild {
                StatusRow(icon: .ok, title: "skate. build \(build)")
            }
            StatusRow(icon: .ok, title: "ReSkate \(launcher.reskateVersion ?? "")")
            StatusRow(icon: .ok, title: "Wine 11 · GPTK 4.0-2")
            if launcher.reshade {
                StatusRow(icon: launcher.reshadeInstalled ? .ok : .warn, title: "ReShade",
                          detail: launcher.reshadeInstalled ? "Menu on \(ReShadeKey.name(launcher.reshadeKey)) in game" : "Run REPAIR to install it")
            }
            steamRow
            if launcher.waitingForSteam {
                Button("START OFFLINE") { launcher.startOffline() }
                    .buttonStyle(.plain)
                    .font(Theme.heavy(11))
                    .foregroundStyle(Theme.blue)
            }
        }
    }

    @ViewBuilder private var headline: some View {
        switch launcher.gameState {
        case .idle:
            if let error = launcher.lastError {
                StatusRow(icon: .error, title: "Launch failed", detail: error, large: true)
            } else {
                StatusRow(icon: .ok, title: "Ready to skate", detail: "Everything is installed.", large: true)
            }
        case .starting(let message):
            StatusRow(icon: .busy, title: "Starting", detail: message, large: true)
        case .running:
            StatusRow(icon: .ok, title: "Skating", detail: "First launch compiles shaders for a few minutes.", large: true)
        }
    }

    @ViewBuilder private var steamRow: some View {
        if !launcher.steamInstalled {
            StatusRow(icon: .warn, title: "Steam not installed", detail: "Run REPAIR to install it")
        } else if launcher.steamLoggedIn {
            StatusRow(icon: .ok, title: "Steam signed in")
        } else if launcher.hasAutoLogin {
            StatusRow(icon: .ok, title: "Steam starts with the game")
        } else {
            StatusRow(icon: .warn, title: "Steam offline", detail: "Sign in once to enable multiplayer")
        }
    }
}

// MARK: - Right column

struct ActionColumn: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        VStack(spacing: 10) {
            switch launcher.phase {
            case .welcome:
                ActionPanel(title: "GAME FOLDER", subtitle: launcher.gameDir.path.tilde, symbol: "folder") {
                    launcher.chooseGameDir()
                }
                .help("Change where ReSkate is installed")
                BigBlock(title: "INSTALL", subtitle: launcher.withStudio ? "About 600 MB with Studio" : "About 400 MB") { launcher.startSetup() }
            case .setup:
                if launcher.waitingForLogin {
                    ActionPanel(title: "SKIP STEAM", subtitle: "Play without multiplayer", symbol: "forward") {
                        launcher.skipSteamLogin()
                    }
                }
                if launcher.setupError != nil {
                    ActionPanel(title: "LOGS", subtitle: "See what went wrong", symbol: "doc.text") { launcher.openLogs() }
                    BigBlock(title: "RETRY", subtitle: "Resume setup") { launcher.startSetup(launcher.setupSteps) }
                } else {
                    BigBlock(title: "INSTALLING", subtitle: currentStep, enabled: false) {}
                }
            case .ready:
                ActionPanel(title: "STEAM", subtitle: steamSubtitle, symbol: "person.2") { launcher.showSteam() }
                if launcher.studioInstalled {
                    ActionPanel(title: "STUDIO", subtitle: studioSubtitle, symbol: "hammer") { launcher.openStudio() }
                        .disabled(launcher.studioState != .idle)
                } else {
                    ActionPanel(title: "STUDIO", subtitle: "Add the mod editor (ReSkate_Studio.zip)", symbol: "hammer") {
                        launcher.addStudio()
                    }
                }
                ToolsPanel()
                BigBlock(title: playTitle, subtitle: "ReSkate \(launcher.reskateVersion ?? "")",
                         enabled: launcher.gameState == .idle) { launcher.play() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var currentStep: String {
        if launcher.waitingForInstaller { return "Finish the Studio installer" }
        return launcher.setupSteps.first { launcher.status[$0]?.state == .running }?.title ?? "Finishing…"
    }

    private var steamSubtitle: String {
        if launcher.steamLoggedIn { return "Signed in" }
        if launcher.steamRunning { return "Signing in…" }
        return launcher.hasAutoLogin ? "Starts with the game" : "Not signed in"
    }

    private var studioSubtitle: String {
        switch launcher.studioState {
        case .idle: "Open \(launcher.studioName) · ReSkate is on R:"
        case .starting: "Starting…"
        case .running: "Open"
        }
    }

    private var playTitle: String {
        switch launcher.gameState {
        case .idle: "PLAY"
        case .starting: "STARTING"
        case .running: "RUNNING"
        }
    }
}

struct ToolsPanel: View {
    @EnvironmentObject var launcher: Launcher
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Open Game Folder") { launcher.openGameDir() }
            Button("Open Logs") { launcher.openLogs() }
            Button("Change Game Folder…") { launcher.chooseGameDir() }
            if launcher.studioInstalled {
                Divider()
                Button("Open Studio Folder") { launcher.openStudioDir() }
                Button("Update Studio…") { launcher.addStudio() }
            }
            Divider()
            Toggle("ReShade", isOn: Binding(get: { launcher.reshade }, set: { launcher.setReShade($0) }))
            Picker("ReShade Menu Key", selection: $launcher.reshadeKey) {
                ForEach(ReShadeKey.all, id: \.vk) { Text($0.name).tag($0.vk) }
            }
            .disabled(!launcher.reshade)
            Divider()
            Button("Repair Install") { launcher.startSetup() }
        } label: {
            PanelLabel(title: "TOOLS", subtitle: "Folder · Logs · Repair", symbol: "wrench.and.screwdriver", hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(PressStyle())
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}
