import CryptoKit
import Foundation
import XCTest
@testable import MacTools

final class KeyVaultTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("vault.enc") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/MacToolsKeyVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testEmptyVaultDoesNotCreateKeyOrFile() throws {
        let provider = FixtureVaultKeys()
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(provider.loadCount, 0)
        XCTAssertEqual(provider.storeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSavedTextAndImageSurviveStoreRecreationWithoutPlaintextFiles() throws {
        let provider = FixtureVaultKeys()
        let text = "A saved clipboard secret with enough unique bytes for this encryption test."
        let entries = [VaultEntry(content: .text(text)),
                       VaultEntry(content: .image(Data(repeating: 0x89, count: 100), width: 10, height: 10))]
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        try store.save(entries)
        XCTAssertEqual(provider.storeCount, 1)
        XCTAssertEqual(provider.key?.count, 32)
        let encrypted = try Data(contentsOf: fileURL)
        XCTAssertNil(encrypted.range(of: Data(text.utf8)))
        XCTAssertFalse(encrypted.starts(with: Data("bplist".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["vault.enc"])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let restarted = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        XCTAssertEqual(try restarted.load(), entries)
        try restarted.save(Array(entries.prefix(1)))
        XCTAssertEqual(try store.load(), Array(entries.prefix(1)))
        XCTAssertEqual(provider.storeCount, 1)
    }

    func testLegacyEncryptedVaultLoadsWithoutMetadataAndCanSaveSensitiveMetadata() throws {
        struct LegacyEntry: Encodable {
            let id: UUID
            let content: ClipboardContent
            let savedAt: Date
        }
        struct LegacyPayload: Encodable {
            let version: Int
            let entries: [LegacyEntry]
        }
        let id = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let content = ClipboardContent.text("existing saved text")
        let key = Data(repeating: 0x53, count: 32)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(LegacyPayload(version: 1, entries: [
            LegacyEntry(id: id, content: content, savedAt: savedAt)
        ]))
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                      authenticating: Data("MacTools.KeyVault.v1".utf8))
        try (Data("MTKV1".utf8) + XCTUnwrap(sealed.combined)).write(to: fileURL)

        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: FixtureVaultKeys(key: key))
        let legacy = try XCTUnwrap(store.load().first)
        XCTAssertEqual(legacy, VaultEntry(id: id, content: content, savedAt: savedAt))
        XCTAssertFalse(legacy.isSensitive)
        XCTAssertEqual(legacy.title, "")

        let updated = VaultEntry(id: id, content: content, savedAt: savedAt, title: "Work credential", isSensitive: true)
        try store.save([updated])
        XCTAssertEqual(try store.load(), [updated])
    }

    func testSensitiveMetadataRoundTripsInsideEncryptedPayload() throws {
        let provider = FixtureVaultKeys()
        let entries = [
            VaultEntry(content: .text("private test value"), title: "Named private item", isSensitive: true),
            VaultEntry(content: .image(Data(repeating: 0x89, count: 100), width: 10, height: 10),
                       title: "Private image", isSensitive: true),
            VaultEntry(content: .text("ordinary item"), title: "Public label")
        ]
        try EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider).save(entries)
        let encrypted = try Data(contentsOf: fileURL)
        let key = SymmetricKey(data: try XCTUnwrap(provider.key))
        let sealed = try AES.GCM.SealedBox(combined: encrypted.dropFirst(5))
        let plaintext = try AES.GCM.open(sealed, using: key, authenticating: Data("MacTools.KeyVault.v1".utf8))
        let payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: plaintext, format: nil) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 2, "Older builds must reject saves containing privacy metadata.")
        for value in ["private test value", "Named private item", "Private image", "Public label"] {
            XCTAssertNil(encrypted.range(of: Data(value.utf8)))
        }
        let restarted = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        XCTAssertEqual(try restarted.load(), entries)
    }

    func testSensitiveDisplayAndSearchNeverUseContent() {
        let secret = "a-private-value-unrelated-to-the-name"
        let named = VaultEntry(content: .text(secret), title: "  Office access\n", isSensitive: true)
        XCTAssertEqual(named.displayTitle, "Office access")
        XCTAssertEqual(named.listText, "Office access")
        XCTAssertTrue(named.matches("OFFICE"))
        XCTAssertTrue(named.matches(""))
        XCTAssertFalse(named.matches(secret))
        XCTAssertFalse(named.matches("private-value"))

        let unnamed = VaultEntry(content: .text(secret), title: " \n", isSensitive: true)
        XCTAssertEqual(unnamed.displayTitle, "Sensitive item")
        XCTAssertEqual(unnamed.listText, "Sensitive item")
        XCTAssertTrue(unnamed.matches("sensitive"))
        XCTAssertFalse(unnamed.matches(secret))

        let image = VaultEntry(content: .image(Data([1]), width: 123, height: 456), isSensitive: true)
        XCTAssertEqual(image.listText, "Sensitive item")
        XCTAssertFalse(image.matches("123"))
    }

    func testOrdinaryItemsRetainContentSearchAndListPreview() {
        let unnamed = VaultEntry(content: .text("first line\nsecond line"))
        XCTAssertEqual(unnamed.displayTitle, "first line second line")
        XCTAssertEqual(unnamed.listText, "first line\nsecond line")
        XCTAssertTrue(unnamed.matches("SECOND"))

        let named = VaultEntry(content: .text("searchable ordinary value"), title: "Reference")
        XCTAssertEqual(named.listText, "Reference")
        XCTAssertTrue(named.matches("reference"))
        XCTAssertTrue(named.matches("ordinary"))
        XCTAssertFalse(named.matches("absent"))
    }

    func testNameLimitsRejectOversizedMetadataBeforeKeyAccess() throws {
        let provider = FixtureVaultKeys()
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        XCTAssertNoThrow(try KeyVaultLimits.validate([
            VaultEntry(content: .text("value"), title: String(repeating: "a", count: 200))
        ]))
        XCTAssertThrowsError(try store.save([
            VaultEntry(content: .text("value"), title: String(repeating: "a", count: 201))
        ]))
        // Multi-scalar graphemes remain subject to the separate encoded byte cap.
        let largeGraphemes = String(repeating: "👩‍💻", count: 100)
        XCTAssertEqual(largeGraphemes.count, 100)
        XCTAssertGreaterThan(largeGraphemes.utf8.count, 800)
        XCTAssertThrowsError(try store.save([
            VaultEntry(content: .text("value"), title: largeGraphemes, isSensitive: true)
        ]))
        XCTAssertEqual(provider.loadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMissingKeyNeverRegeneratesOrReplacesExistingVault() throws {
        let originalKeys = FixtureVaultKeys()
        try EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: originalKeys)
            .save([VaultEntry(content: .text("keep this saved item"))])
        let original = try Data(contentsOf: fileURL)
        let missing = FixtureVaultKeys()
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: missing)
        XCTAssertThrowsError(try store.load()) { error in
            guard case KeyVaultError.missingKey = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(missing.storeCount, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testWrongKeyAndTamperedCiphertextCannotBeReplaced() throws {
        let provider = FixtureVaultKeys(key: Data(repeating: 0x11, count: 32))
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        try store.save([VaultEntry(content: .text("authenticated saved content"))])
        let original = try Data(contentsOf: fileURL)
        let wrongKeys = FixtureVaultKeys(key: Data(repeating: 0x22, count: 32))
        let wrongStore = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: wrongKeys)
        XCTAssertThrowsError(try wrongStore.load())
        XCTAssertThrowsError(try wrongStore.save([]))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)

        var damaged = original
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: fileURL), damaged)
        XCTAssertEqual(provider.storeCount, 0)
    }

    func testDeniedOrInvalidKeyCannotFallBackToPlaintext() throws {
        for provider in [FixtureVaultKeys(denyLoad: true), FixtureVaultKeys(denyStore: true),
                         FixtureVaultKeys(key: Data(repeating: 1, count: 16))] {
            let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
            XCTAssertThrowsError(try store.save([VaultEntry(content: .text("must remain private"))]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testPlaintextAndMalformedEncryptedPayloadAreRejectedWithoutChanges() throws {
        let key = Data(repeating: 0x44, count: 32)
        let provider = FixtureVaultKeys(key: key)
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        let plain = Data("[{\"content\":\"plaintext is not supported\"}]".utf8)
        try plain.write(to: fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: fileURL), plain)

        let encrypted = try AES.GCM.seal(Data("not a vault payload".utf8), using: SymmetricKey(data: key),
                                         authenticating: Data("MacTools.KeyVault.v1".utf8))
        let malformed = Data("MTKV1".utf8) + (try XCTUnwrap(encrypted.combined))
        try malformed.write(to: fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
    }

    func testLimitsRejectCountBytesAndInvalidContentBeforeWriting() throws {
        let provider = FixtureVaultKeys()
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        let countLimit = (0..<KeyVaultLimits.maximumCount).map { VaultEntry(content: .text("item \($0)")) }
        XCTAssertNoThrow(try KeyVaultLimits.validate(countLimit))
        XCTAssertThrowsError(try store.save(countLimit + [VaultEntry(content: .text("one too many"))]))
        let image = ClipboardContent.image(Data(repeating: 1, count: 8 * 1024 * 1024), width: 1000, height: 1000)
        XCTAssertThrowsError(try store.save([VaultEntry(content: image), VaultEntry(content: image), VaultEntry(content: image)]))
        XCTAssertThrowsError(try store.save([VaultEntry(content: .text(""))]))
        XCTAssertThrowsError(try store.save([VaultEntry(content: .text(String(repeating: "a", count: 256 * 1024 + 1)))]))
        XCTAssertThrowsError(try store.save([VaultEntry(content: .image(Data([1]), width: 0, height: 1))]))
        let duplicate = VaultEntry(content: .text("duplicate identifier"))
        XCTAssertThrowsError(try store.save([duplicate, duplicate]))
        XCTAssertEqual(provider.loadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEncryptedFileReadIsBoundedBeforeKeyAccess() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let file = try FileHandle(forWritingTo: fileURL)
        try file.truncate(atOffset: UInt64(KeyVaultLimits.maximumEncryptedBytes + 1))
        try file.close()
        let provider = FixtureVaultKeys()
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        XCTAssertThrowsError(try store.load()) { error in
            guard case KeyVaultError.fileTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(provider.loadCount, 0)
        XCTAssertEqual(provider.storeCount, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, KeyVaultLimits.maximumEncryptedBytes + 1)
    }

    func testSymbolicLinkVaultIsRefusedWithoutChangingTarget() throws {
        let target = directory.appendingPathComponent("keep.txt")
        let original = Data("untouched".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)
        let provider = FixtureVaultKeys()
        let store = EncryptedKeyVaultStore(fileURL: fileURL, keyProvider: provider)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(provider.loadCount, 0)
    }
}

private final class FixtureVaultKeys: KeyVaultKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var loads = 0
    private var stores = 0
    private let denyLoad: Bool
    private let denyStore: Bool

    init(key: Data? = nil, denyLoad: Bool = false, denyStore: Bool = false) {
        storedKey = key
        self.denyLoad = denyLoad
        self.denyStore = denyStore
    }

    var key: Data? { lock.withLock { storedKey } }
    var loadCount: Int { lock.withLock { loads } }
    var storeCount: Int { lock.withLock { stores } }

    func loadKey() throws -> Data? {
        try lock.withLock {
            loads += 1
            if denyLoad { throw KeyVaultError.keychainUnavailable("Fixture access denied.") }
            return storedKey
        }
    }

    func storeKey(_ key: Data) throws {
        try lock.withLock {
            stores += 1
            if denyStore { throw KeyVaultError.keychainUnavailable("Fixture access denied.") }
            storedKey = key
        }
    }
}
