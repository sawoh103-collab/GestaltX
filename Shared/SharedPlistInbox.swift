// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

fileprivate struct SharedFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t
    let generation: UInt64

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        fileType = info.st_mode & S_IFMT
        generation = UInt64(info.st_gen)
    }
}

private struct SharedDirectoryEntry: Sendable {
    let name: String
    let identity: SharedFileIdentity
}

struct SharedPlistError: LocalizedError {
    let key: String
    let retryable: Bool
    init(key: String, retryable: Bool = false) { self.key = key; self.retryable = retryable }
    var errorDescription: String? { NSLocalizedString(key, comment: "") }

    static func canRetry(_ error: Error, depth: Int = 0) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? SharedPlistError { return error.retryable }
        guard depth < 8 else { return false }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain,
           [EACCES, EPERM, EBUSY, EAGAIN, EINTR, EMFILE, ENFILE, ETIMEDOUT].contains(where: { Int($0) == error.code }) { return true }
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileLocking.rawValue,
            CocoaError.userCancelled.rawValue].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return canRetry(underlying, depth: depth + 1)
        }
        return false
    }
}

struct SharedPlistEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let created: Date
    let byteCount: Int

    // These are runtime capabilities, not metadata. Persisting them in
    // entry.json would let an untrusted queue item choose its own identity.
    fileprivate let queueIdentity: SharedFileIdentity?
    fileprivate let directoryIdentity: SharedFileIdentity?

    private enum CodingKeys: String, CodingKey {
        case id, name, created, byteCount
    }

    init(id: UUID, name: String, created: Date, byteCount: Int) {
        self.init(id: id, name: name, created: created, byteCount: byteCount,
                  queueIdentity: nil, directoryIdentity: nil)
    }

    fileprivate init(id: UUID, name: String, created: Date, byteCount: Int,
                     queueIdentity: SharedFileIdentity?, directoryIdentity: SharedFileIdentity?) {
        self.id = id
        self.name = name
        self.created = created
        self.byteCount = byteCount
        self.queueIdentity = queueIdentity
        self.directoryIdentity = directoryIdentity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  name: try values.decode(String.self, forKey: .name),
                  created: try values.decode(Date.self, forKey: .created),
                  byteCount: try values.decode(Int.self, forKey: .byteCount))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(created, forKey: .created)
        try values.encode(byteCount, forKey: .byteCount)
    }

    fileprivate func pinned(queue: SharedFileIdentity, directory: SharedFileIdentity) -> SharedPlistEntry {
        SharedPlistEntry(id: id, name: name, created: created, byteCount: byteCount,
                         queueIdentity: queue, directoryIdentity: directory)
    }
}

struct SharedPlistInbox: Sendable {
    static let maximumByteCount = 16 * 1024 * 1024
    private static let maximumMetadataByteCount = 4096
    let directory: URL
    private let container: URL
    private let namespace: String

