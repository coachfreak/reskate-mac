import AppKit

// Optional ReShade: its DLL goes beside Skate.exe as dxgi.dll, and Wine loads that native dxgi for Skate.exe only
// (per-exe DllOverrides), so ReSkateLauncher.exe and Steam stay untouched.

extension Remote {
    static let reshadeVersion = "6.8.0"
    static let reshadeSetup = URL(string: "https://reshade.me/downloads/ReShade_Setup_\(reshadeVersion).exe")!
    static let reshadeSetupSHA = "207aea16205fbf952bc8fe1879966672454cf04002e7ad34237c7990a5b3c0b4"
    // ReShade's own standard effects (its installer's default pick)
    static let reshadeShaders = URL(string: "https://github.com/crosire/reshade-shaders/archive/refs/heads/slim.zip")!
}

/// Keys offered for the ReShade menu, as Windows virtual-key codes. Insert and ` are ReSkate's own menu and console.
enum ReShadeKey {
    static let all: [(name: String, vk: Int)] =
        [("Home", 0x24), ("End", 0x23), ("Page Up", 0x21), ("Page Down", 0x22)]
        + (1...12).map { ("F\($0)", 0x6F + $0) }

    static func name(_ vk: Int) -> String { all.first { $0.vk == vk }?.name ?? String(format: "Key 0x%02X", vk) }
}

extension Launcher {
    var reshadeDir: URL { support.appending(path: "reshade") }
    var reshadeDLL: URL { reshadeDir.appending(path: "ReShade64.dll") }
    var reshadeInstalled: Bool { fm.fileExists(atPath: reshadeDLL.path) && fm.fileExists(atPath: reshadeDir.appending(path: "reshade-shaders").path) }

    func installReShade(_ report: @escaping Report) async throws -> String {
        if reshadeInstalled { return "ReShade \(Remote.reshadeVersion) already installed" }
        try fm.createDirectory(at: reshadeDir, withIntermediateDirectories: true)
        let setup = rt.downloads.appending(path: "ReShade_Setup.exe")
        try await rt.download(Remote.reshadeSetup, to: setup, label: "Downloading ReShade", report)
        try await rt.verify(setup, sha: Remote.reshadeSetupSHA, report)
        report("Extracting…", nil)
        // the installer is a zip with a stub in front; unzip warns about that and exits 1
        let code = try await Shell.run("/usr/bin/unzip", ["-o", "-j", setup.path, "ReShade64.dll", "-d", reshadeDir.path], log: logFile)
        guard code <= 1, fm.fileExists(atPath: reshadeDLL.path) else { throw SetupError("Could not extract ReShade (code \(code)).") }
        try? fm.removeItem(at: setup)

        let zip = rt.downloads.appending(path: "reshade-shaders.zip")
        try await rt.download(Remote.reshadeShaders, to: zip, label: "Downloading shaders", report)
        let tmp = rt.downloads.appending(path: "reshade-shaders-tmp")
        try? fm.removeItem(at: tmp)
        try await rt.unzip(zip, into: tmp)
        guard let root = rt.findDir(in: tmp, containing: "Shaders") else { throw SetupError("Unexpected shader archive layout.") }
        try? fm.removeItem(at: reshadeDir.appending(path: "reshade-shaders"))
        try fm.moveItem(at: root, to: reshadeDir.appending(path: "reshade-shaders"))
        try? fm.removeItem(at: tmp)
        try? fm.removeItem(at: zip)
        return "ReShade \(Remote.reshadeVersion) installed"
    }

    /// Before each launch: put ReShade beside the game (or switch it off) and set its menu key
    func applyReShade() async throws {
        let override = #"HKCU\Software\Wine\AppDefaults\Skate.exe\DllOverrides"#
        guard reshade, reshadeInstalled else {
            try await rt.wine(["reg", "add", override, "/v", "dxgi", "/t", "REG_SZ", "/d", "builtin", "/f"], prefix: prefix)
            return
        }
        let dll = gameDir.appending(path: "dxgi.dll")
        if (try? Data(contentsOf: dll)) != (try? Data(contentsOf: reshadeDLL)) {
            try? fm.removeItem(at: dll)
            try fm.copyItem(at: reshadeDLL, to: dll)
        }
        let shaders = gameDir.appending(path: "reshade-shaders")
        if !fm.fileExists(atPath: shaders.path) { try fm.copyItem(at: reshadeDir.appending(path: "reshade-shaders"), to: shaders) }
        try writeReShadeKey()
        try await rt.wine(["reg", "add", override, "/v", "dxgi", "/t", "REG_SZ", "/d", "native,builtin", "/f"], prefix: prefix)
        // same folder, but the ReSkate launcher window should not get ReShade
        let launcherOverride = #"HKCU\Software\Wine\AppDefaults\ReSkateLauncher.exe\DllOverrides"#
        try await rt.wine(["reg", "add", launcherOverride, "/v", "dxgi", "/t", "REG_SZ", "/d", "builtin", "/f"], prefix: prefix)
    }

    /// Sets [INPUT] KeyOverlay in ReShade.ini, keeping everything else ReShade saved there
    private func writeReShadeKey() throws {
        let ini = gameDir.appending(path: "ReShade.ini")
        var text = (try? String(contentsOf: ini, encoding: .utf8)) ?? """
            [GENERAL]
            EffectSearchPaths=.\\reshade-shaders\\Shaders\\**
            TextureSearchPaths=.\\reshade-shaders\\Textures\\**
            PresetPath=.\\ReShadePreset.ini

            """
        let line = "KeyOverlay=\(reshadeKey),0,0,0"
        if let range = text.range(of: #"(?m)^KeyOverlay=.*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: line)
        } else if let range = text.range(of: #"(?m)^\[INPUT\]\s*$"#, options: .regularExpression) {
            text.insert(contentsOf: "\n" + line, at: range.upperBound)
        } else {
            text += "\n[INPUT]\n\(line)\n"
        }
        try text.write(to: ini, atomically: true, encoding: .utf8)
    }

    /// The TOOLS / welcome switch: turning it on installs ReShade if needed
    func setReShade(_ on: Bool) {
        reshade = on
        if on && !reshadeInstalled && phase == .ready { startSetup([.reshade]) }
    }
}
