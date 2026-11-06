import CryptoKit
import Darwin
import Foundation
import Security

struct VaultEntry: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let content: ClipboardContent
    let savedAt: Date
    let title: String
    let isSensitive: Bool

    init(id: UUID = UUID(), content: ClipboardContent, savedAt: Date = .now,
         title: String = "", isSensitive: Bool = false) {
        self.id = id
        self.content = content
        self.savedAt = savedAt
        self.title = title
        self.isSensitive = isSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, savedAt, title, isSensitive
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        content = try values.decode(ClipboardContent.self, forKey: .content)
        savedAt = try values.decode(Date.self, forKey: .savedAt)
        // Existing encrypted vaults have neither field. Their content and identity
        // remain unchanged until the user explicitly marks an item sensitive.
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        isSensitive = try values.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Safe for menus, accessibility labels, and confirmations without revealing content.
    var displayTitle: String {
        if !trimmedTitle.isEmpty { return trimmedTitle }
        return isSensitive ? "Sensitive item" : content.menuTitle
    }

    /// Ordinary items retain their existing multi-line list preview.
    var listText: String {
        if !trimmedTitle.isEmpty { return trimmedTitle }
        return isSensitive ? "Sensitive item" : content.searchableText
    }

    /// Sensitive values must not become searchable indirectly through result presence.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if isSensitive { return displayTitle.localizedCaseInsensitiveContains(query) }
        return trimmedTitle.localizedCaseInsensitiveContains(query)
            || content.searchableText.localizedCaseInsensitiveContains(query)
    }
}

enum KeyVaultError: LocalizedError {
    case missingKey
    case invalidKey
    case corruptVault
    case fileTooLarge
    case invalidContents(String)
    case keychainUnavailable(String)
    case storageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "The Key Vault encryption key is missing from Keychain. Your saved vault has not been changed."
        case .invalidKey:
            "The Key Vault encryption key is invalid. Your saved vault has not been changed."
        case .corruptVault:
            "Key Vault could not be decrypted or its data is damaged. Your saved vault has not been changed."
        case .fileTooLarge:
            "The Key Vault file exceeds its supported size. Your saved vault has not been changed."
        case .invalidContents(let reason): reason
        case .keychainUnavailable(let reason): "Keychain is unavailable: \(reason)"
        case .storageUnavailable(let reason): "Key Vault storage is unavailable: \(reason)"
        }
    }
}

enum KeyVaultLimits {
    static let maximumCount = 500
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumTitleCharacters = 200
    static let maximumTitleBytes = 800
    // A binary plist may encode text as UTF-16. Include bounded entry metadata,
    // the file header, nonce, and authentication tag without unbounded reads.
    static let maximumEncryptedBytes = maximumBytes * 2 + 1024 * 1024

    static func validate(_ entries: [VaultEntry]) throws {
        guard entries.count <= maximumCount else {
            throw KeyVaultError.invalidContents("Key Vault can hold up to 500 items. Remove an item before saving another.")
        }
        var identifiers = Set<UUID>()
        var totalBytes = 0
        for entry in entries {
            guard identifiers.insert(entry.id).inserted, entry.savedAt.timeIntervalSince1970.isFinite else {
                throw KeyVaultError.invalidContents("Key Vault contains an invalid saved item.")
            }
            guard entry.title.count <= maximumTitleCharacters, entry.title.utf8.count <= maximumTitleBytes else {
                throw KeyVaultError.invalidContents("Saved item names can contain up to 200 characters and 800 bytes.")
            }
            switch entry.content {
            case .text(let text):
                guard !text.isEmpty, text.utf8.count <= ClipboardHistory.maximumTextBytes else {
                    throw KeyVaultError.invalidContents("Saved text must contain between 1 byte and 256 KB.")
                }
            case .image(let data, let width, let height):
                guard !data.isEmpty, data.count <= ClipboardHistory.maximumItemBytes,
                      width > 0, height > 0, width <= 16_000_000 / height else {
                    throw KeyVaultError.invalidContents("Saved images must be no larger than 8 MB and 16 megapixels.")
                }
            }
            let count = entry.content.byteCount
            guard count <= maximumBytes - totalBytes else {
                throw KeyVaultError.invalidContents("Key Vault can hold up to 20 MB. Remove an item before saving another.")
            }
            totalBytes += count
        }
    }
}

protocol KeyVaultPersistence: Sendable {
    func load() throws -> [VaultEntry]
    func save(_ entries: [VaultEntry]) throws
}

