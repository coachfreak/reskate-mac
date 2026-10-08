import AppKit
import CryptoKit
import SwiftUI

// MARK: - Remote sources

enum Remote {
    // GameHub CDN builds (same files GameHub installs); checksums from GameHub's own metadata
    static let wine = URL(string: "https://gamehub-cdn.youwo.com/uploads/emulator/20260928/a4d87d22d80f462c8bb1a60bf0ca6ec6.zst")!
    static let wineSHA = "d85b764deaadc7094c265d33446ecd5e617af0b6f5cc88424cd0ab9bbc6b7b96"
    static let gptk = URL(string: "https://gamehub-cdn.youwo.com/uploads/emulator/20260805/cf228daa416d4c8c8c1a66c5cae11a0b.tzst")!
    static let gptkSHA = "ef025bdcfe040f056345439d593d2f42ae72869ab92c8745726d4633a13997be"
    static let steamSetup = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    static let reskateRelease = URL(string: "https://api.github.com/repos/Dingo-Shenanigans/ReSkate/releases/latest")!
}

// MARK: - Model

enum Phase { case welcome, setup, ready }

enum StepID: Int, CaseIterable, Identifiable {
    case rosetta, wine, gptk, reskate, prefix, steam, login
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .rosetta: "Rosetta 2"
        case .wine: "Wine 11"
        case .gptk: "Apple GPTK 4.0-2"
        case .reskate: "ReSkate"
        case .prefix: "Windows environment"
        case .steam: "Steam"
        case .login: "Steam sign-in"
        }
    }
}

enum StepState: Equatable { case pending, running, done, skipped, failed }

struct StepStatus {
    var state = StepState.pending
    var detail = ""
    var progress: Double?
}

enum GameState: Equatable { case idle, starting(String), running }

struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

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
            loadBackground()
        }
    }

    private var loginSkipped = false
    private var skipSteamWait = false
    private let fm = FileManager.default

    static let gameArgs = [
        "-WorldRender.FrameSynthesisMode", "FrameSynthesisMode_None",
        "-Render.ResolutionScale", "1",
        "-Render.ResolutionScaleMin", "1",
        "-Render.DynamicResolutionScaleEnable", "0",
    ]

    // MARK: Paths

    // RESKATE_HOME: test a fresh install without touching the real one
    let home = ProcessInfo.processInfo.environment["RESKATE_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    var support: URL { home.appending(path: "Library/Application Support/ReSkate") }
    var runtime: URL { support.appending(path: "runtime") }
    var downloads: URL { support.appending(path: "downloads") }
    var logFile: URL { support.appending(path: "logs/launcher.log") }
    var wineRoot: URL { runtime.appending(path: "wine") }
    var wineBin: URL { wineRoot.appending(path: "bin/wine") }
    var gptkDir: URL { runtime.appending(path: "gptk-4.0-2") }
    var gptkLib: URL { gptkDir.appending(path: "external/libd3dshared.dylib") }
    var prefix: URL { support.appending(path: "prefix") }
    var steamExe: URL { prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe") }
    var gameHubEngine: URL { home.appending(path: "Library/Application Support/com.gamemac.www/wine-engine") }
    var launcherExe: URL { gameDir.appending(path: "ReSkateLauncher.exe") }

    var wineEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1" // every process sharing the wineserver must agree on this
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["MTL_DEBUG_LAYER"] = "0"
        env["RESKATE_CRASH_REPORTING"] = "0"
        env["WINE_GPTK_LIBD3DSHARED_PATH"] = gptkLib.path
        env["WINEDLLPATH"] = gptkDir.appending(path: "wine").path
        return env
    }

    var isInstalled: Bool {
        fm.isExecutableFile(atPath: wineBin.path) && fm.fileExists(atPath: gptkLib.path)
            && fm.fileExists(atPath: prefix.appending(path: "system.reg").path)
            && fm.fileExists(atPath: launcherExe.path) && fm.fileExists(atPath: steamExe.path)
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "gameDir")
        gameDir = saved.map { URL(fileURLWithPath: $0) } ?? home.appending(path: "Games/ReSkate")
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
        phase = isInstalled ? .ready : .welcome
        loadBackground()
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

    /// The ReSkate launcher embeds its 2560x1440 background art; reuse it instead of shipping a copy
    func loadBackground() {
        let exe = launcherExe
        let cache = support.appending(path: "background.jpg")
        Task {
            let image = await Task.detached { () -> NSImage? in
                let fm = FileManager.default
                let exeDate = (try? fm.attributesOfItem(atPath: exe.path)[.modificationDate]) as? Date
                let cacheDate = (try? fm.attributesOfItem(atPath: cache.path)[.modificationDate]) as? Date
                if let cacheDate, exeDate.map({ $0 <= cacheDate }) ?? true { return NSImage(contentsOf: cache) }
                guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe),
                      let jpeg = largestJPEG(in: data) else { return cacheDate != nil ? NSImage(contentsOf: cache) : nil }
                try? jpeg.write(to: cache)
                return NSImage(data: jpeg)
            }.value
            if let image { background = image }
        }
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
        try Shell.spawn(wineBin.path, args, env: wineEnv, log: logFile)
    }

    // MARK: Setup

    func startSetup() {
        phase = .setup
        setupError = nil
        loginSkipped = false
        status = Dictionary(uniqueKeysWithValues: StepID.allCases.map { ($0, StepStatus()) })
        Task { await runSetup() }
    }

    func skipSteamLogin() { loginSkipped = true }

    private func runSetup() async {
        for step in StepID.allCases {
            status[step] = StepStatus(state: .running)
            do {
                let detail = try await perform(step)
                let skipped = step == .login && loginSkipped
                status[step] = StepStatus(state: skipped ? .skipped : .done, detail: detail)
            } catch {
                status[step]?.state = .failed
                status[step]?.progress = nil
                setupError = error.localizedDescription
                log("Setup failed at \(step.title): \(error.localizedDescription)")
                return
            }
        }
        loadBackground()
        try? await Task.sleep(for: .seconds(1))
        phase = .ready
        refreshSteam()
    }

    private func perform(_ step: StepID) async throws -> String {
        switch step {
        case .rosetta: try await ensureRosetta()
        case .wine: try await installWine()
        case .gptk: try await installGPTK()
        case .reskate: try await installReSkate()
        case .prefix: try await setupPrefix()
        case .steam: try await installSteam()
        case .login: try await steamLogin()
        }
    }

    private func setDetail(_ step: StepID, _ text: String) { status[step]?.detail = text }

    private var rosettaInstalled: Bool { fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }

    private func ensureRosetta() async throws -> String {
        if rosettaInstalled { return "Already installed" }
        setDetail(.rosetta, "Installing, macOS will ask for your password…")
        let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
        try await Shell.run("/usr/bin/osascript", ["-e", script], log: logFile)
        guard rosettaInstalled else { throw SetupError("Rosetta 2 could not be installed.") }
        return "Installed"
    }

    private func localGameHubWine() async -> URL? {
        let dir = gameHubEngine.appending(path: "containers/wine_installations")
        for install in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let bin = install.appending(path: "bin/wine").path
            guard fm.isExecutableFile(atPath: bin) else { continue }
            let version = await Task.detached { Shell.output(bin, ["--version"]) }.value
            if version.hasPrefix("wine-11") { return install }
        }
        return nil
    }

    private func installWine() async throws -> String {
        if fm.isExecutableFile(atPath: wineBin.path) { return "Already installed" }
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        let tmp = runtime.appending(path: ".wine-tmp")
        try? fm.removeItem(at: tmp)
        var source = "downloaded from GameHub CDN"
        if let local = await localGameHubWine() {
            setDetail(.wine, "Copying Wine from your GameHub install…")
            try await Shell.check("/bin/cp", ["-Rc", local.path, tmp.path], log: logFile)
            source = "copied from GameHub"
        } else {
            let archive = downloads.appending(path: "wine.tar.zst")
            try await download(Remote.wine, to: archive, step: .wine, label: "Downloading Wine")
            try await verify(archive, sha: Remote.wineSHA, step: .wine)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            setDetail(.wine, "Extracting…")
            try await extract(archive, into: tmp)
            try? fm.removeItem(at: archive)
        }
        guard let root = findDir(in: tmp, containing: "bin/wine") else { throw SetupError("Unexpected Wine archive layout.") }
        try fm.moveItem(at: root, to: wineRoot)
        try? fm.removeItem(at: tmp)
        return "Wine 11 \(source)"
    }

    private func installGPTK() async throws -> String {
        if fm.fileExists(atPath: gptkLib.path) { return "Already installed" }
        try? fm.removeItem(at: gptkDir)
        let local = gameHubEngine.appending(path: "downloads/gptk-4.0-2")
        if fm.fileExists(atPath: local.appending(path: "external/libd3dshared.dylib").path) {
            try await Shell.check("/bin/cp", ["-Rc", local.path, gptkDir.path], log: logFile)
            return "Copied from GameHub"
        }
        let archive = downloads.appending(path: "gptk.tar.zst")
        try await download(Remote.gptk, to: archive, step: .gptk, label: "Downloading GPTK")
        try await verify(archive, sha: Remote.gptkSHA, step: .gptk)
        setDetail(.gptk, "Extracting…")
        try await extract(archive, into: runtime) // archive root is gptk-4.0-2/
        try? fm.removeItem(at: archive)
        guard fm.fileExists(atPath: gptkLib.path) else { throw SetupError("Unexpected GPTK archive layout.") }
        return "Downloaded from GameHub CDN"
    }

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
        let zip = downloads.appending(path: asset.name)
        try await download(asset.browser_download_url, to: zip, step: .reskate, label: "Downloading \(release.tag_name)")
        let tmp = downloads.appending(path: "reskate-tmp")
        try? fm.removeItem(at: tmp)
        // zip uses Windows backslash paths; unzip converts them (and exits 1 for that warning)
        let code = try await Shell.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", tmp.path], log: logFile)
        guard code <= 1 else { throw SetupError("Could not extract ReSkate (code \(code)).") }
        guard let exe = findFile(named: "ReSkateLauncher.exe", in: tmp) else { throw SetupError("ReSkateLauncher.exe missing from download.") }
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: exe.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            let dest = gameDir.appending(path: item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.moveItem(at: item, to: dest) }
        }
        try? fm.removeItem(at: tmp)
        try? fm.removeItem(at: zip)
        return "\(release.tag_name) in \(gameDir.path.tilde)"
    }

    private func setupPrefix() async throws -> String {
        var done: [String] = []
        if !fm.fileExists(atPath: prefix.appending(path: "system.reg").path) {
            setDetail(.prefix, "Creating, this takes a moment…")
            try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            try await wine(["wineboot", "-u"])
            let regs = [
                [#"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", "N"],
                [#"HKCU\Control Panel\Desktop"#, "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96"],
                [#"HKCU\Software\Wine\Fonts"#, "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96"],
                // PS4 pad: hide raw Bluetooth HID (game can't read it under macOS), keep SDL/XInput device
                [#"HKLM\System\CurrentControlSet\Services\winebus"#, "/v", "DisableHidraw", "/t", "REG_DWORD", "/d", "1"],
            ]
            for args in regs { try await wine(["reg", "add"] + args + ["/f"]) }
            done.append("created")
        }
        // GameHub's Wine leaves C:\windows\Fonts empty; Steam's browser recurses to death without Tahoma
        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        if !fm.fileExists(atPath: fonts.appending(path: "tahoma.ttf").path) {
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            let src = wineRoot.appending(path: "share/wine/fonts")
            for font in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                let dest = fonts.appending(path: font.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: font, to: dest) }
            }
            done.append("fonts added")
        }
        return done.isEmpty ? "Already set up" : done.joined(separator: ", ").capitalizedFirst
    }

    private func installSteam() async throws -> String {
        if steamInstalled { return "Already installed" }
        let setup = prefix.appending(path: "drive_c/SteamSetup.exe")
        try await download(Remote.steamSetup, to: setup, step: .steam, label: "Downloading Steam")
        setDetail(.steam, "Installing…")
        try await wine([setup.path, "/S"])
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
                try Shell.spawn(wineBin.path, ["ReSkateLauncher.exe"] + Self.gameArgs, env: wineEnv, cwd: gameDir, log: logFile)
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

    private func gameRunning() -> Bool {
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

    // MARK: Helpers

    @discardableResult
    private func wine(_ args: [String]) async throws -> Int32 {
        try await Shell.run(wineBin.path, args, env: wineEnv, log: logFile)
    }

    private func download(_ url: URL, to dest: URL, step: StepID, label: String) async throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        setDetail(step, "\(label)…")
        let downloader = Downloader(dest: dest) { done, total in
            Task { @MainActor in
                self.status[step]?.progress = total > 0 ? Double(done) / Double(total) : nil
                self.status[step]?.detail = total > 0
                    ? "\(label) · \(done.bytes) of \(total.bytes)"
                    : "\(label) · \(done.bytes)"
            }
        }
        try await downloader.start(url)
        status[step]?.progress = nil
    }

    private func verify(_ file: URL, sha: String, step: StepID) async throws {
        setDetail(step, "Verifying download…")
        let actual = try await Task.detached { try sha256(of: file) }.value
        guard actual == sha else {
            try? fm.removeItem(at: file)
            throw SetupError("Checksum mismatch. The download is corrupted or was changed.")
        }
    }

    private func extract(_ archive: URL, into dir: URL) async throws {
        guard let zstd = Bundle.main.url(forResource: "zstd", withExtension: nil) else { throw SetupError("zstd is missing from the app bundle.") }
        let script = #"set -o pipefail; "$0" -dc "$1" | /usr/bin/tar -xf - -C "$2""#
        try await Shell.check("/bin/bash", ["-c", script, zstd.path, archive.path, dir.path], log: logFile)
    }

    private func findDir(in root: URL, containing relative: String) -> URL? {
        if fm.fileExists(atPath: root.appending(path: relative).path) { return root }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appending(path: relative).path) }
    }

    private func findFile(named name: String, in root: URL) -> URL? {
        let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    private func log(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("[\(Date())] \(line)\n".utf8))
        try? handle.close()
    }
}

