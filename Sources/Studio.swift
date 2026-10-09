import AppKit
import UniformTypeIdentifiers

// ReSkate Studio (the Frosty-based mod/map tool), installed into the game's own prefix so it sees ReSkate
// and its Launch button runs the game next to Steam.

extension Remote {
    // Same installers and checksums winetricks uses for dotnet40 / dotnet48
    static let dotnet40 = URL(string: "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe")!
    static let dotnet40SHA = "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
    static let dotnet48 = URL(string: "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe")!
    static let dotnet48SHA = "95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"
    static func dotnetReleases(_ channel: String) -> URL {
        URL(string: "https://builds.dotnet.microsoft.com/dotnet/release-metadata/\(channel)/releases.json")!
    }
}

/// What the Studio exe needs to run
enum DotNet: Equatable {
    case none
    case framework // .NET Framework 4.x (classic Frosty)
    case desktop(String) // .NET (Core) Windows Desktop runtime channel, e.g. "8.0"

    var title: String {
        switch self {
        case .none: "No .NET needed"
        case .framework: ".NET Framework 4.8"
        case .desktop(let channel): ".NET Desktop Runtime \(channel)"
        }
    }
}

enum StudioState: Equatable { case idle, starting, running }

extension Launcher {
    var studioDir: URL { prefix.appending(path: "drive_c/ReSkate Studio") }
    var dotnetMarker: URL { prefix.appending(path: "drive_c/windows/reskate-dotnet.txt") }
    var dotnetInstalled: String? { try? String(contentsOf: dotnetMarker, encoding: .utf8) }

    var studioInstalled: Bool {
        studioExe.map { fm.fileExists(atPath: $0.path) } == true && fm.fileExists(atPath: dotnetMarker.path)
    }

    var studioName: String { studioExe?.deletingPathExtension().lastPathComponent ?? "ReSkate Studio" }

