import Foundation

@main struct BackupIntegrityTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable { var seals = 0 }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func expectRejected(_ store: GestaltFileStore, record: BackupRecord) async throws {
        do {
            _ = try await store.backupData(record)
            throw Failure(message: "Corrupt backup passed integrity checks")
        } catch is GestaltFailure {}
    }

    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        let backups = directory.appendingPathComponent("backups")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["setting": "alpha"]], format: .binary, options: 0)
        try bytes.write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: "integrity-fixture", acquire: { 1 }, release: { _ in })
        let initial = try await store.loadDevice()
        let record = try await store.backups().first!
        try expect(record.integrityVersion == 1 && record.hasTrustedIntegrity,
                   "New backups record creation-time integrity provenance")
        try expect(try await store.backupData(record) == bytes, "Unchanged backup passes verification")
        let backupURL = backups.appendingPathComponent(record.filename)
        var altered = try GestaltDocument(data: bytes)
        altered.set("omega", for: "setting")
        let replacement = try altered.encoded()
        try expect(replacement.count == record.byteCount, "Fixture replacement is a different valid plist of identical size")
        try replacement.write(to: backupURL)
        try await expectRejected(store, record: record)
        try Data(bytes.dropLast()).write(to: backupURL)
        try await expectRejected(store, record: record)
        try bytes.write(to: backupURL)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: backups.appendingPathComponent(record.id.uuidString + ".json"))) as! [String: Any]
        try expect((metadata["sha256"] as? String)?.count == 64, "New backup metadata persists a SHA-256 digest")

        // Decode the actual old schema, rather than relying only on the new
        // initializer's default argument, to verify backward compatibility.
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacyJSON.removeValue(forKey: "sha256")
        legacyJSON.removeValue(forKey: "integrityVersion")
        let legacy = try JSONDecoder().decode(BackupRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        let metadataURL = backups.appendingPathComponent(record.id.uuidString + ".json")
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: metadataURL)
        try expect(try await store.backupData(legacy) == bytes, "Legacy backups of the recorded length remain readable")
        let migrated = try JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: metadataURL))
        try expect(migrated.sha256?.count == 64, "The first legacy read persists its SHA-256 digest")
        try expect(migrated.integrityVersion == 0 && !migrated.hasTrustedIntegrity,
                   "A first-read digest does not retroactively prove legacy backup integrity")
        let trace = Trace()
        let legacyExport = try await store.backupExportData(legacy, sealingWith: { data in
            trace.seals += 1
            return data
        })
        try expect(legacyExport == bytes && trace.seals == 0,
                   "An untrusted legacy backup cannot receive device proof")
        do {
            _ = try await store.commit(try GestaltDocument(data: bytes), expected: initial, restoring: legacy)
            throw Failure(message: "An untrusted legacy backup was restored")
        } catch is GestaltFailure {}
        try replacement.write(to: backupURL)
        try await expectRejected(store, record: legacy)
        try Data(bytes.dropLast()).write(to: backupURL)
        try await expectRejected(store, record: legacy)
        try bytes.write(to: backupURL)
        var wrongDigestJSON = metadata
        wrongDigestJSON["sha256"] = String(repeating: "0", count: 64)
        let wrongDigest = try JSONDecoder().decode(BackupRecord.self, from: JSONSerialization.data(withJSONObject: wrongDigestJSON))
        try await expectRejected(store, record: wrongDigest)
        try expect(try Data(contentsOf: device) == bytes, "Rejected backup reads never modify the device")

        let baselineRoot = directory.appendingPathComponent("legacy-baseline", isDirectory: true)
        let baselineBackups = baselineRoot.appendingPathComponent("backups", isDirectory: true)
        let baselineDevice = baselineRoot.appendingPathComponent("device.plist")
        try fm.createDirectory(at: baselineBackups, withIntermediateDirectories: true)
        let legacyOriginal = try PropertyListSerialization.data(
            fromPropertyList: ["CacheExtra": ["setting": "untrusted legacy original"]],
            format: .binary, options: 0)
        let current = try PropertyListSerialization.data(
            fromPropertyList: ["CacheExtra": ["setting": "current device value"]],
            format: .binary, options: 0)
        try current.write(to: baselineDevice)
        let legacyBaseline = BackupRecord(id: UUID(), date: .distantPast, reason: "Before applying",
                                          source: .device, deviceID: "baseline-fixture",
                                          byteCount: legacyOriginal.count)
        try legacyOriginal.write(to: baselineBackups.appendingPathComponent(legacyBaseline.filename))
        try JSONEncoder().encode(legacyBaseline).write(
            to: baselineBackups.appendingPathComponent(legacyBaseline.id.uuidString + ".json"))
        let baselineStore = GestaltFileStore(deviceURL: baselineDevice, backupDirectory: baselineBackups,
                                             deviceID: "baseline-fixture", acquire: { 1 }, release: { _ in })
        let baselineSnapshot = try await baselineStore.loadDevice()
        try expect(baselineSnapshot.originalValue(for: "setting") as? String == "current device value",
                   "An untrusted legacy backup cannot supply original-value baselines")
        try expect(try await baselineStore.backups().contains(where: { $0.hasTrustedIntegrity }),
                   "An untrusted legacy record does not suppress a new trusted initial backup")

        let corruptRoot = directory.appendingPathComponent("corrupt-trusted", isDirectory: true)
        let corruptBackups = corruptRoot.appendingPathComponent("backups", isDirectory: true)
        let corruptDevice = corruptRoot.appendingPathComponent("device.plist")
        try fm.createDirectory(at: corruptBackups, withIntermediateDirectories: true)
        try bytes.write(to: corruptDevice)
        let corruptPayload = Data("not a plist".utf8)
        let corruptRecord = BackupRecord(id: UUID(), date: .distantPast, reason: "Initial backup",
                                         source: .device, deviceID: "corrupt-fixture",
                                         byteCount: corruptPayload.count,
                                         sha256: String(repeating: "0", count: 64), integrityVersion: 1)
        try corruptPayload.write(to: corruptBackups.appendingPathComponent(corruptRecord.filename))
        try JSONEncoder().encode(corruptRecord).write(
            to: corruptBackups.appendingPathComponent(corruptRecord.id.uuidString + ".json"))
        let corruptStore = GestaltFileStore(deviceURL: corruptDevice, backupDirectory: corruptBackups,
                                            deviceID: "corrupt-fixture", acquire: { 1 }, release: { _ in })
        _ = try await corruptStore.loadDevice()
        let corruptRecords = try await corruptStore.backups()
        try expect(corruptRecords.count == 2 && corruptRecords.contains(where: { $0.id != corruptRecord.id }),
                   "A corrupt record marked trusted cannot suppress a new verified initial backup")
        print("PASS: trusted provenance, corruption checks, untrusted legacy read-only migration, proof/restore/baseline rejection, corrupt-record replacement and unchanged device bytes.")
    }
}
