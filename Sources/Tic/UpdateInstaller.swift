import CryptoKit
import Foundation
import Darwin

/// Replaces the installed Tico with a release: downloads `Tico.zip`, checks it against
/// `Tico.zip.sha256`, unpacks it, confirms its identity and version and checks its signature,
/// then swaps it in. Files Tic downloads itself get no quarantine flag (it isn't sandboxed and doesn't
/// set `LSFileQuarantineEnabled`), so the new copy opens without Gatekeeper's block, unsigned or not.
struct UpdateInstaller: Sendable {
    enum Failure: LocalizedError, Equatable {
        case notWritable(String)
        case checksumMismatch
        case badArchive
        case wrongApp
        case wrongVersion(String)
        case badSignature
        case incompatibleSystem(String)
        case incompatibleArchitecture
        case swapFailed

        var errorDescription: String? {
            switch self {
            case .notWritable(let folder): "Tico can't replace itself in \(folder)."
            case .checksumMismatch: "The download didn't match its checksum."
            case .badArchive: "The download didn't contain Tico."
            case .wrongApp: "The download wasn't Tico."
            case .wrongVersion(let found): "The download was v\(found), not the expected version."
            case .badSignature: "The downloaded app's signature is broken."
            case .incompatibleSystem(let version): "This update requires macOS \(version)."
            case .incompatibleArchitecture: "This update does not support this Mac's processor."
            case .swapFailed: "The update could not be safely installed on this volume. Your current app is unchanged."
            }
        }
    }

    /// Fetches a release asset. Injected by tests; the app downloads from GitHub.
    var download: @Sendable (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    var supportsArchitecture: @Sendable (URL) async -> Bool = { executable in
        #if arch(arm64)
        let cpuType: UInt32 = 0x0100000c
        #else
        let cpuType: UInt32 = 0x01000007
        #endif
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return false }
        return Self.supportsMachO(data, cpuType: cpuType)
    }

    /// Called after validation and immediately before replacing the running app.
    var beforeSwap: @Sendable () async throws -> Void = {}
    var atomicSwap: @Sendable (URL, URL) -> Bool = { old, new in
        renamex_np(old.path, new.path, UInt32(RENAME_SWAP)) == 0
    }

    /// Pinned to the version the user was offered, not `latest`, so a release landing mid-update can't
    /// swap in something they didn't see the notes for.
    static func assetURL(_ name: String, version: String) -> URL {
        URL(string: "https://github.com/code-wgl/Tico/releases/download/v\(version)/\(name)")!
    }

    /// Replaces the app at `app` with `version`. On any failure the installed copy is left as it was.
    func install(version: String, replacing app: URL) async throws {
        let files = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: app.path) else {
            throw Failure.notWritable(folder.path)
        }

        async let zip = download(Self.assetURL("Tico.zip", version: version))
        async let checksum = download(Self.assetURL("Tico.zip.sha256", version: version))
        let (archiveData, checksumData) = try await (zip, checksum)
        let expected = String(bytes: checksumData, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first
        let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard expected?.lowercased() == actual else { throw Failure.checksumMismatch }

        // A scratch folder on the app's own volume, so the final moves are renames, not copies.
        let staging = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true
        )
        defer { try? files.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("Tico.zip")
        try archiveData.write(to: archive)
        guard await Self.run("/usr/bin/ditto", "-x", "-k", archive.path, staging.path) else { throw Failure.badArchive }

        let new = staging.appendingPathComponent("Tico.app")
        guard let newInfo = Self.info(of: new) else { throw Failure.badArchive }
        let installedID = Self.info(of: app)?["CFBundleIdentifier"] as? String
        guard installedID == "com.kasvith.tic",
              let id = newInfo["CFBundleIdentifier"] as? String, id == installedID else { throw Failure.wrongApp }
        let found = newInfo["CFBundleShortVersionString"] as? String ?? "?"
        guard found == version else { throw Failure.wrongVersion(found) }
        guard await Self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", new.path) else { throw Failure.badSignature }
        let minimum = newInfo["LSMinimumSystemVersion"] as? String ?? "?"
        guard Self.supportsSystemVersion(minimum, current: ProcessInfo.processInfo.operatingSystemVersion) else {
            throw Failure.incompatibleSystem(minimum)
        }
        guard let executable = newInfo["CFBundleExecutable"] as? String,
              executable == "Tic",
              await supportsArchitecture(new.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)) else {
            throw Failure.incompatibleArchitecture
        }
        try await beforeSwap()