    init(container: URL, namespace: String) throws {
        guard !namespace.isEmpty, namespace.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }), namespace != ".", namespace != ".." else { throw Self.invalidQueue }
        self.container = container
        self.namespace = namespace
        directory = container.appendingPathComponent("GestaltX/ShareInbox", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static var invalidQueue: SharedPlistError {
        SharedPlistError(key: "The shared plist could not be read. Share it again.")
    }

    private static var changedQueue: NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumByteCount else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw SharedPlistError(key: "Choose a MobileGestalt plist with a CacheExtra dictionary.")
        }
        if root["CacheExtra"] is [String: Any] { return }
        // A v2 device backup intentionally exposes no MobileGestalt fields. The
        // main app authenticates and decrypts it with a device-only Keychain key.
        guard root.count == 1,
              let proof = root["GestaltXDeviceProof"] as? [String: Any],
              proof["version"] as? Int == 2,
              proof["algorithm"] as? String == "AES.GCM.256",
              let sealed = proof["sealed"] as? Data,
              sealed.count >= 28, sealed.count <= maximumByteCount else {
            throw SharedPlistError(key: "Choose a MobileGestalt plist with a CacheExtra dictionary.")
        }
    }

    // Read within the item-provider callback, while its temporary URL is valid.
    static func readDocument(at url: URL, coordinator: NSFileCoordinator = NSFileCoordinator()) throws -> Data {
        guard url.isFileURL else { throw invalidQueue }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Coordination itself can wait on a FIFO before invoking the accessor.
        // Reject known special files first, but let File Providers materialize
        // missing placeholders or supply a different URL during coordination.
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard status != 0 || (info.st_mode & S_IFMT) == S_IFREG else { throw invalidQueue }
        // A security scope grants access, while coordination asks File Providers
        // to materialize their document and keeps concurrent changes out of the read.
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let data = try readLimited(readableURL, limit: maximumByteCount)
                try validate(data)
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw invalidQueue }
        return try result.get()
    }

    static func readDocumentAsync(at url: URL, coordinator: NSFileCoordinator = NSFileCoordinator()) async throws -> Data {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await SharedPlistReadJob(coordinator).run { try readDocument(at: url, coordinator: $0) }
    }

    func readAsync(_ entry: SharedPlistEntry) async throws -> Data {
        try await SharedPlistReadJob(NSFileCoordinator()).run { _ in try read(entry) }
    }

    private static func readLimited(_ url: URL, limit: Int) throws -> Data {
        // Open without waiting for a writer and check the opened descriptor, not
        // just the path: a FIFO must not block the app while scanning its inbox.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        return try readLimited(descriptor: descriptor, limit: limit)
    }

    private static func readLimited(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        try readLimited(descriptor: openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC), limit: limit)
    }

    private static func readLimited(descriptor: Int32, limit: Int) throws -> Data {
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw invalidQueue }
        var data = Data()
        while true {
            let part = try handle.read(upToCount: min(64 * 1024, limit - data.count + 1)) ?? Data()
            if part.isEmpty { return data }
            guard part.count <= limit - data.count else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
            data.append(part)
        }
    }

    func enqueue(_ data: Data, name: String) throws -> SharedPlistEntry {
        try enqueue(data, name: name, beforePublish: nil)
    }

    func enqueue(_ data: Data, name: String,
                 beforePublish: ((String) -> Void)?) throws -> SharedPlistEntry {
        try Self.validate(data)
        cleanupStaleEntries()
        guard let parent = try openDirectory(create: true) else { throw Self.invalidQueue }
        defer { close(parent) }
        let queueIdentity = try Self.directoryIdentity(of: parent)
        let id = UUID()
        let entry = SharedPlistEntry(id: id, name: Self.displayName(name),
                                    created: Date(), byteCount: data.count)
        let metadata = try JSONEncoder().encode(entry)
        guard metadata.count <= Self.maximumMetadataByteCount else { throw Self.invalidQueue }
        let staging = "." + id.uuidString + ".pending"
        var stagingIdentity: SharedFileIdentity?
        var published = false
        do {
            guard mkdirat(parent, staging, 0o700) == 0 else { throw Self.fileError() }
            let createdIdentity = try Self.pathIdentity(of: staging, in: parent)
            guard createdIdentity.fileType == S_IFDIR else { throw Self.invalidQueue }
            stagingIdentity = createdIdentity
            let stagingDirectory = try Self.openChild(staging, in: parent, expected: createdIdentity)
            defer { close(stagingDirectory) }
            let lease = try SharedInboxHousekeeping.writerLock(in: stagingDirectory)
            defer { close(lease) }
            try Self.write(data, named: "document.plist", in: stagingDirectory)
            try Self.write(metadata, named: "entry.json", in: stagingDirectory)
            beforePublish?(staging)
            try Self.verifyPath(staging, expected: createdIdentity, opened: stagingDirectory, in: parent)
            try verifyQueuePath(queueIdentity)
            // Publish only complete pairs. The main app ignores hidden staging folders.
            let result = staging.withCString { source in
                id.uuidString.withCString { destination in
                    renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw Self.fileError() }
            published = true
            try Self.verifyPath(id.uuidString, expected: createdIdentity, opened: stagingDirectory, in: parent)
            try verifyQueuePath(queueIdentity)
            return entry.pinned(queue: queueIdentity, directory: createdIdentity)
        } catch {
            if let stagingIdentity {
                try? SharedInboxHousekeeping.removeDirectory(
                    named: published ? id.uuidString : staging,
                    expected: stagingIdentity,
                    in: parent
                )
            }
            throw error
        }
    }

    func entries() throws -> [SharedPlistEntry] {
        try entries(beforeReturn: nil)
    }

    func entries(beforeReturn: (() -> Void)?) throws -> [SharedPlistEntry] {
        cleanupStaleEntries()
        guard let parent = try openDirectory(create: false) else { return [] }
        defer { close(parent) }
        let queueIdentity = try Self.directoryIdentity(of: parent)
        let result = try Self.listedEntries(in: parent).compactMap { listed -> SharedPlistEntry? in
                guard let id = UUID(uuidString: listed.name), listed.identity.fileType == S_IFDIR,
                      let child = try? Self.openChild(listed.name, in: parent, expected: listed.identity) else { return nil }
                defer { close(child) }
                guard let bytes = try? Self.readLimited("entry.json", in: child, limit: Self.maximumMetadataByteCount),
                      let entry = try? JSONDecoder().decode(SharedPlistEntry.self, from: bytes), entry.id == id,
                      (0...Self.maximumByteCount).contains(entry.byteCount),
                      (try? Self.verifyPath(listed.name, expected: listed.identity, opened: child, in: parent)) != nil else {
                    return nil
                }
                return entry.pinned(queue: queueIdentity, directory: listed.identity)
            }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
        beforeReturn?()
        try verifyQueuePath(queueIdentity)
        return result
    }

    func read(_ entry: SharedPlistEntry) throws -> Data {
        try read(entry, beforeUse: nil)
    }

    func read(_ entry: SharedPlistEntry, beforeUse: (() -> Void)?) throws -> Data {
        guard let parent = try openDirectory(create: false) else { throw Self.invalidQueue }
        defer { close(parent) }
        let child = try Self.openPinnedEntry(entry, in: parent)
        defer { close(child) }
        beforeUse?()
        // Published inbox files are local copies, not File Provider URLs. Open
        // relative to the pinned directory so replacing a path cannot redirect
        // a read into a different namespace while it is in progress.
        let bytes = try Self.readLimited("document.plist", in: child, limit: Self.maximumByteCount)
        try Self.validate(bytes)
        guard bytes.count == entry.byteCount else { throw Self.invalidQueue }
        guard let queueIdentity = entry.queueIdentity,
              let expected = entry.directoryIdentity else { throw Self.invalidQueue }
        try Self.verifyPath(entry.id.uuidString, expected: expected, opened: child, in: parent)
        try verifyQueuePath(queueIdentity)
        return bytes
    }

    func acknowledge(_ entry: SharedPlistEntry) throws {
        try acknowledge(entry, beforeIsolation: nil)
    }

    func acknowledge(_ entry: SharedPlistEntry, beforeIsolation: (() -> Void)?) throws {
        guard let parent = try openDirectory(create: false) else { throw Self.invalidQueue }
        defer { close(parent) }
        let child = try Self.openPinnedEntry(entry, in: parent)
        defer { close(child) }
        guard let queueIdentity = entry.queueIdentity,
              let expected = entry.directoryIdentity else { throw Self.invalidQueue }
        try SharedInboxHousekeeping.removeDirectory(named: entry.id.uuidString, expected: expected,
                                                     opened: child, in: parent,
                                                     beforeIsolation: beforeIsolation,
                                                     verifyParent: { try verifyQueuePath(queueIdentity) })
    }

    func reject(_ entry: SharedPlistEntry) {
        reject(entry, beforeIsolation: nil)
    }

    func reject(_ entry: SharedPlistEntry, beforeIsolation: (() -> Void)?) {
        _ = quarantine(entry, beforeIsolation: beforeIsolation)
    }

    private func quarantine(_ entry: SharedPlistEntry, beforeIsolation: (() -> Void)? = nil) -> Bool {
        guard let parent = try? openDirectory(create: false) else { return false }
        defer { close(parent) }
        guard let child = try? Self.openPinnedEntry(entry, in: parent),
              let queueIdentity = entry.queueIdentity,
              let expected = entry.directoryIdentity else { return false }
        defer { close(child) }
        return (try? SharedInboxHousekeeping.rejectDirectory(
            named: entry.id.uuidString, expected: expected, opened: child,
            in: parent, beforeIsolation: beforeIsolation,
            verifyParent: { try verifyQueuePath(queueIdentity) }
        )) != nil
    }

    @discardableResult
    func cleanupStaleEntries(now: Date = Date()) -> Int {
        cleanupStaleEntries(now: now, beforeIsolation: nil)
    }

    @discardableResult
    func cleanupStaleEntries(now: Date, beforeIsolation: ((String) -> Void)?) -> Int {
        SharedInboxHousekeeping.clean(container: container, namespace: namespace, now: now,
                                      beforeIsolation: beforeIsolation)
    }

    private static func fileError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func openChild(_ name: String, in parent: Int32,
                                  expected: SharedFileIdentity? = nil) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        do {
            let identity = try directoryIdentity(of: descriptor)
            guard expected == nil || identity == expected else { throw changedQueue }
            guard try pathIdentity(of: name, in: parent) == identity else { throw changedQueue }
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func openPinnedEntry(_ entry: SharedPlistEntry, in parent: Int32) throws -> Int32 {
        guard let queueIdentity = entry.queueIdentity,
              let directoryIdentity = entry.directoryIdentity,
              try Self.directoryIdentity(of: parent) == queueIdentity else { throw changedQueue }
        return try openChild(entry.id.uuidString, in: parent, expected: directoryIdentity)
    }

    private static func directoryIdentity(of descriptor: Int32) throws -> SharedFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileError() }
        let identity = SharedFileIdentity(info)
        guard identity.fileType == S_IFDIR else { throw invalidQueue }
        return identity
    }

    private static func pathIdentity(of name: String, in directory: Int32) throws -> SharedFileIdentity {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fileError() }
        return SharedFileIdentity(info)
    }

    private static func verifyPath(_ name: String, expected: SharedFileIdentity,
                                   opened descriptor: Int32, in parent: Int32) throws {
        guard try directoryIdentity(of: descriptor) == expected,
              try pathIdentity(of: name, in: parent) == expected else { throw changedQueue }
    }

    private func verifyQueuePath(_ expected: SharedFileIdentity) throws {
        // Reopen through the public App Group path. The descriptor used by the
        // operation remains valid after a rename, so fstat(parent) alone cannot
        // detect that the namespace was rebound to a different directory.
        guard let current = try openDirectory(create: false) else { throw Self.changedQueue }
        defer { close(current) }
        guard try Self.directoryIdentity(of: current) == expected else { throw Self.changedQueue }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        if create { try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true) }
        var descriptor = container.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        if descriptor < 0 {
            if !create && errno == ENOENT { return nil }
            throw Self.fileError()
        }
        do {
            // Check every component below the trusted App Group container. The
            // descriptor walk also survives concurrent renaming of an ancestor.
            for name in ["GestaltX", "ShareInbox", namespace] {
                if create && mkdirat(descriptor, name, 0o700) != 0 && errno != EEXIST { throw Self.fileError() }
                let next: Int32
                do { next = try Self.openChild(name, in: descriptor) }
                catch {
                    if !create && (error as NSError).code == Int(ENOENT) { close(descriptor); return nil }
                    throw error
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func listedEntries(in directory: Int32) throws -> [SharedDirectoryEntry] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw fileError() }
        guard let stream = fdopendir(duplicate) else { let error = fileError(); close(duplicate); throw error }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [SharedDirectoryEntry] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                var info = stat()
                if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    result.append(SharedDirectoryEntry(name: name, identity: SharedFileIdentity(info)))
                } else if errno != ENOENT {
                    throw fileError()
                }
            }
            errno = 0
        }
        guard errno == 0 else { throw fileError() }
        return result
    }

    private static func write(_ data: Data, named name: String, in directory: Int32) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private static func displayName(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent.filter { !$0.isNewline && !$0.isASCIIControl }
        var result = ""
        var byteCount = 0
        // A Character may contain many UTF-8 bytes, so a character count alone
        // cannot keep entry.json within the reader's limit. Leave room for JSON
        // escaping and the remaining metadata, without splitting a grapheme.
        for character in leaf.prefix(200) {
            let count = String(character).utf8.count
            guard count <= 1024 - byteCount else { break }
            result.append(character)
            byteCount += count
        }
        return result.isEmpty ? "MobileGestalt.plist" : result
    }

    // Temporary access failures do not prove that a published document is bad.
    // Keep those bytes for an explicit retry; malformed contents still leave the
    // automatic queue so they cannot block later documents forever.
    @discardableResult
    func reject(_ entry: SharedPlistEntry, after error: Error) -> Bool {
        guard !SharedPlistError.canRetry(error) else { return false }
        return quarantine(entry)
    }
}

