// Updates from the project's GitHub releases: checks once a day; a newer release is downloaded, checked against the
// release key's signature, unpacked, swapped in and restarted. curl, ditto and codesign do the heavy lifting in their
// own processes, so no networking code ever loads into Crumb itself.

import AppKit
import Security

private let lastCheckKey = "lastUpdateCheck"
private let assetName = "Crumb.zip"
private let checkInterval: TimeInterval = 24 * 60 * 60

private enum Outcome {
    case upToDate, installed, failed
}

private func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: Data) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    let output = Pipe()
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return (-1, Data()) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, data)
}

/// True when `signature` is the release key's ECDSA P-256 signature (DER, SHA-256) of `data`.
private func signedByRelease(_ data: Data, _ signature: Data, publicKey: String) -> Bool {
    guard let raw = Data(base64Encoded: publicKey), raw.count == 65, !signature.isEmpty else { return false }
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 256,
    ]
    guard let key = SecKeyCreateWithData(raw as CFData, attributes as CFDictionary, nil) else { return false }
    return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, signature as CFData, nil)
}

/// Whether this Mac's macOS is new enough for a bundle (its LSMinimumSystemVersion).
private func runsHere(_ info: [String: Any]) -> Bool {
    guard let minimum = info["LSMinimumSystemVersion"] as? String else { return true }
    let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
    let version = OperatingSystemVersion(majorVersion: parts.count > 0 ? parts[0] : 0, minorVersion: parts.count > 1 ? parts[1] : 0,
                                         patchVersion: parts.count > 2 ? parts[2] : 0)
    return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
}

private struct Source: Sendable {
    let api: String          // the latest-release URL
    let publicKey: String    // base64 of the release key
    let httpsOnly: Bool      // tests point Crumb at local files
}

private func update(_ source: Source, current: String, bundlePath: String, identifier: String) -> (Outcome, String) {
    let secure = source.httpsOnly ? ["--proto", "=https", "--proto-redir", "=https"] : []
    let (status, json) = run("/usr/bin/curl", secure + ["-fsSL", "--max-time", "20", "-H", "Accept: application/vnd.github+json", "-A", "Crumb", source.api])
    guard status == 0, let release = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
          let tag = release["tag_name"] as? String
    else { return (.failed, "Couldn't check for updates.") }
    if !isNewerVersion(tag, current) { return (.upToDate, "Crumb is up to date.") }
    var download: String?, signatureURL: String?
    for asset in release["assets"] as? [[String: Any]] ?? [] {
        if asset["name"] as? String == assetName { download = asset["browser_download_url"] as? String }
        if asset["name"] as? String == assetName + ".sig" { signatureURL = asset["browser_download_url"] as? String }
    }
    guard let download, let signatureURL else { return (.failed, "The new version has no download yet.") }

    // A folder on the same volume as Crumb, so the new version can be swapped in.
    let files = FileManager.default
    guard let scratch = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                       appropriateFor: URL(fileURLWithPath: bundlePath), create: true)
    else { return (.failed, "Crumb can't update itself in this folder.") }
    let folder = scratch.path
    func fail(_ text: String) -> (Outcome, String) {
        try? files.removeItem(atPath: folder)
        return (.failed, text)
    }
    let zip = folder + "/Crumb.zip", signature = folder + "/Crumb.zip.sig", unpacked = folder + "/new"
    let fetch = secure + ["-fsSL", "--max-time", "600", "-A", "Crumb", "-o"]
    if run("/usr/bin/curl", fetch + [zip, download]).status != 0 { return fail("Couldn't download the update.") }
    guard run("/usr/bin/curl", fetch + [signature, signatureURL]).status == 0,
          let archive = try? Data(contentsOf: URL(fileURLWithPath: zip), options: .mappedIfSafe),
          let signed = try? Data(contentsOf: URL(fileURLWithPath: signature)),
          signedByRelease(archive, signed, publicKey: source.publicKey)
    else { return fail("The download isn't signed by Crumb's release key.") }

    let unzipped = run("/usr/bin/ditto", ["-x", "-k", zip, unpacked]).status == 0
    let app = unpacked + "/Crumb.app"
    let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any] ?? [:]
    guard unzipped, info["CFBundleIdentifier"] as? String == identifier, let version = info["CFBundleShortVersionString"] as? String,
          isNewerVersion(version, current)
    else { return fail("The download isn't a newer Crumb.") }
    if !runsHere(info) { return fail("Crumb \(version) needs a newer version of macOS.") }
    if run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]).status != 0 { return fail("The download is damaged.") }

    // Swap the old and new bundles in one step; the running copy keeps working from memory until the restart.
    if renamex_np(app, bundlePath, UInt32(RENAME_SWAP)) != 0 { return fail("Crumb can't replace itself in this folder.") }
    try? files.removeItem(atPath: folder)
    return (.installed, "Updated to \(version). Restarting…")
}

@MainActor
final class Updater {
    private weak var popup: Popup?
    private var api: String?
    private let publicKey: String?
    private var localTest = false
    private var timer: Timer?
    private var busy = false

    init(popup: Popup) {
        self.popup = popup
        let bundle = Bundle.main
        let key = bundle.object(forInfoDictionaryKey: "CrumbUpdateKey") as? String
        publicKey = key?.isEmpty == false ? key : nil
        if let override = ProcessInfo.processInfo.environment["CRUMB_UPDATE_URL"], !override.isEmpty {
            api = override  // for tests: a local release, still checked against the release key
            localTest = true
        } else if let repository = bundle.object(forInfoDictionaryKey: "CrumbRepository") as? String,
                  repository.split(separator: "/").count == 2 {
            api = "https://api.github.com/repos/\(repository)/releases/latest"
        }
        if publicKey == nil { api = nil }  // a build without the release key can't trust any download
    }

    /// False when the build can't verify updates.
    var available: Bool { api != nil }

    func start() {
        guard api != nil else { return }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 15 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Defaults.checkForUpdates) else { return }
        if Date().timeIntervalSince1970 - defaults.double(forKey: lastCheckKey) < checkInterval { return }
        check(nil)
    }

    func checkNow(_ report: @escaping @MainActor (String) -> Void) {
        check(report)
    }

    private func check(_ report: (@MainActor (String) -> Void)?) {
        guard let api, let publicKey, !busy else {
            report?(api == nil ? "Updates aren't available for this build." : "Already checking…")
            return
        }
        busy = true
        let source = Source(api: api, publicKey: publicKey, httpsOnly: !localTest)
        let bundle = Bundle.main
        let current = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let path = bundle.bundlePath, identifier = bundle.bundleIdentifier ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (outcome, message) = update(source, current: current, bundlePath: path, identifier: identifier)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    // Automatic checks wait a day even after a failure, so a broken release isn't fetched over and over.
                    if outcome != .failed || report == nil {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                    }
                    report?(message)
                    if outcome == .installed { self.restart() }
                }
            }
        }
    }

    /// Starts the new version once this one has quit, waiting until the list isn't open.
    private func restart() {
        if popup?.isOpen == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                MainActor.assumeIsolated { self?.restart() }
            }
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        if (try? task.run()) != nil { NSApp.terminate(nil) }
    }
}
