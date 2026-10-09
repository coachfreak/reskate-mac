import AppKit
import CryptoKit

// Wine + GPTK runtime setup, process and download helpers.

// MARK: - Remote sources

enum Remote {
    // GameHub CDN builds (same files GameHub installs); checksums from GameHub's own metadata
    static let wine = URL(string: "https://gamehub-cdn.youwo.com/uploads/emulator/20260928/a4d87d22d80f462c8bb1a60bf0ca6ec6.zst")!
    static let wineSHA = "d85b764deaadc7094c265d33446ecd5e617af0b6f5cc88424cd0ab9bbc6b7b96"
    static let gptk = URL(string: "https://gamehub-cdn.youwo.com/uploads/emulator/20260805/cf228daa416d4c8c8c1a66c5cae11a0b.tzst")!
    static let gptkSHA = "ef025bdcfe040f056345439d593d2f42ae72869ab92c8745726d4633a13997be"
}

// MARK: - Model

enum StepState: Equatable { case pending, running, done, skipped, failed }

struct StepStatus {
    var state = StepState.pending
    var detail = ""
    var progress: Double?
}

struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Setup progress callback: detail text and optional download progress
typealias Report = @MainActor (String, Double?) -> Void

// MARK: - Runtime (Wine + GPTK)

@MainActor
struct Runtime {
    let home: URL
    let logFile: URL
    private let fm = FileManager.default

