import AppKit
import SwiftUI

// MARK: - Remote sources

extension Remote {
    static let steamSetup = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    static let reskateRelease = URL(string: "https://api.github.com/repos/Dingo-Shenanigans/ReSkate/releases/latest")!
}

// MARK: - Model

enum Phase { case welcome, setup, ready }

enum StepID: Int, CaseIterable, Identifiable {
    case rosetta, wine, gptk, reskate, prefix, steam, login, studio, dotnet, reshade
    var id: Int { rawValue }
    static let game: [StepID] = [.rosetta, .wine, .gptk, .reskate, .prefix, .steam, .login]

    var title: String {
        switch self {
        case .rosetta: "Rosetta 2"
        case .wine: "Wine 11"
        case .gptk: "Apple GPTK 4.0-2"
        case .reskate: "ReSkate"
        case .prefix: "Windows environment"
        case .steam: "Steam"
        case .login: "Steam sign-in"
        case .studio: "ReSkate Studio"
        case .dotnet: ".NET runtime"
        case .reshade: "ReShade"
        }
    }
}

enum GameState: Equatable { case idle, starting(String), running }

@MainActor
final class Launcher: ObservableObject {
    @Published var phase = Phase.welcome
    @Published var status: [StepID: StepStatus] = [:]
    @Published var setupError: String?
    @Published var waitingForLogin = false
    @Published var gameState = GameState.idle
    @Published var lastError: String?
    @Published var steamRunning = false
    @Published var steamLoggedIn = false
    @Published var waitingForSteam = false
    @Published var background: NSImage?
    @Published var gameDir: URL {
        didSet {
            UserDefaults.standard.set(gameDir.path, forKey: "gameDir")
            refreshBackground()
            mapGameDrive()
        }
    }
    @Published var setupSteps = StepID.game

    // ReSkate Studio (Studio.swift)
    @Published var withStudio: Bool { didSet { UserDefaults.standard.set(withStudio, forKey: "withStudio") } }
    // ReShade (ReShade.swift); the key is a Windows virtual-key code
    @Published var reshade: Bool { didSet { UserDefaults.standard.set(reshade, forKey: "reshade") } }
    @Published var reshadeKey: Int { didSet { UserDefaults.standard.set(reshadeKey, forKey: "reshadeKey") } }
    /// ReSkate_Studio.zip, an extracted folder, or an installer .exe the user picked
    @Published var studioSource: URL? { didSet { UserDefaults.standard.set(studioSource?.path, forKey: "studioSource") } }
    @Published var studioExe: URL? { didSet { UserDefaults.standard.set(studioExe?.path, forKey: "studioExe") } }
    @Published var studioState = StudioState.idle
    @Published var waitingForInstaller = false
    var replaceStudio = false

    private var loginSkipped = false
    private var skipSteamWait = false
    let fm = FileManager.default
    let rt = Runtime(log: "launcher.log")

    static let gameArgs = [
        "-WorldRender.FrameSynthesisMode", "FrameSynthesisMode_None",
        "-Render.ResolutionScale", "1",
        "-Render.ResolutionScaleMin", "1",
        "-Render.DynamicResolutionScaleEnable", "0",
    ]

    // MARK: Paths

