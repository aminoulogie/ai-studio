import XCTest
@testable import AIStudio

final class StudioUpdaterTests: XCTestCase {
    private func makeUpdater(directory: URL, defaults: UserDefaults, builtIn: Int = 5) -> StudioUpdater {
        let manifest = StudioWebManifest(version: builtIn, sha256: "", size: 0, minNative: 1)
        return StudioUpdater(directory: directory, defaults: defaults,
                             builtIn: { manifest },
                             bundledHTML: { "<html>built-in studioInitialized</html>" })
    }

    private func fixture() -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "StudioUpdaterTests." + UUID().uuidString)!
        return (directory, defaults)
    }

    private func bundle(version: Int, minNative: Int = 1,
                        body: String = "<html>update studioInitialized</html>") -> (StudioWebManifest, Data) {
        let data = Data(body.utf8)
        return (StudioWebManifest(version: version, sha256: StudioUpdater.sha256Hex(data),
                                  size: data.count, minNative: minNative), data)
    }

    func testReleaseTagParsing() {
        XCTAssertEqual(StudioUpdater.version(fromTag: "v1.0.97"), 97)
        XCTAssertEqual(StudioUpdater.version(fromTag: "1.0.5"), 5)
        XCTAssertNil(StudioUpdater.version(fromTag: "v2.0.1"))
        XCTAssertNil(StudioUpdater.version(fromTag: "v1.0.x"))
        XCTAssertNil(StudioUpdater.version(fromTag: "latest"))
    }

    func testPicksNewestReleaseWithBothAssetsOnGitHubOnly() throws {
        func asset(_ name: String, _ id: String) -> [String: Any] {
            ["name": name, "url": "https://api.github.com/repos/o/r/releases/assets/\(id)"]
        }
        let foreign: [String: Any] = ["name": "studio-web.json", "url": "https://evil.example/m"]
        let releases: [[String: Any]] = [
            ["tag_name": "v1.0.99", "draft": true, "assets": [asset("studio-web.json", "99m"), asset("studio-web.html", "99h")]],
            ["tag_name": "v1.0.98", "assets": [asset("AIStudio-v1.0.98.ipa", "98i")]],
            ["tag_name": "v1.0.100", "assets": [foreign, asset("studio-web.html", "100h")]],
            ["tag_name": "v1.0.97", "assets": [asset("studio-web.json", "97m"), asset("studio-web.html", "97h")]],
            ["tag_name": "v1.0.96", "assets": [asset("studio-web.json", "96m"), asset("studio-web.html", "96h")]]
        ]
        let data = try JSONSerialization.data(withJSONObject: releases)
        let picked = StudioUpdater.pickRelease(from: data)
        XCTAssertEqual(picked?.version, 97)
        XCTAssertEqual(picked?.manifestURL.lastPathComponent, "97m")
        XCTAssertEqual(picked?.htmlURL.lastPathComponent, "97h")
        XCTAssertNil(StudioUpdater.pickRelease(from: Data("[]".utf8)))
        XCTAssertNil(StudioUpdater.pickRelease(from: Data("not json".utf8)))
    }

    func testValidationRejectsTamperedWrongSizeNotAPageAndNewerNativeRequirement() throws {
        let (manifest, data) = bundle(version: 6)
        XCTAssertNoThrow(try StudioUpdater.validate(manifest, data: data))
        XCTAssertThrowsError(try StudioUpdater.validate(manifest, data: Data("<html>tampered studioInitialized</html>".utf8)))
        let wrongSize = StudioWebManifest(version: 6, sha256: manifest.sha256, size: manifest.size + 1, minNative: 1)
        XCTAssertThrowsError(try StudioUpdater.validate(wrongSize, data: data))
        let (future, futureData) = bundle(version: 7, minNative: StudioUpdater.nativeLevel + 1)
        XCTAssertThrowsError(try StudioUpdater.validate(future, data: futureData)) { error in
            guard case StudioUpdateError.needsNewApp = error else { return XCTFail("expected needsNewApp") }
        }
        let (plain, plainData) = bundle(version: 8, body: "just some text")
        XCTAssertThrowsError(try StudioUpdater.validate(plain, data: plainData))
    }

    func testCanInstallOnlyNewerCompatibleAndNotBadVersions() {
        let newer = StudioWebManifest(version: 7, sha256: "", size: 0, minNative: 1)
        XCTAssertTrue(StudioUpdater.canInstall(newer, current: 6, bad: []))
        XCTAssertFalse(StudioUpdater.canInstall(newer, current: 7, bad: []))
        XCTAssertFalse(StudioUpdater.canInstall(newer, current: 6, bad: [7]))
        let needsNative = StudioWebManifest(version: 8, sha256: "", size: 0, minNative: StudioUpdater.nativeLevel + 1)
        XCTAssertFalse(StudioUpdater.canInstall(needsNative, current: 6, bad: []))
    }

    func testLaunchUsesNewerStoredBundleAndKeepsItOnceConfirmed() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults)
        let builtIn = try XCTUnwrap(updater.launchContent())
        XCTAssertFalse(builtIn.isUpdate)
        XCTAssertEqual(builtIn.version, 5)
        let (manifest, data) = bundle(version: 6)
        try updater.store(manifest, data: data)
        let update = try XCTUnwrap(updater.launchContent())
        XCTAssertTrue(update.isUpdate)
        XCTAssertEqual(update.version, 6)
        updater.confirmHealthy()
        let relaunch = makeUpdater(directory: directory, defaults: defaults)
        relaunch.recoverFromInterruptedLaunch()
        XCTAssertEqual(try XCTUnwrap(relaunch.launchContent()).version, 6)
        XCTAssertTrue(relaunch.badVersions().isEmpty)
    }

    func testUnconfirmedLaunchRollsBackToBuiltInAndRemembersTheBadVersion() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeUpdater(directory: directory, defaults: defaults)
        let (manifest, data) = bundle(version: 6)
        try first.store(manifest, data: data)
        XCTAssertTrue(try XCTUnwrap(first.launchContent()).isUpdate)
        // The page never confirmed itself (crash, hang, kill), so the next launch must not trust it.
        let relaunch = makeUpdater(directory: directory, defaults: defaults)
        relaunch.recoverFromInterruptedLaunch()
        let content = try XCTUnwrap(relaunch.launchContent())
        XCTAssertFalse(content.isUpdate)
        XCTAssertEqual(content.version, 5)
        XCTAssertTrue(relaunch.badVersions().contains(6))
        XCTAssertNil(relaunch.installed())
        XCTAssertFalse(StudioUpdater.canInstall(manifest, current: 5, bad: relaunch.badVersions()))
    }

    func testBuiltInWinsWhenItIsNewerThanAStoredBundle() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults, builtIn: 7)
        let (manifest, data) = bundle(version: 6)
        try updater.store(manifest, data: data)
        let content = try XCTUnwrap(updater.launchContent())
        XCTAssertFalse(content.isUpdate)
        XCTAssertEqual(content.version, 7)
    }

    func testTamperedStoredFileIsIgnored() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults)
        let (manifest, data) = bundle(version: 6)
        try updater.store(manifest, data: data)
        try Data("<html>swapped studioInitialized</html>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))
        XCTAssertNil(updater.installed())
        XCTAssertFalse(try XCTUnwrap(updater.launchContent()).isUpdate)
    }

    func testResetReturnsToTheBuiltInBundle() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults)
        let (manifest, data) = bundle(version: 6)
        try updater.store(manifest, data: data)
        XCTAssertNotNil(updater.status()["installed"])
        updater.reset()
        XCTAssertNil(updater.status()["installed"])
        XCTAssertFalse(try XCTUnwrap(updater.launchContent()).isUpdate)
    }

    private func scriptBundle(version: Int, script: String = "// claudeObserver claudeSubmit") -> (StudioWebManifest, Data, Data) {
        let page = Data("<html>update studioInitialized</html>".utf8)
        let helper = Data(script.utf8)
        let manifest = StudioWebManifest(version: version, sha256: StudioUpdater.sha256Hex(page), size: page.count, minNative: 1,
                                         observerSha256: StudioUpdater.sha256Hex(helper), observerSize: helper.count)
        return (manifest, page, helper)
    }

    func testPickReleaseKeepsTheScriptLinkWhenTheReleaseHasOne() throws {
        func asset(_ name: String, _ id: String) -> [String: Any] {
            ["name": name, "url": "https://api.github.com/repos/o/r/releases/assets/\(id)"]
        }
        let withScript: [[String: Any]] = [
            ["tag_name": "v1.0.99", "assets": [asset("studio-web.json", "m"), asset("studio-web.html", "h"), asset("studio-observer.js", "o")]]
        ]
        let withoutScript: [[String: Any]] = [
            ["tag_name": "v1.0.98", "assets": [asset("studio-web.json", "m8"), asset("studio-web.html", "h8")]]
        ]
        let newData = try JSONSerialization.data(withJSONObject: withScript)
        let oldData = try JSONSerialization.data(withJSONObject: withoutScript)
        XCTAssertEqual(StudioUpdater.pickRelease(from: newData)?.observerURL?.lastPathComponent, "o")
        XCTAssertNotNil(StudioUpdater.pickRelease(from: oldData))
        XCTAssertNil(StudioUpdater.pickRelease(from: oldData)?.observerURL)
    }

    func testScriptMustMatchItsManifestAndLookLikeOurScript() throws {
        let (manifest, page, helper) = scriptBundle(version: 6)
        XCTAssertNoThrow(try StudioUpdater.validateObserver(manifest, data: helper))
        XCTAssertThrowsError(try StudioUpdater.validateObserver(manifest, data: Data("// claudeObserver claudeSubmit!".utf8)))
        let plain = StudioWebManifest(version: 6, sha256: manifest.sha256, size: page.count, minNative: 1)
        XCTAssertThrowsError(try StudioUpdater.validateObserver(plain, data: helper))
        // Matches its own hash but is not our script.
        let foreign = Data("alert(1)".utf8)
        let foreignManifest = StudioWebManifest(version: 6, sha256: manifest.sha256, size: page.count, minNative: 1,
                                                observerSha256: StudioUpdater.sha256Hex(foreign), observerSize: foreign.count)
        XCTAssertThrowsError(try StudioUpdater.validateObserver(foreignManifest, data: foreign))
    }

    func testScriptIsStoredWithTheUpdateAndRemovedWithIt() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults)
        XCTAssertNil(updater.observerSource())
        let (manifest, page, helper) = scriptBundle(version: 6)
        try updater.store(manifest, data: page, observer: helper)
        XCTAssertEqual(updater.observerSource(), "// claudeObserver claudeSubmit")
        updater.reset()
        XCTAssertNil(updater.observerSource())
    }

    func testUpdateThatAnnouncesAScriptIsRefusedWithoutIt() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults)
        let (manifest, page, _) = scriptBundle(version: 6)
        XCTAssertThrowsError(try updater.store(manifest, data: page))
        XCTAssertNil(updater.installed())
        XCTAssertNil(updater.observerSource())
    }

    func testTamperedOrOlderStoredScriptIsNotUsed() throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = makeUpdater(directory: directory, defaults: defaults)
        let (manifest, page, helper) = scriptBundle(version: 6)
        try updater.store(manifest, data: page, observer: helper)
        try Data("alert(1)".utf8).write(to: directory.appendingPathComponent("observer.js"))
        XCTAssertNil(updater.observerSource())

        let (otherDirectory, otherDefaults) = fixture()
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        let newerBuiltIn = makeUpdater(directory: otherDirectory, defaults: otherDefaults, builtIn: 7)
        try newerBuiltIn.store(manifest, data: page, observer: helper)
        XCTAssertNil(newerBuiltIn.observerSource())
    }

    func testRedirectsStayOnGitHubHosts() {
        XCTAssertTrue(StudioUpdateNetwork.allowed(host: "api.github.com"))
        XCTAssertTrue(StudioUpdateNetwork.allowed(host: "objects.githubusercontent.com"))
        XCTAssertTrue(StudioUpdateNetwork.allowed(host: "release-assets.githubusercontent.com"))
        XCTAssertFalse(StudioUpdateNetwork.allowed(host: "evilgithub.com"))
        XCTAssertFalse(StudioUpdateNetwork.allowed(host: "github.com.evil.example"))
        XCTAssertFalse(StudioUpdateNetwork.allowed(host: nil))
    }
}
