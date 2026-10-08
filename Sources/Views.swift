import AppKit
import SwiftUI

// Look of the ReSkate launcher: photo backdrop, flat dark panels, Montserrat + Permanent Marker, blue PLAY block.
enum Theme {
    static let panel = Color(red: 0.1, green: 0.1, blue: 0.11).opacity(0.94)
    static let panelHover = Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.96)
    static let line = Color.white.opacity(0.12)
    static let dim = Color.white.opacity(0.62)
    static let green = Color(red: 0.2, green: 0.78, blue: 0.4)
    static let blue = Color(red: 0.0, green: 0.55, blue: 1.0)
    static let orange = Color(red: 0.96, green: 0.52, blue: 0.13)
    static let red = Color(red: 0.95, green: 0.3, blue: 0.27)
    static let ink = Color(white: 0.06)

    static func heavy(_ size: CGFloat) -> Font { .custom("Montserrat-ExtraBold", size: size) }
    static func bold(_ size: CGFloat) -> Font { .custom("Montserrat-Bold", size: size) }
    static func semibold(_ size: CGFloat) -> Font { .custom("Montserrat-SemiBold", size: size) }
    static func medium(_ size: CGFloat) -> Font { .custom("Montserrat-Medium", size: size) }
    static func marker(_ size: CGFloat) -> Font { .custom("PermanentMarker-Regular", size: size) }
}

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

struct Backdrop: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.45)
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }
}

// MARK: - Window chrome

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

struct WindowControls: View {
    var body: some View {
        HStack(spacing: 18) {
            ChromeButton(symbol: "minus") { NSApp.keyWindow?.miniaturize(nil) }
            ChromeButton(symbol: "xmark") { NSApp.terminate(nil) }
        }
    }
}

struct ChromeButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                Text("Mac Launcher 1.0").font(Theme.medium(11)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12)
            .frame(width: 210, height: 40, alignment: .leading)
            .background(Theme.panel)
        }
        .help(launcher.steamLoggedIn ? "Steam: signed in" : "Steam: offline")
    }
}

struct Logo: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: -6) {
            Text("RESKATE")
                .font(Theme.marker(58))
                .foregroundStyle(.white)
            Text("MAC VERSION")
                .font(Theme.heavy(13))
                .tracking(4)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.orange)
        }
        .rotationEffect(.degrees(-4))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
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

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.heavy(10))
            .foregroundStyle(Theme.ink.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color, in: Capsule())
    }
}

enum RowIcon { case ok, warn, error, pending, busy, skipped }

struct StatusRow: View {
    let icon: RowIcon
    let title: String
    var detail: String?
    var large = false
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            symbol.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(large ? Theme.bold(17) : Theme.semibold(13))
                    .foregroundStyle(icon == .pending ? Theme.dim : .white)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.medium(large ? 12 : 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress {
                    ProgressBar(value: progress).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var symbol: some View {
        switch icon {
        case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.green)
        case .warn: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.orange)
        case .error: Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.red)
        case .skipped: Image(systemName: "minus.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Color(white: 0.4))
        case .pending: Circle().strokeBorder(Color(white: 0.4), lineWidth: 1.5).frame(width: 17, height: 17)
        case .busy: ProgressView().controlSize(.small).tint(.white)
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(Theme.blue).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

struct Divided: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

struct WelcomeStatus: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusRow(icon: .warn, title: "Setup required", detail: "One-time install, about 400 MB.", large: true)
            Divided()
            StatusRow(icon: .pending, title: "Wine 11", detail: "Windows compatibility layer")
            StatusRow(icon: .pending, title: "Apple GPTK 4.0-2", detail: "DirectX 12 on Metal")
            StatusRow(icon: .pending, title: "ReSkate", detail: "Latest release from GitHub")
            StatusRow(icon: .pending, title: "Steam", detail: "Needed for multiplayer, sign in with a QR code")
            Text("Already have ReSkate? Pick its folder under GAME FOLDER and nothing gets downloaded twice.")
                .font(Theme.medium(11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SetupStatus: View {
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(StepID.allCases) { step in
                let status = launcher.status[step] ?? StepStatus()
                StatusRow(icon: icon(status.state), title: step.title, detail: status.detail, progress: status.progress)
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

    private func icon(_ state: StepState) -> RowIcon {
        switch state {
        case .pending: .pending
        case .running: .busy
        case .done: .ok
        case .skipped: .skipped
        case .failed: .error
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
                BigBlock(title: "INSTALL", subtitle: "About 400 MB") { launcher.startSetup() }
            case .setup:
                if launcher.waitingForLogin {
                    ActionPanel(title: "SKIP STEAM", subtitle: "Play without multiplayer", symbol: "forward") {
                        launcher.skipSteamLogin()
                    }
                }
                if launcher.setupError != nil {
                    ActionPanel(title: "LOGS", subtitle: "See what went wrong", symbol: "doc.text") { launcher.openLogs() }
                    BigBlock(title: "RETRY", subtitle: "Resume setup") { launcher.startSetup() }
                } else {
                    BigBlock(title: "INSTALLING", subtitle: currentStep, enabled: false) {}
                }
            case .ready:
                ActionPanel(title: "STEAM", subtitle: steamSubtitle, symbol: "person.2") { launcher.showSteam() }
                ToolsPanel()
                BigBlock(title: playTitle, subtitle: "ReSkate \(launcher.reskateVersion ?? "")",
                         enabled: launcher.gameState == .idle) { launcher.play() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var currentStep: String {
        StepID.allCases.first { launcher.status[$0]?.state == .running }?.title ?? "Finishing…"
    }

    private var steamSubtitle: String {
        if launcher.steamLoggedIn { return "Signed in" }
        if launcher.steamRunning { return "Signing in…" }
        return launcher.hasAutoLogin ? "Starts with the game" : "Not signed in"
    }

    private var playTitle: String {
        switch launcher.gameState {
        case .idle: "PLAY"
        case .starting: "STARTING"
        case .running: "RUNNING"
        }
    }
}

struct PanelLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.heavy(20)).foregroundStyle(.white)
                Text(subtitle)
                    .font(Theme.medium(11))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 46, height: 46)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.2))
        }
        .padding(.horizontal, 20)
        .frame(height: 78)
        .background(hovering ? Theme.panelHover : Theme.panel)
        .contentShape(Rectangle())
    }
}

struct ActionPanel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PanelLabel(title: title, subtitle: subtitle, symbol: symbol, hovering: hovering)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
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

struct BigBlock: View {
    let title: String
    let subtitle: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.heavy(title.count > 6 ? 30 : 40))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(subtitle)
                    .font(Theme.bold(12))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 124)
            .background(Theme.blue.opacity(enabled ? (hovering ? 1 : 0.94) : 0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