protocol KeyVaultKeyProvider: Sendable {
    func loadKey() throws -> Data?
    func storeKey(_ key: Data) throws
}

/// A local generic-password item. Keys are never synchronized or saved in files.
struct KeychainVaultKeyProvider: KeyVaultKeyProvider {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MacTools.KeyVault",
         kSecAttrAccount as String: "encryption-key-v1",
         kSecAttrSynchronizable as String: false]
    }

    func loadKey() throws -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let key = result as? Data else { throw KeyVaultError.invalidKey }
        return key
    }

    func storeKey(_ key: Data) throws {
        guard key.count == 32 else { throw KeyVaultError.invalidKey }
        var attributes = query
        attributes[kSecValueData as String] = key
        attributes[kSecAttrLabel as String] = "Mac Tools Key Vault"
        // Add only: never replace an existing key, which would orphan its vault.
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> KeyVaultError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)."
        return .keychainUnavailable(reason)
    }
}

struct EncryptedKeyVaultStore: KeyVaultPersistence {
    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("MacTools/KeyVault/vault.enc")
    }

    private struct Payload: Codable {
        let version: Int
        let entries: [VaultEntry]
    }

    private static let header = Data("MTKV1".utf8)
    private static let authenticatedContext = Data("MacTools.KeyVault.v1".utf8)
    private let fileURL: URL
    private let keyProvider: any KeyVaultKeyProvider

    init(fileURL: URL = EncryptedKeyVaultStore.defaultFileURL,
         keyProvider: any KeyVaultKeyProvider = KeychainVaultKeyProvider()) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    func load() throws -> [VaultEntry] {
        guard let encrypted = try readEncryptedFile() else { return [] }
        let key = try encryptionKey(existingVault: true)
        return try decrypt(encrypted, using: key)
    }

    func save(_ entries: [VaultEntry]) throws {
        try KeyVaultLimits.validate(entries)
        let existing = try readEncryptedFile()
        let key = try encryptionKey(existingVault: existing != nil)
        // A wrong/missing key or damaged existing vault must never be silently
        // replaced with a fresh file, including when the caller saves an empty list.
        if let existing { _ = try decrypt(existing, using: key) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        // Older builds must refuse the file rather than discard privacy metadata.
        let plaintext = try encoder.encode(Payload(version: 2, entries: entries))
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedContext)
        guard let combined = box.combined else { throw KeyVaultError.corruptVault }
        let encrypted = Self.header + combined
        guard encrypted.count <= KeyVaultLimits.maximumEncryptedBytes else { throw KeyVaultError.fileTooLarge }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).vault-tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encrypted.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Rename within the same directory is the commit point. Permissions are
        // already set, and a failed replacement leaves the prior vault intact.
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw KeyVaultError.storageUnavailable(String(cString: strerror(errno)))
        }
    }

    private func encryptionKey(existingVault: Bool) throws -> SymmetricKey {
        if let data = try keyProvider.loadKey() {
            guard data.count == 32 else { throw KeyVaultError.invalidKey }
            return SymmetricKey(data: data)
        }
        guard !existingVault else { throw KeyVaultError.missingKey }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try keyProvider.storeKey(data)
        return key
    }

    private func decrypt(_ encrypted: Data, using key: SymmetricKey) throws -> [VaultEntry] {
        guard encrypted.starts(with: Self.header) else { throw KeyVaultError.corruptVault }
        let payload: Payload
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(Self.header.count))
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.authenticatedContext)
            payload = try PropertyListDecoder().decode(Payload.self, from: plaintext)
        } catch {
            throw KeyVaultError.corruptVault
        }
        guard [1, 2].contains(payload.version) else { throw KeyVaultError.corruptVault }
        try KeyVaultLimits.validate(payload.entries)
        return payload.entries
    }

    private func readEncryptedFile() throws -> Data? {
        // Inspect the opened descriptor and cap the read, even if the file grows.
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw KeyVaultError.storageUnavailable(String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw KeyVaultError.storageUnavailable(String(cString: strerror(errno)))
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw KeyVaultError.storageUnavailable("The vault path is not a regular file.")
        }
        guard info.st_size >= 0, info.st_size <= KeyVaultLimits.maximumEncryptedBytes else {
            throw KeyVaultError.fileTooLarge
        }
        var data = Data()
        while data.count <= KeyVaultLimits.maximumEncryptedBytes {
            let allowance = min(64 * 1024, KeyVaultLimits.maximumEncryptedBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: allowance), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= KeyVaultLimits.maximumEncryptedBytes else { throw KeyVaultError.fileTooLarge }
        return data
    }
}