    /// R:\ in Wine points at the ReSkate folder, so Studio's game picker finds it fast
    func mapGameDrive() {
        let devices = prefix.appending(path: "dosdevices")
        guard fm.fileExists(atPath: devices.path) else { return }
        let link = devices.appending(path: "r:")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == gameDir.path { return }
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: gameDir)
        // Wine only reads drive letters when its session starts; one already running (Steam in the
        // background) won't list R: in file pickers. openStudio restarts the session once.
        UserDefaults.standard.set(true, forKey: "driveChanged")
    }

    // MARK: Studio files

    func installStudio(_ report: Report) async throws -> String {
        if !replaceStudio, let studioExe, fm.fileExists(atPath: studioExe.path) { return "Already installed" }
        guard let source = studioSource, fm.fileExists(atPath: source.path) else {
            throw SetupError("Pick ReSkate_Studio.zip first.")
        }
        mapGameDrive()
        try fm.createDirectory(at: studioDir, withIntermediateDirectories: true)
        // copied over the old files, never wiped: Studio keeps its settings and projects next to the exe
        report("Copying \(source.lastPathComponent)…", nil)
        if source.hasDirectoryPath {
            try await Shell.check("/bin/cp", ["-Rc", source.path + "/.", studioDir.path], log: logFile)
        } else if source.pathExtension.lowercased() == "zip" {
            try await rt.unzip(source, into: studioDir)
        } else {
            try await Shell.check("/bin/cp", ["-c", source.path, studioDir.path], log: logFile)
        }

        guard let exe = Self.pickExe(rt.findFiles(in: studioDir) { $0.pathExtension.lowercased() == "exe" }) else {
            throw SetupError("No program found in \(source.lastPathComponent).")
        }
        if Self.isInstaller(exe) {
            report("Finish the installer. If it asks for ReSkate, pick drive R:", nil)
            waitingForInstaller = true
            defer { waitingForInstaller = false }
            try await rt.wine([exe.path], prefix: prefix, cwd: exe.deletingLastPathComponent())
            let drive = prefix.appending(path: "drive_c")
            let installed = ["Program Files", "Program Files (x86)", "users", "ReSkate Studio"].flatMap { dir in
                rt.findFiles(in: drive.appending(path: dir)) { $0.pathExtension.lowercased() == "exe" && !Self.isInstaller($0) }
            }
            guard let found = Self.pickExe(installed, nameMustMatch: true) else {
                throw SetupError("The installer finished, but Studio wasn't found. Run it again with RETRY.")
            }
            studioExe = found
        } else {
            studioExe = exe
        }
        return "\(studioName) installed"
    }

    private static let skipName = try! Regex("(?i)unins|redist|crash|updater|helper|dotnet|ndp4|net ?framework|directx|dxsetup|prereq|steam")
    private static let skipDir = try! Regex("(?i)/(prereqs?|redist|thirdparty|third ?party|_commonredist|tools|steam)/")
    private static let preferred = try! Regex("(?i)studio|reskate|editor|frosty")

    /// Best guess at Studio's main exe: named like Studio, then shallowest, then biggest
    static func pickExe(_ exes: [URL], nameMustMatch: Bool = false) -> URL? {
        let candidates = exes.filter { url in
            url.lastPathComponent.firstMatch(of: skipName) == nil && url.path.firstMatch(of: skipDir) == nil
                && (!nameMustMatch || url.lastPathComponent.firstMatch(of: preferred) != nil)
        }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return candidates.min { a, b in
            let key = { (u: URL) in (u.lastPathComponent.firstMatch(of: preferred) == nil ? 1 : 0, u.pathComponents.count) }
            let (ka, kb) = (key(a), key(b))
            return ka != kb ? ka < kb : size(a) > size(b)
        }
    }

    /// Inno Setup / NSIS installers, by name or by their embedded signature
    static func isInstaller(_ exe: URL) -> Bool {
        if exe.lastPathComponent.range(of: "setup|install", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return false }
        let head = data.prefix(4 << 20)
        return ["Inno Setup Setup Data", "Nullsoft Install System"].contains { head.range(of: Data($0.utf8)) != nil }
    }

    // MARK: .NET

    /// .NET Core apps ship a runtimeconfig.json; classic .NET Framework exes have a CLR header in the PE
    static func dotnetNeed(of exe: URL) -> DotNet {
        let config = exe.deletingPathExtension().appendingPathExtension("runtimeconfig.json")
        if let data = try? Data(contentsOf: config),
           let options = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["runtimeOptions"] as? [String: Any] {
            if options["includedFrameworks"] != nil { return .none } // self-contained
            let frameworks = (options["frameworks"] as? [[String: Any]]) ?? [options["framework"] as? [String: Any]].compactMap { $0 }
            guard let version = frameworks.compactMap({ $0["version"] as? String }).first else { return .none }
            return .desktop(version.split(separator: ".").prefix(2).joined(separator: "."))
        }
        return hasCLRHeader(exe) ? .framework : .none
    }

    static func hasCLRHeader(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe), let head = try? handle.read(upToCount: 4096),
              head.count > 0x40 else { return false }
        let bytes = [UInt8](head)
        func u32(_ i: Int) -> Int { i + 4 <= bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 : 0 }
        let pe = u32(0x3C), optional = pe + 24
        guard optional + 2 <= bytes.count, bytes[pe] == 0x50, bytes[pe + 1] == 0x45 else { return false }
        let pe32Plus = bytes[optional] == 0x0B && bytes[optional + 1] == 0x02
        let comDirectory = optional + (pe32Plus ? 112 : 96) + 14 * 8 // data directory 14: CLR runtime header
        return u32(comDirectory) != 0
    }

    func installDotNet(_ report: @escaping Report) async throws -> String {
        guard let studioExe else { throw SetupError("Studio isn't installed.") }
        let need = Self.dotnetNeed(of: studioExe)
        if let done = dotnetInstalled, done == need.title, need != .framework || hasRealMscoree { return "\(done) already installed" }
        switch need {
        case .none: break
        case .framework: try await installFramework(report)
        case .desktop(let channel): try await installDesktopRuntime(channel, report)
        }
        // WPF's hardware path draws garbage or nothing under Wine; software rendering is reliable
        try await setReg([#"HKCU\Software\Microsoft\Avalon.Graphics"#, "/v", "DisableHWAcceleration", "/t", "REG_DWORD", "/d", "1"])
        try need.title.write(to: dotnetMarker, atomically: true, encoding: .utf8)
        return need == .none ? need.title : "\(need.title) installed"
    }

    /// Microsoft's mscoree.dll (not Wine's Mono loader), without it no .NET Framework exe starts
    private var hasRealMscoree: Bool {
        guard let data = try? Data(contentsOf: prefix.appending(path: "drive_c/windows/system32/mscoree.dll")) else { return false }
        return data.range(of: Data("WINE_MONO_OVERRIDES".utf8)) == nil
    }

    private func winver(_ version: String) async throws {
        try await rt.wine(["winecfg", "-v", version], prefix: prefix)
    }

    /// Microsoft installers exit with "success, reboot needed" codes under Wine
    private func msInstaller(_ exe: URL, _ args: [String]) async throws {
        let code = try await rt.wine([exe.path] + args, prefix: prefix, env: ["WINEDLLOVERRIDES": "fusion=b"])
        guard [0, 194, 1641, 3010].contains(code) else {
            throw SetupError("\(exe.lastPathComponent) failed (code \(code)). See the log for details.")
        }
    }

    private func setReg(_ args: [String]) async throws {
        try await rt.wine(["reg", "add"] + args + ["/f"], prefix: prefix)
    }

    /// winetricks remove_mono + dotnet40 + dotnet48: real .NET Framework instead of Wine Mono (WPF needs it)
    private func installFramework(_ report: @escaping Report) async throws {
        report("Removing Wine Mono…", nil)
        // uninstaller prints its list on stderr; `uninstaller --remove` leaves Mono in place here, msiexec doesn't
        let list = Shell.output(rt.wineBin.path, ["uninstaller", "--list"], env: wineEnv, stderr: true)
        for line in list.split(separator: "\n") where line.contains("Wine Mono") {
            if let id = line.split(separator: "|").first { try await rt.wine(["msiexec", "/x", String(id), "/qn"], prefix: prefix) }
        }
        for dir in ["system32", "syswow64"] {
            let dll = prefix.appending(path: "drive_c/windows/\(dir)/mscoree.dll")
            if let data = try? Data(contentsOf: dll), data.range(of: Data("WINE_MONO_OVERRIDES".utf8)) != nil { try? fm.removeItem(at: dll) }
        }
        let overrides = [#"HKCU\Software\Wine\DllOverrides"#, "/v", "mscoree", "/t", "REG_SZ", "/d", "native"]

        let net40 = rt.downloads.appending(path: "dotNetFx40_Full_x86_x64.exe")
        try await rt.download(Remote.dotnet40, to: net40, label: "Downloading .NET Framework 4.0", report)
        try await rt.verify(net40, sha: Remote.dotnet40SHA, report)
        report("Installing .NET Framework 4.0, this takes a few minutes…", nil)
        try await winver("winxp64")
        // Wine re-registers its own "4.7" NDP keys on prefix updates (winecfg triggers one); with them, the
        // 4.0 installer thinks it's already installed and skips the real mscoree.dll. Delete them right before.
        for view in [#"HKLM\Software"#, #"HKLM\Software\Wow6432Node"#] {
            for version in ["v3.5", "v4"] {
                try await rt.wine(["reg", "delete", view + #"\Microsoft\NET Framework Setup\NDP\"# + version, "/f"], prefix: prefix)
            }
        }
        try await msInstaller(net40, ["/q", "/c:install.exe /q"])
        guard hasRealMscoree else {
            try await winver("win10")
            throw SetupError(".NET Framework 4.0 didn't install mscoree.dll. See the log for details.")
        }
        try await setReg(overrides)
        try await setReg([#"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "/v", "Install", "/t", "REG_DWORD", "/d", "1"])
        try await setReg([#"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "/v", "Version", "/t", "REG_SZ", "/d", "4.0.30319"])
        try await setReg([#"HKLM\Software\Microsoft\.NETFramework"#, "/v", "OnlyUseLatestCLR", "/t", "REG_DWORD", "/d", "1"])
        try await setReg([#"HKLM\Software\Wow6432Node\.NETFramework"#, "/v", "OnlyUseLatestCLR", "/t", "REG_DWORD", "/d", "1"])
        try? fm.removeItem(at: net40)

        let net48 = rt.downloads.appending(path: "ndp48-x86-x64-allos-enu.exe")
        try await rt.download(Remote.dotnet48, to: net48, label: "Downloading .NET Framework 4.8", report)
        try await rt.verify(net48, sha: Remote.dotnet48SHA, report)
        report("Installing .NET Framework 4.8, this takes several minutes…", nil)
        try await winver("win7")
        try await msInstaller(net48, ["/sfxlang:1027", "/q", "/norestart"])
        try await setReg(overrides)
        try await winver("win10") // the game prefix's default
        try? fm.removeItem(at: net48)
    }

    private struct DotNetReleases: Decodable {
        struct Release: Decodable {
            struct Component: Decodable {
                struct File: Decodable { let name: String; let url: URL; let hash: String }
                let version: String
                let files: [File]
            }
            let windowsdesktop: Component?
        }
        let releases: [Release]
    }

    private func installDesktopRuntime(_ channel: String, _ report: @escaping Report) async throws {
        report("Looking up .NET \(channel)…", nil)
        let (data, _) = try await URLSession.shared.data(from: Remote.dotnetReleases(channel))
        let releases = try JSONDecoder().decode(DotNetReleases.self, from: data).releases
        guard let desktop = releases.lazy.compactMap(\.windowsdesktop).first,
              let file = desktop.files.first(where: { $0.name == "windowsdesktop-runtime-win-x64.exe" }) else {
            throw SetupError("No .NET \(channel) desktop runtime found for Windows x64.")
        }
        let installer = rt.downloads.appending(path: "windowsdesktop-runtime-\(desktop.version)-win-x64.exe")
        try await rt.download(file.url, to: installer, label: "Downloading .NET \(desktop.version)", report)
        try await rt.verify(installer, sha: file.hash, report)
        report("Installing .NET \(desktop.version)…", nil)
        try await msInstaller(installer, ["/install", "/quiet", "/norestart"])
        try? fm.removeItem(at: installer)
    }

    // MARK: Run

    func openStudio() {
        guard studioState == .idle, let studioExe else { return }
        lastError = nil
        mapGameDrive()
        Task {
            do {
                studioState = .starting
                if UserDefaults.standard.bool(forKey: "driveChanged") && !gameRunning() {
                    try await restartWine()
                    UserDefaults.standard.set(false, forKey: "driveChanged")
                }
                // Studio keeps no game folder setting; R: (not Z:\, which Wine reports as a symlink) passes its deploy check
                try rt.spawnWine([studioExe.path, "--game", #"R:\"#], prefix: prefix, cwd: studioExe.deletingLastPathComponent())
                try await Task.sleep(for: .seconds(8))
                studioState = .running
                while studioRunning() { try await Task.sleep(for: .seconds(3)) }
            } catch {
                lastError = error.localizedDescription
            }
            studioState = .idle
        }
    }

    /// Ends every Windows program in the prefix so the next one starts a fresh session; Steam comes back hidden
    private func restartWine() async throws {
        let server = rt.wineRoot.appending(path: "bin/wineserver").path
        try await Shell.run(server, ["-k"], env: wineEnv, log: logFile)
        try await Shell.run(server, ["-w"], env: wineEnv, log: logFile)
        if steamInstalled && hasAutoLogin { try startSteam(visible: false) }
    }

    private func studioRunning() -> Bool {
        guard let name = studioExe?.lastPathComponent else { return false }
        return Shell.succeeds("/usr/bin/pgrep", ["-f", NSRegularExpression.escapedPattern(for: name)])
    }

    // MARK: Actions

    /// Asks for ReSkate_Studio.zip (or its extracted folder / installer); false if cancelled
    @discardableResult
    func chooseStudio() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .exe, .folder]
        panel.prompt = "Choose"
        panel.message = "Pick ReSkate_Studio.zip from the ReSkate Discord (or the extracted ReSkate Studio folder)"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        studioSource = url
        return true
    }

    /// Install (or update) Studio after the game is set up
    func addStudio() {
        guard chooseStudio() else { return }
        withStudio = true
        replaceStudio = studioExe != nil
        startSetup([.studio, .dotnet])
    }

    func openStudioDir() { NSWorkspace.shared.open(studioExe?.deletingLastPathComponent() ?? studioDir) }
}
