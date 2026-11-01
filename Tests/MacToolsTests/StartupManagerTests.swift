import XCTest
@testable import MacTools

final class StartupManagerTests: XCTestCase {
    func testBinaryAndXMLConfigurationsPreserveRealProgramAndTrigger() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "org.example.backup", "ProgramArguments": ["/Applications/Backup.app/Contents/MacOS/Backup", "--quiet"], "RunAtLoad": true], format: format, options: 0)
            let item = try StartupManager.parse(data, url: URL(fileURLWithPath: "/example.plist"), scope: .user)
            XCTAssertEqual(item.label, "org.example.backup")
            XCTAssertEqual(item.program, "/Applications/Backup.app/Contents/MacOS/Backup")
            XCTAssertEqual(item.trigger, "At sign-in")
            XCTAssertFalse(item.disabledInFile)
        }
    }

    func testSystemStartupAndDisabledFileAreConfigurationNotLiveState() throws {
        let item = try parse(["Label": "org.example.daemon", "Program": "/usr/local/bin/daemon", "ProgramArguments": ["ignored"], "RunAtLoad": true, "Disabled": true], scope: .system)
        XCTAssertEqual(item.program, "/usr/local/bin/daemon")
        XCTAssertEqual(item.trigger, "At startup")
        XCTAssertTrue(item.disabledInFile)
    }

    func testEventTriggersHaveUsefulNames() throws {
        XCTAssertEqual(try parse(["Label": "a", "KeepAlive": ["SuccessfulExit": false]]).trigger, "Keep alive")
        XCTAssertEqual(try parse(["Label": "a", "StartInterval": 3600]).trigger, "Scheduled")
        XCTAssertEqual(try parse(["Label": "a", "WatchPaths": ["/tmp/example"]]).trigger, "On changes")
        XCTAssertEqual(try parse(["Label": "a", "MachServices": ["org.example": true]]).trigger, "On demand")
    }

    func testMalformedMissingAndOversizedConfigurationsAreRejected() throws {
        XCTAssertThrowsError(try StartupManager.parse(Data("invalid".utf8), url: URL(fileURLWithPath: "/bad.plist"), scope: .user))
        XCTAssertThrowsError(try parse(["RunAtLoad": true]))
        XCTAssertThrowsError(try parse(["Label": " \n"]))
        XCTAssertThrowsError(try StartupManager.parse(Data(repeating: 0, count: StartupManager.maximumFileBytes + 1), url: URL(fileURLWithPath: "/big.plist"), scope: .user))
    }

    func testInventoryReadsOnlyPlistsAndReportsSymlinksAndMalformedFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try data(["Label": "org.example.valid", "RunAtLoad": true]).write(to: root.appendingPathComponent("valid.plist"))
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("bad.plist"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.plist"), withDestinationURL: root.appendingPathComponent("valid.plist"))
        let result = try await StartupManager(locations: [StartupLocation(url: root, scope: .allUsers)]).inventory()
        XCTAssertEqual(result.items.map(\.label), ["org.example.valid"])
        XCTAssertEqual(result.items.first?.scope, .allUsers)
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("valid.plist").path))
    }

    func testDirectoryLimitIsVisibleAndMissingLocationIsNormal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 { try data(["Label": "org.example.\(index)"]).write(to: root.appendingPathComponent("\(index).plist")) }
        let result = try await StartupManager(locations: [StartupLocation(url: root, scope: .user), StartupLocation(url: root.appendingPathComponent("missing"), scope: .user)], maximumEntriesPerLocation: 1).inventory()
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("limit"))
    }

    func testSymbolicLinkDirectoryIsNotFollowed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try data(["Label": "org.example"]).write(to: actual.appendingPathComponent("item.plist"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let result = try await StartupManager(locations: [StartupLocation(url: link, scope: .user)]).inventory()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    private func parse(_ property: [String: Any], scope: StartupScope = .user) throws -> StartupItem {
        try StartupManager.parse(data(property), url: URL(fileURLWithPath: "/example.plist"), scope: scope)
    }
    private func data(_ property: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: property, format: .xml, options: 0)
    }
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/MacTools-StartupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

@MainActor
final class StartupManagerModelTests: XCTestCase {
    func testDemoFilteringUsesLabelsProgramsAndScopes() async throws {
        let model = StartupManagerModel(isDemo: true)
        model.refresh()
        for _ in 0..<100 {
            if !model.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.items.count, 3)
        model.query = "Cloud Sync"
        XCTAssertEqual(model.filteredItems.count, 1)
        model.scope = .system
        XCTAssertTrue(model.filteredItems.isEmpty)
        model.query = ""
        XCTAssertEqual(model.filteredItems.count, 1)
        model.shutdown()
    }

    func testShutdownRejectsLateInventory() async throws {
        let source = StartupGate()
        let model = StartupManagerModel(isDemo: false, inventory: { await source.read() })
        model.refresh()
        for _ in 0..<100 {
            if await source.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.shutdown()
        await source.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.items.isEmpty)
    }
}

private actor StartupGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<StartupInventory, Never>?
    func read() async -> StartupInventory {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: StartupInventory(items: [], issues: []))
        continuation = nil
    }
}