    var home: URL { rt.home }
    var support: URL { rt.support }
    var logFile: URL { rt.logFile }
    var prefix: URL { support.appending(path: "prefix") }
    var steamExe: URL { prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe") }
    var launcherExe: URL { gameDir.appending(path: "ReSkateLauncher.exe") }
    var wineEnv: [String: String] { rt.wineEnv(prefix: prefix) }

    var isInstalled: Bool {
        rt.isInstalled && fm.fileExists(atPath: prefix.appending(path: "system.reg").path)
            && fm.fileExists(atPath: launcherExe.path) && fm.fileExists(atPath: steamExe.path)
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "gameDir")
        gameDir = saved.map { URL(fileURLWithPath: $0) } ?? rt.home.appending(path: "Games/ReSkate")
        withStudio = UserDefaults.standard.bool(forKey: "withStudio")
        reshade = UserDefaults.standard.bool(forKey: "reshade")
        reshadeKey = UserDefaults.standard.object(forKey: "reshadeKey") as? Int ?? 0x24 // Home, ReShade's default
        studioSource = UserDefaults.standard.string(forKey: "studioSource").map { URL(fileURLWithPath: $0) }
        studioExe = UserDefaults.standard.string(forKey: "studioExe").map { URL(fileURLWithPath: $0) }
        phase = isInstalled ? .ready : .welcome
        refreshBackground()
        if CommandLine.arguments.contains("--setup") { Task { startSetup() } }
        Task {
            while true {
                refreshSteam()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Info shown in the UI

    /// ReSkate version from the launcher's PE FileVersion (launcher.json lags behind self-updates)
    var reskateVersion: String? {
        guard let data = try? Data(contentsOf: launcherExe, options: .mappedIfSafe),
              let key = data.range(of: "FileVersion".data(using: .utf16LittleEndian)!) else { return nil }
        let tail = [UInt8](data[key.upperBound..<min(key.upperBound + 64, data.endIndex)])
        let units = stride(from: 0, to: tail.count - 1, by: 2).map { UInt16(tail[$0]) | UInt16(tail[$0 + 1]) << 8 }
        let text = String(decoding: units, as: UTF16.self)
        return text.split(whereSeparator: { $0 == "\0" || $0 == " " }).first.map(String.init)
    }

    var gameBuild: String? {
        guard let data = try? Data(contentsOf: gameDir.appending(path: "launcher.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let game = json["game"] as? [String: Any] else { return nil }
        return game["build_id"] as? String
    }

    var displayName: String {
        let users = prefix.appending(path: "drive_c/Program Files (x86)/Steam/config/loginusers.vdf")
        if let text = try? String(contentsOf: users, encoding: .utf8),
           let regex = try? Regex(#""PersonaName"\s+"([^"]+)""#),
           let match = text.firstMatch(of: regex), let name = match.output[1].substring {
            return String(name)
        }
        return NSUserName()
    }

    func refreshBackground() {
        let exe = launcherExe, cache = support.appending(path: "background.jpg")
        Task { if let image = await loadBackground(from: exe, cache: cache) { background = image } }
    }

    // MARK: Steam state (read from the prefix registry)

    private func userReg() -> String {
        (try? String(contentsOf: prefix.appending(path: "user.reg"), encoding: .utf8)) ?? ""
    }

    var isLoggedIn: Bool { userReg().range(of: #""ActiveUser"=dword:0*[1-9a-f]"#, options: .regularExpression) != nil }
    var hasAutoLogin: Bool { userReg().range(of: #""AutoLoginUser"="[^"]"#, options: .regularExpression) != nil }
    var steamInstalled: Bool { fm.fileExists(atPath: steamExe.path) }

    func refreshSteam() {
        steamRunning = Shell.succeeds("/usr/bin/pgrep", ["-f", #"Steam\\steam\.exe"#])
        steamLoggedIn = steamRunning && isLoggedIn
    }

    func startSteam(visible: Bool) throws {
        var args = [#"C:\Program Files (x86)\Steam\steam.exe"#]
        if !visible { args.append("-silent") }
        try rt.spawnWine(args, prefix: prefix)
    }

    // MARK: Setup

    /// Runs the given steps; by default the whole game setup, plus Studio if it was picked
    func startSetup(_ steps: [StepID]? = nil) {
        setupSteps = steps ?? StepID.game + (withStudio ? [.studio, .dotnet] : []) + (reshade ? [.reshade] : [])
        phase = .setup
        setupError = nil
        loginSkipped = false
        status = Dictionary(uniqueKeysWithValues: setupSteps.map { ($0, StepStatus()) })
        Task { await runSetup() }
    }

    func skipSteamLogin() { loginSkipped = true }

    private func runSetup() async {
        for step in setupSteps {
            status[step] = StepStatus(state: .running)
            do {
                let detail = try await perform(step)
                let skipped = step == .login && loginSkipped
                status[step] = StepStatus(state: skipped ? .skipped : .done, detail: detail)
            } catch {
                status[step]?.state = .failed
                status[step]?.progress = nil
                setupError = error.localizedDescription
                rt.log("Setup failed at \(step.title): \(error.localizedDescription)")
                return
            }
        }
        replaceStudio = false
        refreshBackground()
        try? await Task.sleep(for: .seconds(1))
        phase = .ready
        refreshSteam()
    }

    private func perform(_ step: StepID) async throws -> String {
        let report = reporter(step)
        switch step {
        case .rosetta: return try await rt.ensureRosetta(report)
        case .wine: return try await rt.installWine(report)
        case .gptk: return try await rt.installGPTK(report)
        case .reskate: return try await installReSkate()
        case .prefix:
            let detail = try await rt.setupPrefix(prefix, report)
            mapGameDrive()
            return detail
        case .steam: return try await installSteam()
        case .login: return try await steamLogin()
        case .studio: return try await installStudio(report)
        case .dotnet: return try await installDotNet(report)
        case .reshade: return try await installReShade(report)
        }
    }

    private func reporter(_ step: StepID) -> Report {
        { [weak self] detail, progress in
            self?.status[step]?.detail = detail
            self?.status[step]?.progress = progress
        }
    }

    private func setDetail(_ step: StepID, _ text: String) { status[step]?.detail = text }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }

    private func installReSkate() async throws -> String {
        if fm.fileExists(atPath: launcherExe.path) { return "Found in \(gameDir.path.tilde)" }
        setDetail(.reskate, "Looking up latest release on GitHub…")
        let (data, _) = try await URLSession.shared.data(from: Remote.reskateRelease)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("ReSkate-") && $0.name.hasSuffix(".zip") }) else {
            throw SetupError("No ReSkate download found in \(release.tag_name).")
        }
        let zip = rt.downloads.appending(path: asset.name)
        try await rt.download(asset.browser_download_url, to: zip, label: "Downloading \(release.tag_name)", reporter(.reskate))
        status[.reskate]?.progress = nil
        let tmp = rt.downloads.appending(path: "reskate-tmp")
        try? fm.removeItem(at: tmp)
        try await rt.unzip(zip, into: tmp)
        guard let exe = rt.findFiles(in: tmp, where: { $0.lastPathComponent == "ReSkateLauncher.exe" }).first else {
            throw SetupError("ReSkateLauncher.exe missing from download.")
        }
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: exe.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            let dest = gameDir.appending(path: item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.moveItem(at: item, to: dest) }
        }
        try? fm.removeItem(at: tmp)
        try? fm.removeItem(at: zip)
        return "\(release.tag_name) in \(gameDir.path.tilde)"
    }

    private func installSteam() async throws -> String {
        if steamInstalled { return "Already installed" }
        let setup = prefix.appending(path: "drive_c/SteamSetup.exe")
        try await rt.download(Remote.steamSetup, to: setup, label: "Downloading Steam", reporter(.steam))
        status[.steam]?.progress = nil
        setDetail(.steam, "Installing…")
        try await rt.wine([setup.path, "/S"], prefix: prefix)
        try? fm.removeItem(at: setup)
        guard steamInstalled else { throw SetupError("Steam installation failed.") }
        return "Installed"
    }

    private func steamLogin() async throws -> String {
        if hasAutoLogin { return "Remembered sign-in" }
        waitingForLogin = true
        defer { waitingForLogin = false }
        setDetail(.login, "Steam opens in a moment. Sign in (QR code works) and keep \"Remember me\" on.")
        refreshSteam()
        if !steamRunning { try startSteam(visible: true) }
        while !isLoggedIn {
            if loginSkipped { return "Skipped, multiplayer stays off" }
            try await Task.sleep(for: .seconds(2))
        }
        return "Signed in"
    }

    // MARK: Play

    func play() {
        guard gameState == .idle else { return }
        lastError = nil
        skipSteamWait = false
        Task {
            do {
                if steamInstalled && !isLoggedIn {
                    refreshSteam()
                    if !steamRunning {
                        gameState = .starting("Starting Steam…")
                        try startSteam(visible: !hasAutoLogin)
                    }
                    gameState = .starting("Waiting for Steam sign-in…")
                    waitingForSteam = true
                    defer { waitingForSteam = false }
                    var waited = 0
                    while !isLoggedIn && !skipSteamWait && waited < 120 {
                        try await Task.sleep(for: .seconds(2))
                        waited += 2
                    }
                }
                gameState = .starting("Starting ReSkate…")
                try await applyReShade()
                try Shell.spawn(rt.wineBin.path, ["ReSkateLauncher.exe"] + Self.gameArgs, env: wineEnv, cwd: gameDir, log: logFile)
                gameState = .running
                try await Task.sleep(for: .seconds(10))
                while gameRunning() { try await Task.sleep(for: .seconds(3)) }
            } catch {
                lastError = error.localizedDescription
            }
            gameState = .idle
            refreshSteam()
        }
    }

    func startOffline() { skipSteamWait = true }

    func gameRunning() -> Bool {
        // ignore the launcher's crash helper, it can outlive the game
        Shell.output("/usr/bin/pgrep", ["-fl", #"ReSkateLauncher\.exe|Skate\.exe"#])
            .split(separator: "\n").contains { !$0.contains("crash-helper") }
    }

    // MARK: Actions

    func chooseGameDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Pick a folder for ReSkate, or your existing folder containing ReSkateLauncher.exe"
        panel.directoryURL = gameDir.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { gameDir = url }
    }

    func openGameDir() { NSWorkspace.shared.open(gameDir) }

    func openLogs() {
        let gameLogs = gameDir.appending(path: "logs")
        NSWorkspace.shared.open(fm.fileExists(atPath: gameLogs.path) ? gameLogs : logFile.deletingLastPathComponent())
    }

    func showSteam() {
        do { try startSteam(visible: true) } catch { lastError = error.localizedDescription }
    }
}

// MARK: - App

@main
struct ReSkateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var launcher = Launcher()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(launcher)
                .frame(width: 500, height: 928)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