        // Exchange both directory entries atomically: a crash cannot leave the app path empty.
        // If the filesystem cannot exchange them, leave the existing app in place.
        guard atomicSwap(app, new) else { throw Failure.swapFailed }
    }

    static func supportsSystemVersion(_ minimum: String, current: OperatingSystemVersion) -> Bool {
        let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return false }
        let required = parts.compactMap { Int($0) } + Array(repeating: 0, count: 3 - parts.count)
        let installed = [current.majorVersion, current.minorVersion, current.patchVersion]
        return !required.lexicographicallyPrecedes(installed) ? required == installed : true
    }

    /// Inspect Mach-O headers without Xcode or Command Line Tools. Reject truncated, mismatched,
    /// non-executable and CPU-specialized slices rather than guessing that they can run.
    static func supportsMachO(_ data: Data, cpuType: UInt32) -> Bool {
        func word(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
            let bytes = data[offset..<(offset + 4)]
            return bigEndian ? bytes.reduce(0) { ($0 << 8) | UInt32($1) }
                : bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func doubleWord(_ offset: Int, bigEndian: Bool) -> UInt64? {
            guard let first = word(offset, bigEndian: bigEndian),
                  let second = word(offset + 4, bigEndian: bigEndian) else { return nil }
            return bigEndian ? UInt64(first) << 32 | UInt64(second) : UInt64(second) << 32 | UInt64(first)
        }
        func thinSlice(_ offset: Int, size: Int) -> Bool {
            guard size >= 32, offset >= 0, offset <= data.count, size <= data.count - offset,
                  let magic = word(offset, bigEndian: true), magic == 0xcffaedfe,
                  word(offset + 4, bigEndian: false) == cpuType,
                  let subtype = word(offset + 8, bigEndian: false),
                  word(offset + 12, bigEndian: false) == 2 else { return false } // MH_EXECUTE
            // x86_64h / arm64e are not guaranteed to run on every Mac of that architecture.
            let baseSubtype = subtype & 0x00ffffff
            return cpuType == 0x01000007 ? baseSubtype == 3 : baseSubtype == 0 || baseSubtype == 1
        }

        guard let magic = word(0, bigEndian: true) else { return false }
        if magic == 0xcffaedfe { return thinSlice(0, size: data.count) }
        let bigEndian = magic == 0xcafebabe || magic == 0xcafebabf
        let littleEndian = magic == 0xbebafeca || magic == 0xbfbafeca
        guard bigEndian || littleEndian, let count = word(4, bigEndian: bigEndian), count > 0, count <= 128 else { return false }
        let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
        let stride = fat64 ? 32 : 20
        guard data.count >= 8 + Int(count) * stride else { return false }
        for index in 0..<Int(count) {
            let entry = 8 + index * stride
            guard word(entry, bigEndian: bigEndian) == cpuType else { continue }
            let offset = fat64 ? doubleWord(entry + 8, bigEndian: bigEndian) : word(entry + 8, bigEndian: bigEndian).map(UInt64.init)
            let size = fat64 ? doubleWord(entry + 16, bigEndian: bigEndian) : word(entry + 12, bigEndian: bigEndian).map(UInt64.init)
            guard let offset, let size, let start = Int(exactly: offset), let length = Int(exactly: size),
                  start >= 8 + Int(count) * stride else { continue }
            if thinSlice(start, size: length) { return true }
        }
        return false
    }

    /// Reopens `app` once this process has exited. The shell outlives Tic, waits for its pid to go, and
    /// opens the (now updated) bundle; the path is passed as `$0` so it needs no quoting.
    static func relaunchAfterExit(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\""
        process.arguments = ["-c", script, app.path]
        try? process.run()
    }

    private static func info(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// Runs a tool to completion without blocking a thread; true when it exits 0.
    private static func run(_ tool: String, _ arguments: String...) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
    }
}