// Each coordinator is used by one worker. Foundation explicitly permits cancel
// from another thread; no other coordinator operation crosses that boundary.
private final class SharedPlistReadJob: @unchecked Sendable {
    private let coordinator: NSFileCoordinator
    init(_ coordinator: NSFileCoordinator) { self.coordinator = coordinator }

    func run(_ read: @escaping @Sendable (NSFileCoordinator) throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            do {
                let bytes = try read(self.coordinator)
                try Task.checkCancellation()
                return bytes
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let bytes = try await worker.value
            try Task.checkCancellation()
            return bytes
        } onCancel: {
            worker.cancel()
            self.coordinator.cancel()
        }
    }
}

private enum SharedInboxHousekeeping {
    private static let lockName = ".writer.lock"
    private static let isolationPrefix = ".GestaltX-cleanup-evidence-"

    static func writerLock(in directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, lockName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw error() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { let failure = error(); close(descriptor); throw failure }
        return descriptor
    }

    static func removeDirectory(named name: String, expected: SharedFileIdentity,
                                in parent: Int32) throws {
        let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw error() }
        defer { close(opened) }
        try removeDirectory(named: name, expected: expected, opened: opened,
                            in: parent, beforeIsolation: nil, verifyParent: nil)
    }

    static func removeDirectory(named name: String, expected: SharedFileIdentity,
                                opened: Int32, in parent: Int32,
                                beforeIsolation: (() -> Void)?,
                                verifyParent: (() throws -> Void)?) throws {
        try verifyOpened(name, expected: expected, opened: opened, in: parent)
        beforeIsolation?()
        if let verifyParent = verifyParent { try verifyParent() }
        let isolated = try isolate(name, in: parent)
        try verifyOpened(isolated, expected: expected, opened: opened, in: parent)
        if let verifyParent = verifyParent { try verifyParent() }
        do {
            try removeContents(in: opened)
            try unlinkVerified(isolated, expected: expected, in: parent, directory: true)
        } catch {
            // Once isolated, any uncertainty leaves the exact tree under an
            // evidence name. It is never put back on a public queue path.
            throw error
        }
    }

    static func rejectDirectory(named name: String, expected: SharedFileIdentity,
                                opened: Int32, in parent: Int32,
                                beforeIsolation: (() -> Void)?,
                                verifyParent: (() throws -> Void)?) throws {
        try verifyOpened(name, expected: expected, opened: opened, in: parent)
        beforeIsolation?()
        if let verifyParent = verifyParent { try verifyParent() }
        let isolated = try isolate(name, in: parent)
        try verifyOpened(isolated, expected: expected, opened: opened, in: parent)
        if let verifyParent = verifyParent { try verifyParent() }

        // Timestamp the descriptor-pinned object while it still has an
        // unpredictable private name. A failure keeps it as evidence instead
        // of publishing an immediately-expired rejection.
        guard futimens(opened, nil) == 0 else { throw error() }
        try verifyOpened(isolated, expected: expected, opened: opened, in: parent)
        let rejected = "." + name + ".rejected"
        let result = isolated.withCString { source in
            rejected.withCString { destination in
                renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw error() }
        try verifyOpened(rejected, expected: expected, opened: opened, in: parent)
        if let verifyParent = verifyParent { try verifyParent() }
    }

    static func clean(container: URL, namespace: String, now: Date,
                      beforeIsolation: ((String) -> Void)?) -> Int {
        // Housekeeping is best effort. A failed scan must never prevent normal
        // enqueue/read operations, and an active producer is never waited on.
        guard let parent = try? openDirectory(container: container, namespace: namespace) else { return 0 }
        defer { close(parent) }
        guard let queueIdentity = try? descriptorIdentity(parent) else { return 0 }
        guard let names = try? names(in: parent) else { return 0 }
        var removed = 0
        for entry in names {
            guard removed < 32, let retention = retention(for: entry.name) else { continue }
            if cleanCandidate(entry, in: parent, retention: retention, now: now,
                              beforeIsolation: beforeIsolation,
                              verifyParent: {
                                  try verifyDirectory(container: container, namespace: namespace,
                                                      expected: queueIdentity)
                              }) {
                removed += 1
            }
        }
        return removed
    }

    private static func cleanCandidate(_ entry: SharedDirectoryEntry, in parent: Int32,
                                       retention: TimeInterval, now: Date,
                                       beforeIsolation: ((String) -> Void)?,
                                       verifyParent: () throws -> Void) -> Bool {
        guard (try? verifyParent()) != nil else { return false }
        let name = entry.name
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return false }
        defer { close(child) }
        var opened = stat()
        guard fstat(child, &opened) == 0,
              SharedFileIdentity(opened) == entry.identity,
              SharedFileIdentity(opened).fileType == S_IFDIR,
              now.timeIntervalSince1970 - Double(opened.st_mtimespec.tv_sec) >= retention else { return false }
        let openedIdentity = SharedFileIdentity(opened)

        let lease = openat(child, lockName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { return false }
        defer { close(lease) }
        var lockInfo = stat()
        guard fstat(lease, &lockInfo) == 0, SharedFileIdentity(lockInfo).fileType == S_IFREG,
              flock(lease, LOCK_EX | LOCK_NB) == 0 else { return false }
        let lockIdentity = SharedFileIdentity(lockInfo)
        // Holding a descriptor lock is insufficient if the lock's directory
        // entry was concurrently replaced. Pin both the descriptor and path.
        guard identity(of: lockName, in: child) == lockIdentity else { return false }

        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              SharedFileIdentity(current) == openedIdentity else { return false }
        beforeIsolation?(name)
        guard (try? verifyParent()) != nil else { return false }

        guard let isolated = try? isolate(name, in: parent) else { return false }
        var isolatedInfo = stat()
        guard fstatat(parent, isolated, &isolatedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              SharedFileIdentity(isolatedInfo) == openedIdentity else {
            // The source changed after the last identity check. Its replacement
            // remains under an unpredictable evidence name and is never deleted.
            return false
        }
        var pinned = stat()
        guard fstat(child, &pinned) == 0, SharedFileIdentity(pinned) == openedIdentity,
              identity(of: lockName, in: child) == lockIdentity,
              (try? verifyParent()) != nil else { return false }

        do {
            try removeContents(in: child)
            try unlinkVerified(isolated, expected: openedIdentity, in: parent, directory: true)
            return true
        } catch {
            // Keep the isolated tree for inspection whenever its identity or
            // contents become uncertain. A later scan ignores evidence names.
            return false
        }
    }

    private static func retention(for name: String) -> TimeInterval? {
        let suffix: String
        let age: TimeInterval
        if name.hasSuffix(".pending") { suffix = ".pending"; age = 24 * 60 * 60 }
        else if name.hasSuffix(".rejected") { suffix = ".rejected"; age = 7 * 24 * 60 * 60 }
        else { return nil }
        guard name.hasPrefix(".") else { return nil }
        let identifier = String(name.dropFirst().dropLast(suffix.count))
        guard let id = UUID(uuidString: identifier), id.uuidString == identifier else { return nil }
        return age
    }

    private static func openDirectory(container: URL, namespace: String) throws -> Int32 {
        var descriptor = container.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw error() }
        for component in ["GestaltX", "ShareInbox", namespace] {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = error()
            close(descriptor)
            guard next >= 0 else { throw failure }
            descriptor = next
        }
        return descriptor
    }

    private static func names(in directory: Int32) throws -> [SharedDirectoryEntry] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw error() }
        guard let stream = fdopendir(duplicate) else { let failure = error(); close(duplicate); throw failure }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [SharedDirectoryEntry] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                var info = stat()
                if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    result.append(SharedDirectoryEntry(name: name, identity: SharedFileIdentity(info)))
                } else if errno != ENOENT {
                    throw error()
                }
            }
            errno = 0
        }
        guard errno == 0 else { throw error() }
        return result
    }

    private static func removeContents(in directory: Int32, depth: Int = 0) throws {
        guard depth < 64 else { throw changedDuringCleanup() }
        for entry in try names(in: directory) {
            let name = entry.name
            var observed = stat()
            guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
                  SharedFileIdentity(observed) == entry.identity else { throw changedDuringCleanup() }
            let isolated = try isolate(name, in: directory)
            var isolatedInfo = stat()
            guard fstatat(directory, isolated, &isolatedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  SharedFileIdentity(isolatedInfo) == entry.identity else { throw changedDuringCleanup() }

            if entry.identity.fileType == S_IFDIR {
                let child = openat(directory, isolated, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw error() }
                do {
                    defer { close(child) }
                    var pinned = stat()
                    guard fstat(child, &pinned) == 0, SharedFileIdentity(pinned) == entry.identity else {
                        throw changedDuringCleanup()
                    }
                    try removeContents(in: child, depth: depth + 1)
                }
                try unlinkVerified(isolated, expected: entry.identity, in: directory, directory: true)
            } else {
                try unlinkVerified(isolated, expected: entry.identity, in: directory, directory: false)
            }
        }
    }

    private static func isolate(_ name: String, in directory: Int32) throws -> String {
        for _ in 0..<8 {
            let isolated = isolationPrefix + UUID().uuidString
            let result = name.withCString { source in
                isolated.withCString { destination in
                    renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return isolated }
            if errno != EEXIST { throw error() }
        }
        throw error()
    }

    private static func unlinkVerified(_ name: String, expected: SharedFileIdentity, in directory: Int32,
                                       directory isDirectory: Bool) throws {
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              SharedFileIdentity(current) == expected else { throw changedDuringCleanup() }
        // The random name is created exclusively inside a 0700 App Group tree;
        // this leaves no predictable path for a cooperating producer to replace
        // between the final identity check and unlinkat.
        guard unlinkat(directory, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw error() }
    }

    private static func identity(of name: String, in directory: Int32) -> SharedFileIdentity? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return SharedFileIdentity(info)
    }

    private static func descriptorIdentity(_ descriptor: Int32) throws -> SharedFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw error() }
        let identity = SharedFileIdentity(info)
        guard identity.fileType == S_IFDIR else { throw changedDuringCleanup() }
        return identity
    }

    private static func verifyOpened(_ name: String, expected: SharedFileIdentity,
                                     opened: Int32, in parent: Int32) throws {
        guard try descriptorIdentity(opened) == expected,
              identity(of: name, in: parent) == expected else { throw changedDuringCleanup() }
    }

    private static func verifyDirectory(container: URL, namespace: String,
                                        expected: SharedFileIdentity) throws {
        let current = try openDirectory(container: container, namespace: namespace)
        defer { close(current) }
        guard try descriptorIdentity(current) == expected else { throw changedDuringCleanup() }
    }

    private static func changedDuringCleanup() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
    }

    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
