import CryptoKit
import Foundation
import Testing
@testable import Tic

/// The in-place updater against real (fake) app bundles: each test installs a signed "Tic.app" into a
/// temp Applications folder, builds a release zip + checksum, and serves them through the injected
/// download. Every failure must leave the installed copy exactly as it was.
@Suite("UpdateInstaller")
struct UpdateInstallerTests {
    @Test("downloads Tico release assets from the Tico repository")
    func assetURLs() {
        #expect(UpdateInstaller.assetURL("Tico.zip", version: "1.2.3").absoluteString
                == "https://github.com/code-wgl/Tico/releases/download/v1.2.3/Tico.zip")
        #expect(UpdateInstaller.assetURL("Tico.zip.sha256", version: "1.2.3").absoluteString
                == "https://github.com/code-wgl/Tico/releases/download/v1.2.3/Tico.zip.sha256")
    }

    @Test("reads thin and universal Mach-O headers without developer tools")
    func executableArchitecture() {
        let intel: UInt32 = 0x01000007
        let arm: UInt32 = 0x0100000c
        func little(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func big(_ value: UInt32) -> [UInt8] { little(value).reversed() }
        func thin(_ cpu: UInt32, subtype: UInt32) -> [UInt8] {
            [0xcf, 0xfa, 0xed, 0xfe] + little(cpu) + little(subtype) + little(2) + Array(repeating: 0, count: 16)
        }
        let intelSlice = thin(intel, subtype: 3)
        let armSlice = thin(arm, subtype: 0)
        let universal = Data(big(0xcafebabe) + big(2)
                             + big(intel) + big(3) + big(48) + big(32) + big(0)
                             + big(arm) + big(0) + big(80) + big(32) + big(0)
                             + intelSlice + armSlice)
        let fat64 = Data(big(0xcafebabf) + big(1)
                         + big(intel) + big(3) + big(0) + big(40) + big(0) + big(32) + big(0) + big(0)
                         + intelSlice)
        let swappedFat = Data(little(0xcafebabe) + little(1)
                              + little(arm) + little(0) + little(28) + little(32) + little(0) + armSlice)
        #expect(UpdateInstaller.supportsMachO(Data(intelSlice), cpuType: intel))
        #expect(!UpdateInstaller.supportsMachO(Data(intelSlice), cpuType: arm))
        #expect(UpdateInstaller.supportsMachO(universal, cpuType: intel))
        #expect(UpdateInstaller.supportsMachO(universal, cpuType: arm))
        #expect(UpdateInstaller.supportsMachO(fat64, cpuType: intel))
        #expect(UpdateInstaller.supportsMachO(swappedFat, cpuType: arm))
        #expect(!UpdateInstaller.supportsMachO(Data(universal.prefix(60)), cpuType: arm))
        #expect(!UpdateInstaller.supportsMachO(Data(thin(arm, subtype: 2)), cpuType: arm))
        #expect(!UpdateInstaller.supportsMachO(Data("#!/bin/sh".utf8), cpuType: intel))
        var notExecutable = intelSlice
        notExecutable[12] = 6 // MH_DYLIB
        #expect(!UpdateInstaller.supportsMachO(Data(notExecutable), cpuType: intel))
    }

    @Test("recognizes the architecture of the running test executable")
    func runningExecutableArchitecture() throws {
        let executable = try #require(Bundle.main.executableURL)
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        #expect(UpdateInstaller.supportsMachO(data, cpuType: cpu))
    }
    private struct Fixture {
        let folder: URL
        var installed: URL { folder.appendingPathComponent("Tico.app") }
    }

    private func makeFixture(installedVersion: String = "0.8.0") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = Fixture(folder: folder)
        try makeApp(at: fixture.installed, version: installedVersion)
        return fixture
    }

    /// A minimal, ad-hoc-signed bundle: Info.plist + a shell-script executable.
    private func makeApp(at app: URL, id: String = "com.kasvith.tic", version: String, minimum: String = "14.0", tamper: Bool = false) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": id, "CFBundleExecutable": "Tic",
            "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": minimum,
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Tic")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        if tamper { try Data("#!/bin/sh\necho changed\n".utf8).write(to: executable) }
    }

    /// A release: `Tico.zip` of a fresh bundle plus its `Tico.zip.sha256` (or a wrong one).
    private func makeRelease(id: String = "com.kasvith.tic", version: String, minimum: String = "14.0", tamper: Bool = false, badChecksum: Bool = false, supportedArchitecture: Bool = true) throws -> UpdateInstaller {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerBuild-\(UUID().uuidString)")
        let app = build.appendingPathComponent("Tico.app")
        try makeApp(at: app, id: id, version: version, minimum: minimum, tamper: tamper)
        let zipURL = build.appendingPathComponent("Tico.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zipURL.path)
        let zip = try Data(contentsOf: zipURL)
        let hash = badChecksum ? String(repeating: "0", count: 64) : SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let checksum = Data("\(hash)  Tico.zip\n".utf8)
        return UpdateInstaller(download: { url in
            url.lastPathComponent == "Tico.zip.sha256" ? checksum : zip
        }, supportsArchitecture: { _ in supportedArchitecture })
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    private func installedVersion(_ fixture: Fixture) -> String? {
        (NSDictionary(contentsOf: fixture.installed.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    @Test("installs the new version in place and leaves nothing behind")
    func installs() async throws {
        let fixture = try makeFixture()
        try await makeRelease(version: "0.9.0").install(version: "0.9.0", replacing: fixture.installed)
        #expect(installedVersion(fixture) == "0.9.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path) == ["Tico.app"])
    }

    @Test("a checksum mismatch stops before touching the installed copy")
    func checksumMismatch() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.checksumMismatch) {
            try await makeRelease(version: "0.9.0", badChecksum: true).install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("rejects an update requiring a newer OS without replacing the installed app")
    func unsupportedSystem() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.incompatibleSystem("999.0")) {
            try await makeRelease(version: "0.9.0", minimum: "999.0").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("rejects an update for a different architecture without replacing the installed app")
    func unsupportedArchitecture() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.incompatibleArchitecture) {
            try await makeRelease(version: "0.9.0", supportedArchitecture: false).install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a failure preparing to swap leaves the existing app in place")
    func preparationFailure() async throws {
        struct Interrupted: Error {}
        let fixture = try makeFixture()
        var installer = try makeRelease(version: "0.9.0")
        installer.beforeSwap = { throw Interrupted() }
        await #expect(throws: Interrupted.self) {
            try await installer.install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a failed atomic exchange leaves the existing app in place")
    func atomicExchangeFailure() async throws {
        let fixture = try makeFixture()
        var installer = try makeRelease(version: "0.9.0")
        installer.atomicSwap = { _, _ in false }
        await #expect(throws: UpdateInstaller.Failure.swapFailed) {
            try await installer.install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("minimum version is compared numerically and invalid metadata is rejected")
    func minimumSystemVersion() {
        let current = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 1)
        #expect(UpdateInstaller.supportsSystemVersion("14.4", current: current))
        #expect(!UpdateInstaller.supportsSystemVersion("14.10", current: current))
        #expect(!UpdateInstaller.supportsSystemVersion("invalid", current: current))
    }

    @Test("a download that isn't Tic is refused")
    func wrongApp() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.wrongApp) {
            try await makeRelease(id: "com.example.other", version: "0.9.0").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a download of another version than the one offered is refused")
    func wrongVersion() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.wrongVersion("0.9.1")) {
            try await makeRelease(version: "0.9.1").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("an app whose signature no longer matches is refused")
    func brokenSignature() async throws {
        let fixture = try makeFixture()
        await #expect(throws: UpdateInstaller.Failure.badSignature) {
            try await makeRelease(version: "0.9.0", tamper: true).install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }

    @Test("a folder Tic can't write to is reported, not attempted")
    func notWritable() async throws {
        let fixture = try makeFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path) }
        await #expect(throws: UpdateInstaller.Failure.notWritable(fixture.folder.path)) {
            try await makeRelease(version: "0.9.0").install(version: "0.9.0", replacing: fixture.installed)
        }
        #expect(installedVersion(fixture) == "0.8.0")
    }
}
