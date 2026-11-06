import Foundation
import Security

public protocol CredentialStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct KeychainStorage: CredentialStorage {
    // No custom access group or bundle-ID assumptions; guest access still depends on the host.
    private let service = "TVPair.RemotePairing.v1"
    private let account = "credential-vault"
    public init() {}
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    public static func check(_ status: OSStatus, allowMissing: Bool = false) throws {
        guard status == errSecSuccess || (allowMissing && status == errSecItemNotFound) else { throw TVPairError.keychain(status) }
    }
    public func load() throws -> Data? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        try Self.check(status, allowMissing: true)
        if status == errSecItemNotFound { return nil }
        guard let data = output as? Data else { throw TVPairError.storage }; return data
    }
    public func save(_ data: Data) throws {
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; changes.forEach { item[$0.key] = $0.value }
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else { try Self.check(status) }
    }
    public func delete() throws { try Self.check(SecItemDelete(query as CFDictionary), allowMissing: true) }
}

public struct ProtectedFileStorage: CredentialStorage {
    private let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("credentials.protected") }
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try Data(contentsOf: url) } catch { throw TVPairError.storage }
    }
    public func save(_ data: Data) throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var excluded = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { throw TVPairError.storage }
    }
    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch { throw TVPairError.storage }
    }
}

/// No in-memory update occurs until the backend has committed the new vault.
public actor CredentialVault {
    private var storage: any CredentialStorage
    private var records: [PairingRecord] = []
    private var loaded = false
    public init(storage: any CredentialStorage = KeychainStorage()) { self.storage = storage }
    public func load() throws -> [SavedDevice] {
        do {
            if let data = try storage.load() {
                let decoded = try JSONDecoder().decode([PairingRecord].self, from: data)
                guard decoded.count <= 100 else { throw TVPairError.storage }
                try decoded.forEach { try $0.validate() }; records = decoded
            } else { records = [] }
            loaded = true; return records.map(\.summary)
        } catch let error as TVPairError { throw error }
        catch { throw TVPairError.storage }
    }
    public func save(_ record: PairingRecord) throws -> [SavedDevice] {
        if !loaded { _ = try load() }
        try record.validate()
        var updated = records; updated.removeAll { $0.id == record.id }
        guard updated.count < 100 else { throw TVPairError.storage }
        updated.append(record)
        try storage.save(JSONEncoder().encode(updated)); records = updated
        return records.map(\.summary)
    }
    public func record(id: UUID) throws -> PairingRecord {
        if !loaded { _ = try load() }
        guard let value = records.first(where: { $0.id == id }) else { throw TVPairError.invalidRecord("record not found") }; return value
    }
    public func delete(id: UUID) throws -> [SavedDevice] {
        if !loaded { _ = try load() }
        let updated = records.filter { $0.id != id }
        if updated.isEmpty { try storage.delete() } else { try storage.save(JSONEncoder().encode(updated)) }
        records = updated; return records.map(\.summary)
    }
    public func selectProtectedFile(directory: URL, explicitConsent: Bool) throws -> [SavedDevice] {
        guard explicitConsent else { throw TVPairError.storage }
        // Storage namespaces are separate. Never silently migrate or erase the Keychain vault.
        let previous = storage, oldRecords = records, wasLoaded = loaded
        storage = ProtectedFileStorage(directory: directory); loaded = false
        do { return try load() }
        catch { storage = previous; records = oldRecords; loaded = wasLoaded; throw error }
    }
}
