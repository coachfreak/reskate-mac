import AppKit

/// Looks for a newer launcher release on GitHub and, after asking, swaps the app bundle in place and relaunches.
@MainActor
enum Updater {
    static let latest = URL(string: "https://api.github.com/repos/coachfreak/reskate-mac/releases/latest")!

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String? // "sha256:<hex>"
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
    }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "v1.2.0" is newer than "1.1.9"
    static func isNewer(_ tag: String, than version: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (parts(tag), parts(version))
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
            return (i < a.count ? a[i] : 0) > (i < b.count ? b[i] : 0)
        }
        return false
    }

    static func check() async {
        guard let data = try? await URLSession.shared.data(from: latest).0,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              isNewer(release.tag_name, than: current),
              let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return }

        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let alert = NSAlert()
        alert.messageText = "ReSkate Mac Launcher \(version) is available"
        let notes = (release.body ?? "").prefix(600)
        alert.informativeText = "You have \(current). The launcher updates itself and restarts; your games and settings stay.\n\n\(notes)"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try await install(asset.browser_download_url, digest: asset.digest)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Update failed"
            failed.informativeText = "\(error.localizedDescription)\n\nYou can download it from the release page instead."
            failed.addButton(withTitle: "Open Release Page")
            failed.addButton(withTitle: "Close")
            if failed.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.html_url) }
        }
    }

    private static func install(_ url: URL, digest: String?) async throws {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        // a quarantined app run from Downloads is translocated to a read-only copy
        guard !target.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw SetupError("The launcher can't replace itself where it is (\(target.deletingLastPathComponent().path.tilde)). Move ReSkate.app to Applications first.")
        }
        let work = fm.temporaryDirectory.appending(path: "ReSkateUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appending(path: "ReSkate.dmg")
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SetupError("Download failed.") }
        try fm.moveItem(at: downloaded, to: dmg)
        if let digest, digest.hasPrefix("sha256:") {
            guard try checksum(of: dmg) == digest.dropFirst(7).lowercased() else { throw SetupError("Checksum mismatch. The download is corrupted or was changed.") }
        }

        let mount = work.appending(path: "mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Shell.check("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path], log: nil)
        let staged = work.appending(path: "ReSkate.app")
        let copy = try await Shell.run("/usr/bin/ditto", [mount.appending(path: "ReSkate.app").path, staged.path])
        try await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard copy == 0 else { throw SetupError("The disk image has no ReSkate.app.") }
        try await Shell.check("/usr/bin/codesign", ["--verify", "--deep", staged.path], log: nil)

        // swap once this process has quit: keep the old bundle until the new one is in place, then relaunch
        let script = #"""
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            if mv "$2" "$2.old" && mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
            open "$2"
            rm -rf "$4"
            """#
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path, work.path]
        try swap.run()
        NSApp.terminate(nil)
    }
}