// MARK: - Process / download helpers

enum Shell {
    static func make(_ exe: String, _ args: [String], env: [String: String]?, cwd: URL?, log: URL?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let env { process.environment = env }
        if let cwd { process.currentDirectoryURL = cwd }
        if let log, let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        return process
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil, log: URL? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let process = make(exe, args, env: env, cwd: cwd, log: log)
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    static func check(_ exe: String, _ args: [String], log: URL?) async throws {
        let code = try await run(exe, args, log: log)
        guard code == 0 else { throw SetupError("\((exe as NSString).lastPathComponent) failed (code \(code)). See the log for details.") }
    }

    static func spawn(_ exe: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil, log: URL? = nil) throws {
        try make(exe, args, env: env, cwd: cwd, log: log).run()
    }

    static func output(_ exe: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func succeeds(_ exe: String, _ args: [String]) -> Bool {
        let process = make(exe, args, env: nil, cwd: nil, log: nil)
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let dest: URL
    private let onProgress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var finishError: Error?
    private var lastReported: Int64 = 0

    init(dest: URL, onProgress: @escaping (Int64, Int64) -> Void) {
        self.dest = dest
        self.onProgress = onProgress
    }

    func start(_ url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten done: Int64, totalBytesExpectedToWrite total: Int64) {
        guard done - lastReported >= 1 << 20 || done == total else { return }
        lastReported = done
        onProgress(done, total)
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finishError = SetupError("Server returned HTTP \(response.statusCode) (\(downloadTask.originalRequest?.url?.host ?? "")).")
            return
        }
        do { try FileManager.default.moveItem(at: location, to: dest) } catch { finishError = error }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? finishError { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}

/// Finds the biggest complete JPEG inside a binary by walking marker segments
/// (skipping by length, so EXIF thumbnails don't end the image early).
func largestJPEG(in data: Data) -> Data? {
    let bytes = [UInt8](data)
    func end(from start: Int) -> Int? {
        var i = start + 2
        func length(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        while i + 4 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = bytes[i + 1]
            switch marker {
            case 0xD9: return i + 2
            case 0xDA: // entropy-coded scan: 0xFF is stuffed (FF00) or a restart marker
                var j = i + 2 + length(i + 2)
                while j + 1 < bytes.count {
                    guard bytes[j] == 0xFF else { j += 1; continue }
                    let next = bytes[j + 1]
                    if next == 0xD9 { return j + 2 }
                    if next == 0x00 || (0xD0...0xD7).contains(next) { j += 2; continue }
                    break
                }
                i = j
            case 0x01, 0xD0...0xD7: i += 2
            default: i += 2 + length(i + 2)
            }
        }
        return nil
    }
    var best: Range<Int>?
    var i = 0
    while i + 3 < bytes.count {
        if bytes[i] == 0xFF, bytes[i + 1] == 0xD8, bytes[i + 2] == 0xFF, let e = end(from: i) {
            if e - i > (best?.count ?? 0) { best = i..<e }
            i = e
        } else {
            i += 1
        }
    }
    return best.map { Data(bytes[$0]) }
}

func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

extension Int64 {
    // fixed English formatting regardless of system locale
    var bytes: String { String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), Double(self) / 1_000_000) }
}

extension String {
    var tilde: String { (self as NSString).abbreviatingWithTildeInPath }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

@main
struct ReSkateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var launcher = Launcher()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(launcher)
                .frame(width: 500, height: 840)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