    init(log name: String) {
        // RESKATE_HOME: test a fresh install without touching the real one
        home = ProcessInfo.processInfo.environment["RESKATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        logFile = home.appending(path: "Library/Application Support/ReSkate/logs/\(name)")
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
    }

    var support: URL { home.appending(path: "Library/Application Support/ReSkate") }
    var runtime: URL { support.appending(path: "runtime") }
    var downloads: URL { support.appending(path: "downloads") }
    var wineRoot: URL { runtime.appending(path: "wine") }
    var wineBin: URL { wineRoot.appending(path: "bin/wine") }
    var gptkDir: URL { runtime.appending(path: "gptk-4.0-2") }
    var gptkLib: URL { gptkDir.appending(path: "external/libd3dshared.dylib") }
    var gameHubEngine: URL { home.appending(path: "Library/Application Support/com.gamemac.www/wine-engine") }

    var isInstalled: Bool { fm.isExecutableFile(atPath: wineBin.path) && fm.fileExists(atPath: gptkLib.path) }

    func wineEnv(prefix: URL) -> [String: String] {
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

    // MARK: Install steps

    private var rosettaInstalled: Bool { fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }

    func ensureRosetta(_ report: Report) async throws -> String {
        if rosettaInstalled { return "Already installed" }
        report("Installing, macOS will ask for your password…", nil)
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

    func installWine(_ report: @escaping Report) async throws -> String {
        if fm.isExecutableFile(atPath: wineBin.path) { return "Already installed" }
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        let tmp = runtime.appending(path: ".wine-tmp")
        try? fm.removeItem(at: tmp)
        var source = "downloaded from GameHub CDN"
        if let local = await localGameHubWine() {
            report("Copying Wine from your GameHub install…", nil)
            try await Shell.check("/bin/cp", ["-Rc", local.path, tmp.path], log: logFile)
            source = "copied from GameHub"
        } else {
            let archive = downloads.appending(path: "wine.tar.zst")
            try await download(Remote.wine, to: archive, label: "Downloading Wine", report)
            try await verify(archive, sha: Remote.wineSHA, report)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            report("Extracting…", nil)
            try await extract(archive, into: tmp)
            try? fm.removeItem(at: archive)
        }
        guard let root = findDir(in: tmp, containing: "bin/wine") else { throw SetupError("Unexpected Wine archive layout.") }
        try fm.moveItem(at: root, to: wineRoot)
        try? fm.removeItem(at: tmp)
        return "Wine 11 \(source)"
    }

    func installGPTK(_ report: @escaping Report) async throws -> String {
        if fm.fileExists(atPath: gptkLib.path) { return "Already installed" }
        try? fm.removeItem(at: gptkDir)
        let local = gameHubEngine.appending(path: "downloads/gptk-4.0-2")
        if fm.fileExists(atPath: local.appending(path: "external/libd3dshared.dylib").path) {
            try await Shell.check("/bin/cp", ["-Rc", local.path, gptkDir.path], log: logFile)
            return "Copied from GameHub"
        }
        let archive = downloads.appending(path: "gptk.tar.zst")
        try await download(Remote.gptk, to: archive, label: "Downloading GPTK", report)
        try await verify(archive, sha: Remote.gptkSHA, report)
        report("Extracting…", nil)
        try await extract(archive, into: runtime) // archive root is gptk-4.0-2/
        try? fm.removeItem(at: archive)
        guard fm.fileExists(atPath: gptkLib.path) else { throw SetupError("Unexpected GPTK archive layout.") }
        return "Downloaded from GameHub CDN"
    }

    /// Creates the Wine prefix with the Mac fixes; extra registry entries go in as `reg add` arguments
    func setupPrefix(_ prefix: URL, extraRegs: [[String]] = [], _ report: Report) async throws -> String {
        var done: [String] = []
        if !fm.fileExists(atPath: prefix.appending(path: "system.reg").path) {
            report("Creating, this takes a moment…", nil)
            try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            try await wine(["wineboot", "-u"], prefix: prefix)
            let regs = [
                [#"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", "N"],
                [#"HKCU\Control Panel\Desktop"#, "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96"],
                [#"HKCU\Software\Wine\Fonts"#, "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96"],
                // PS4 pad: hide raw Bluetooth HID (game can't read it under macOS), keep SDL/XInput device
                [#"HKLM\System\CurrentControlSet\Services\winebus"#, "/v", "DisableHidraw", "/t", "REG_DWORD", "/d", "1"],
            ] + extraRegs
            for args in regs { try await wine(["reg", "add"] + args + ["/f"], prefix: prefix) }
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

    // MARK: Helpers

    @discardableResult
    func wine(_ args: [String], prefix: URL, cwd: URL? = nil, env extra: [String: String] = [:]) async throws -> Int32 {
        try await Shell.run(wineBin.path, args, env: wineEnv(prefix: prefix).merging(extra) { $1 }, cwd: cwd, log: logFile)
    }

    func spawnWine(_ args: [String], prefix: URL, cwd: URL? = nil) throws {
        try Shell.spawn(wineBin.path, args, env: wineEnv(prefix: prefix), cwd: cwd, log: logFile)
    }

    func download(_ url: URL, to dest: URL, label: String, _ report: @escaping Report) async throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        report("\(label)…", nil)
        let downloader = Downloader(dest: dest) { done, total in
            Task { @MainActor in
                report(total > 0 ? "\(label) · \(done.bytes) of \(total.bytes)" : "\(label) · \(done.bytes)",
                       total > 0 ? Double(done) / Double(total) : nil)
            }
        }
        try await downloader.start(url)
    }

    func verify(_ file: URL, sha: String, _ report: Report) async throws {
        report("Verifying download…", nil)
        let actual = try await Task.detached { try checksum(of: file, sha512: sha.count == 128) }.value
        guard actual == sha.lowercased() else {
            try? fm.removeItem(at: file)
            throw SetupError("Checksum mismatch. The download is corrupted or was changed.")
        }
    }

    private func extract(_ archive: URL, into dir: URL) async throws {
        guard let zstd = Bundle.main.url(forResource: "zstd", withExtension: nil) else { throw SetupError("zstd is missing from the app bundle.") }
        let script = #"set -o pipefail; "$0" -dc "$1" | /usr/bin/tar -xf - -C "$2""#
        try await Shell.check("/bin/bash", ["-c", script, zstd.path, archive.path, dir.path], log: logFile)
    }

    /// Unzips a Windows zip; those use backslash paths, which unzip converts (and exits 1 for that warning)
    func unzip(_ zip: URL, into dir: URL) async throws {
        let code = try await Shell.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", dir.path], log: logFile)
        guard code <= 1 else { throw SetupError("Could not extract \(zip.lastPathComponent) (code \(code)).") }
    }

    func findDir(in root: URL, containing relative: String) -> URL? {
        if fm.fileExists(atPath: root.appending(path: relative).path) { return root }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appending(path: relative).path) }
    }

    func findFiles(in root: URL, where match: (URL) -> Bool) -> [URL] {
        var found: [URL] = []
        let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if match(url) { found.append(url) }
        }
        return found
    }

    func log(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("[\(Date())] \(line)\n".utf8))
        try? handle.close()
    }
}

/// The ReSkate launcher embeds its 2560x1440 background art; reuse it instead of shipping a copy
func loadBackground(from exe: URL, cache: URL) async -> NSImage? {
    await Task.detached { () -> NSImage? in
        let fm = FileManager.default
        let exeDate = (try? fm.attributesOfItem(atPath: exe.path)[.modificationDate]) as? Date
        let cacheDate = (try? fm.attributesOfItem(atPath: cache.path)[.modificationDate]) as? Date
        if let cacheDate, exeDate.map({ $0 <= cacheDate }) ?? true { return NSImage(contentsOf: cache) }
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe),
              let jpeg = largestJPEG(in: data) else { return cacheDate != nil ? NSImage(contentsOf: cache) : nil }
        try? jpeg.write(to: cache)
        return NSImage(data: jpeg)
    }.value
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

    static func output(_ exe: String, _ args: [String], env: [String: String]? = nil, stderr: Bool = false) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let env { process.environment = env }
        process.standardOutput = pipe
        process.standardError = stderr ? pipe : FileHandle.nullDevice
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

/// SHA-256 hex digest, or SHA-512 (what Microsoft publishes for .NET)
func checksum(of file: URL, sha512: Bool = false) throws -> String {
    func digest<H: HashFunction>(_ hasher: inout H) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    if sha512 { var h = SHA512(); return try digest(&h) }
    var h = SHA256()
    return try digest(&h)
}

extension Int64 {
    // fixed English formatting regardless of system locale
    var bytes: String { String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), Double(self) / 1_000_000) }
}

extension String {
    var tilde: String { (self as NSString).abbreviatingWithTildeInPath }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
