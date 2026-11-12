import Foundation
import CryptoKit
import Darwin

@main struct SystemWriteRecoveryTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        private var journalBlockURL: URL?
        private var journalBlockCreated = false
        private var writeEventReplacement: (URL, Data)?
        private(set) var writes = 0

        func append(_ message: String) {
            lock.lock()
            messages.append(message)
            let blockURL = message == "Original values: fields and cache flags saved and verified"
                ? journalBlockURL : nil
            if blockURL != nil { journalBlockURL = nil }
            let replacement = message.hasPrefix("Write: ") ? writeEventReplacement : nil
            if replacement != nil { writeEventReplacement = nil }
            lock.unlock()
            if let blockURL {
                do {
                    try FileManager.default.createDirectory(at: blockURL, withIntermediateDirectories: false)
                    lock.lock(); journalBlockCreated = true; lock.unlock()
                } catch {}
            }
            if let (url, data) = replacement { try? SystemWriteRecoveryTests.replaceInPlace(data, at: url) }
        }

        func recordWrite() {
            lock.lock(); defer { lock.unlock() }
            writes += 1
        }

        func contains(_ message: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return messages.contains(message)
        }

        func blockNextJournal(at url: URL) {
            lock.lock(); defer { lock.unlock() }
            journalBlockURL = url
        }

        func didCreateJournalBlock() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return journalBlockCreated
        }

        func replaceOnNextWriteEvent(_ data: Data, at url: URL) {
            lock.lock(); defer { lock.unlock() }
            writeEventReplacement = (url, data)
        }
    }

    final class CommitBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var blocked = false
        private var reached = false
        private var timedOut = false

        func append(_ message: String) {
            lock.lock()
            let shouldBlock = message == "Recovery journal: original and intended bytes saved and synchronized" && !blocked
            if shouldBlock {
                blocked = true
                reached = true
            }
            lock.unlock()
            if shouldBlock, release.wait(timeout: .now() + 30) == .timedOut {
                lock.lock(); timedOut = true; lock.unlock()
            }
        }

        func didReach() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return reached
        }

        func didTimeOut() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        func unblock() { release.signal() }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func identity(_ url: URL) throws -> (UInt64, UInt64) {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { lstat($0!, &info) }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    static func replaceInPlace(_ data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    static func journal(original: Data, intended: Data, device: URL, deviceID: String) throws -> Data {
        let id = try identity(device)
        let record = PendingSystemWrite(version: 1, deviceID: deviceID,
                                        deviceNumber: id.0, inodeNumber: id.1,
                                        original: original, intended: intended,
                                        originalSHA256: digest(original), intendedSHA256: digest(intended))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(record)
    }

    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("GestaltX-write-recovery-" + UUID().uuidString)
        let device = root.appendingPathComponent("device.plist")
        let backups = root.appendingPathComponent("backups")
        let pending = backups.appendingPathComponent("PendingSystemWrite.plist")
        try files.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let original = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["setting": "original"]], format: .binary, options: 0)
        let intended = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["setting": "intended"]], format: .binary, options: 0)
        try original.write(to: device)
        try journal(original: original, intended: intended, device: device, deviceID: "recovery-fixture").write(to: pending)
        let tornPrefix = Data(intended.prefix(max(1, intended.count / 2)))
        try replaceInPlace(tornPrefix, at: device)

        let recovering = GestaltFileStore(deviceURL: device, backupDirectory: backups,
                                          deviceID: "recovery-fixture", acquire: { 1 }, release: { _ in })
        let recovered = try await recovering.loadDevice()
        let recoveredBytes = try Data(contentsOf: device)
        try expect(recovered.data == original && recoveredBytes == original,
                   "A cold start restores exact original bytes after a torn write")
        try expect(!files.fileExists(atPath: pending.path), "Successful recovery removes the write-ahead record")

        try journal(original: original, intended: intended, device: device, deviceID: "recovery-fixture").write(to: pending)
        try replaceInPlace(intended, at: device)
        let committed = try await recovering.loadDevice()
        let committedBytes = try Data(contentsOf: device)
        try expect(committed.data == intended && committedBytes == intended,
                   "A cold start retains a fully committed intended write")
        try expect(!files.fileExists(atPath: pending.path), "Committed recovery removes the write-ahead record")

        try replaceInPlace(original, at: device)
        try journal(original: original, intended: intended, device: device, deviceID: "recovery-fixture").write(to: pending)
        let thirdState = try PropertyListSerialization.data(
            fromPropertyList: ["CacheExtra": ["setting": "independent same-inode update"]],
            format: .binary, options: 0)
        let thirdIdentity = try identity(device)
        try replaceInPlace(thirdState, at: device)
        try expect(try identity(device) == thirdIdentity, "The third-state fixture preserves the system inode")
        do {
            _ = try await recovering.loadDevice()
            throw Failure(message: "An unrecognized same-inode state was overwritten")
        } catch is GestaltFailure {}
        try expect(try Data(contentsOf: device) == thirdState,
                   "Cold-start recovery preserves an unrecognized valid same-inode plist")
        try expect(files.fileExists(atPath: pending.path),
                   "Unrecognized same-inode recovery retains its journal evidence")
        try files.removeItem(at: pending)
        try replaceInPlace(original, at: device)

        let staleJournal = try journal(original: original, intended: intended, device: device, deviceID: "recovery-fixture")
        try staleJournal.write(to: pending)
        try files.removeItem(at: device)
        let replacement = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["setting": "system replacement"]], format: .binary, options: 0)
        try replacement.write(to: device)
        do {
            _ = try await recovering.loadDevice()
            throw Failure(message: "A replacement inode was overwritten")
        } catch is GestaltFailure {}
        let replacementBytes = try Data(contentsOf: device)
        try expect(replacementBytes == replacement,
                   "Recovery never overwrites a replacement inode")
        try expect(files.fileExists(atPath: pending.path),
                   "A blocked recovery retains its evidence for manual handling")

        let racedDevice = root.appendingPathComponent("raced-device.plist")
        let racedBackups = root.appendingPathComponent("raced-backups")
        let parkedOriginal = root.appendingPathComponent("parked-original.plist")
        let liveReplacement = try PropertyListSerialization.data(
            fromPropertyList: ["CacheExtra": ["setting": "concurrent replacement"]],
            format: .binary, options: 0)
        try original.write(to: racedDevice)
        let racedStore = GestaltFileStore(
            deviceURL: racedDevice, backupDirectory: racedBackups,
            deviceID: "replacement-fixture", acquire: { 1 }, release: { _ in },
            writeData: { _, url in
                try files.moveItem(at: url, to: parkedOriginal)
                try liveReplacement.write(to: url)
            })
        let racedSnapshot = try await racedStore.loadDevice()
        var racedEdit = racedSnapshot.document
        racedEdit.set("requested edit", for: "setting")
        do {
            _ = try await racedStore.commit(racedEdit, expected: racedSnapshot)
            throw Failure(message: "A concurrently replaced system path was accepted")
        } catch is GestaltFailure {}
        try expect(try Data(contentsOf: racedDevice) == liveReplacement,
                   "Rollback never overwrites a concurrently published replacement")
        try expect(try Data(contentsOf: parkedOriginal) == original,
                   "The displaced original inode remains unchanged")
        try expect(files.fileExists(atPath: racedBackups.appendingPathComponent("PendingSystemWrite.plist").path),
                   "An unresolved path replacement retains its recovery journal")

        let sameInodeDevice = root.appendingPathComponent("same-inode-device.plist")
        let sameInodeBackups = root.appendingPathComponent("same-inode-backups")
        try original.write(to: sameInodeDevice)
        let sameInodeTrace = Trace()
        let sameInodeStore = GestaltFileStore(
            deviceURL: sameInodeDevice, backupDirectory: sameInodeBackups,
            deviceID: "same-inode-fixture", acquire: { 1 }, release: { _ in },
            eventSink: { sameInodeTrace.append($0) })
        let sameInodeSnapshot = try await sameInodeStore.loadDevice()
        var sameInodeEdit = sameInodeSnapshot.document
        sameInodeEdit.set("requested edit", for: "setting")
        sameInodeTrace.replaceOnNextWriteEvent(thirdState, at: sameInodeDevice)
        let beforeRaceIdentity = try identity(sameInodeDevice)
        do {
            _ = try await sameInodeStore.commit(sameInodeEdit, expected: sameInodeSnapshot)
            throw Failure(message: "A last-moment same-inode update passed the built-in writer")
        } catch is GestaltFailure {}
        try expect(try identity(sameInodeDevice) == beforeRaceIdentity,
                   "The last-moment race changes bytes without replacing the inode")
        try expect(try Data(contentsOf: sameInodeDevice) == thirdState,
                   "The built-in writer preserves a last-moment same-inode update")
        try expect(files.fileExists(atPath: sameInodeBackups.appendingPathComponent("PendingSystemWrite.plist").path),
                   "The rejected same-inode race retains its recovery journal")

        let blockedDevice = root.appendingPathComponent("blocked-device.plist")
        let blockedBackups = root.appendingPathComponent("blocked-backups")
        try original.write(to: blockedDevice)
        let trace = Trace()
        let blockedStore = GestaltFileStore(
            deviceURL: blockedDevice, backupDirectory: blockedBackups,
            deviceID: "journal-fixture", acquire: { 1 }, release: { _ in },
            writeData: { _, _ in trace.recordWrite() }, eventSink: { trace.append($0) })
        let blockedSnapshot = try await blockedStore.loadDevice()
        trace.blockNextJournal(at: blockedBackups.appendingPathComponent("PendingSystemWrite.plist"))
        var blockedEdit = blockedSnapshot.document
        blockedEdit.set("requested edit", for: "setting")
        var journalFailureObserved = false
        do {
            _ = try await blockedStore.commit(blockedEdit, expected: blockedSnapshot)
        } catch {
            journalFailureObserved = true
        }
        try expect(journalFailureObserved, "A missing recovery journal must reject the commit")
        try expect(trace.didCreateJournalBlock(),
                   "Inject the journal failure after pre-write backup and original-value persistence")
        try expect(trace.writes == 0, "A journal failure stops before invoking the system writer")
        try expect(!trace.contains("Recovery: restoring previous bytes"),
                   "A failure before the system write does not rewrite unchanged device bytes")
        try expect(try Data(contentsOf: blockedDevice) == original,
                   "A journal failure leaves the device bytes unchanged")

        let serializedDevice = root.appendingPathComponent("serialized-device.plist")
        let serializedBackups = root.appendingPathComponent("serialized-backups")
        try original.write(to: serializedDevice)
        let barrier = CommitBarrier()
        let firstStore = GestaltFileStore(
            deviceURL: serializedDevice, backupDirectory: serializedBackups,
            deviceID: "serialized-fixture", acquire: { 1 }, release: { _ in },
            eventSink: { barrier.append($0) })
        let secondStore = GestaltFileStore(
            deviceURL: serializedDevice, backupDirectory: serializedBackups,
            deviceID: "serialized-fixture", acquire: { 1 }, release: { _ in })
        let firstSnapshot = try await firstStore.loadDevice()
        let secondSnapshot = try await secondStore.loadDevice()
        var firstEdit = firstSnapshot.document
        firstEdit.set("first serialized writer", for: "setting")
        var secondEdit = secondSnapshot.document
        secondEdit.set("second serialized writer", for: "setting")
        let firstTask = Task { try await firstStore.commit(firstEdit, expected: firstSnapshot) }
        var barrierReleased = false
        defer {
            if !barrierReleased { barrier.unblock() }
        }
        var barrierReached = false
        for _ in 0..<500 {
            if barrier.didReach() { barrierReached = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(barrierReached, "The first writer publishes its journal while holding the file lock")
        do {
            _ = try await secondStore.commit(secondEdit, expected: secondSnapshot)
            throw Failure(message: "A second writer entered while the first journal was active")
        } catch is GestaltFailure {}
        try expect(!barrier.didTimeOut(), "The first writer must remain blocked until the test releases it")
        let serializedPending = serializedBackups.appendingPathComponent("PendingSystemWrite.plist")
        let activeJournal = try PropertyListDecoder().decode(
            PendingSystemWrite.self, from: Data(contentsOf: serializedPending))
        try expect(activeJournal.intended == (try firstEdit.encoded()),
                   "A rejected second writer cannot replace the active recovery journal")
        barrier.unblock()
        barrierReleased = true
        let firstCommit = try await firstTask.value
        try expect(firstCommit.document.matches(firstEdit),
                   "The lock owner completes after the competing writer is rejected")
        try expect(!files.fileExists(atPath: serializedPending.path),
                   "Only the lock owner clears its recovery journal")
        print("PASS: strict-prefix recovery, committed retention, unknown-state preservation, path/inode race refusal, serialized journals and durable recovery evidence.")
    }
}
