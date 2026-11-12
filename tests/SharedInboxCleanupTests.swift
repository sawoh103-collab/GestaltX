import Foundation
import Darwin

@main struct SharedInboxCleanupTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        // A separate process holds the same advisory lease as an extension.
        // The five-second poll bounds even a regressed blocking cleanup test.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-lock" {
            let descriptor = open(CommandLine.arguments[2], O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure(message: "Open the writer lease") }
            defer { close(descriptor) }
            try expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Hold the writer lease in the child process")
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            _ = poll(&input, 1, 5000)
            return
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-inbox-cleanup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let inbox = try SharedPlistInbox(container: root, namespace: "test")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["fixture": true]], format: .binary, options: 0)
        let now = Date()
        let old = now.addingTimeInterval(-9 * 24 * 60 * 60)
        let published = try inbox.enqueue(bytes, name: "published.plist")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: inbox.directory.appendingPathComponent(published.id.uuidString).path)
        let recentlyRejected = try inbox.enqueue(bytes, name: "recently-rejected.plist")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: inbox.directory.appendingPathComponent(recentlyRejected.id.uuidString).path)
        inbox.reject(recentlyRejected)
        let recentRejection = inbox.directory.appendingPathComponent("." + recentlyRejected.id.uuidString + ".rejected")

        func fixture(_ suffix: String, date: Date, name: String? = nil) throws -> URL {
            let url = inbox.directory.appendingPathComponent(name ?? "." + UUID().uuidString + suffix)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            try bytes.write(to: url.appendingPathComponent("document.plist"))
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let abandoned = try fixture(".pending", date: old)
        let rejected = try fixture(".rejected", date: old)
        let recent = try fixture(".pending", date: now)
        let unknown = try fixture(".pending", date: old, name: ".not-our-uuid.pending")
        let active = try fixture(".pending", date: old)
        let lease = active.appendingPathComponent(".writer.lock")
        try Data().write(to: lease)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: active.path)
        var leaseBefore = stat()
        try expect(lease.withUnsafeFileSystemRepresentation { lstat($0!, &leaseBefore) } == 0,
                   "Record the active writer lock identity")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try bytes.write(to: outside.appendingPathComponent("keep.plist"))
        try fm.createSymbolicLink(at: abandoned.appendingPathComponent("outside.link"), withDestinationURL: outside)
        let link = inbox.directory.appendingPathComponent("." + UUID().uuidString + ".pending")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let badLease = try fixture(".pending", date: old)
        let fifo = badLease.appendingPathComponent(".writer.lock")
        try expect(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) } == 0, "Create a malformed lease fixture")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: badLease.path)
        let raced = try fixture(".pending", date: old)
        let racedName = raced.lastPathComponent
        let parkedOriginal = inbox.directory.appendingPathComponent(".race-original")
        let replacement = inbox.directory.appendingPathComponent(".race-replacement")
        let originalMarker = Data("scanned-original".utf8)
        let replacementMarker = Data("concurrent-replacement".utf8)
        let evidencePrefix = ".GestaltX-cleanup-evidence-"
        try originalMarker.write(to: raced.appendingPathComponent("identity.marker"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: raced.path)
        try fm.createDirectory(at: replacement, withIntermediateDirectories: false)
        try replacementMarker.write(to: replacement.appendingPathComponent("identity.marker"))
        let lockRaced = try fixture(".pending", date: old)
        let lockRacedName = lockRaced.lastPathComponent
        let lockRaceMarker = Data("lock-path-replacement".utf8)
        try lockRaceMarker.write(to: lockRaced.appendingPathComponent("identity.marker"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: lockRaced.path)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-lock", lease.path]
        let ready = Pipe(), release = Pipe()
        child.standardOutput = ready
        child.standardInput = release
        try child.run()
        try ready.fileHandleForWriting.close()
        defer { try? release.fileHandleForWriting.close(); if child.isRunning { child.terminate() } }
        try expect(try ready.fileHandleForReading.read(upToCount: 1) == Data([1]), "The child must hold its lease before cleanup")
        let start = Date()
        var raceInjectionError: Error?
        var raceWasInjected = false
        var lockRaceWasInjected = false
        let removed = inbox.cleanupStaleEntries(now: now) { name in
            do {
                if name == racedName, !raceWasInjected {
                    try fm.moveItem(at: raced, to: parkedOriginal)
                    try fm.moveItem(at: replacement, to: raced)
                    raceWasInjected = true
                } else if name == lockRacedName, !lockRaceWasInjected {
                    let racedLease = lockRaced.appendingPathComponent(".writer.lock")
                    try fm.removeItem(at: racedLease)
                    try Data("replacement-lock".utf8).write(to: racedLease)
                    lockRaceWasInjected = true
                }
            } catch {
                raceInjectionError = error
            }
        }
        try expect(Date().timeIntervalSince(start) < 2, "Cleanup must not wait for another process's writer lock")
        try expect(raceWasInjected && lockRaceWasInjected && raceInjectionError == nil,
                   "Inject path and writer-lock replacements after their identity checks")
        try expect(removed == 2, "Only expired pending/rejected fixtures are removed")
        try expect(!fm.fileExists(atPath: abandoned.path) && !fm.fileExists(atPath: rejected.path), "Remove abandoned payloads")
        for url in [recent, unknown, active, recentRejection, badLease, link] {
            try expect(fm.fileExists(atPath: url.path), "Preserve recent, active, unknown and linked directories")
        }
        var leaseAfter = stat()
        try expect(lease.withUnsafeFileSystemRepresentation { lstat($0!, &leaseAfter) } == 0 &&
                   leaseAfter.st_dev == leaseBefore.st_dev && leaseAfter.st_ino == leaseBefore.st_ino &&
                   (leaseAfter.st_mode & S_IFMT) == (leaseBefore.st_mode & S_IFMT),
                   "Cleanup must retain the active writer's exact lock object")
        var linkInfo = stat()
        try expect(link.withUnsafeFileSystemRepresentation { lstat($0!, &linkInfo) } == 0 &&
                   (linkInfo.st_mode & S_IFMT) == S_IFLNK,
                   "A stale symlink candidate must remain a symlink and must not be followed")
        try expect(try Data(contentsOf: outside.appendingPathComponent("keep.plist")) == bytes, "Never follow a cleanup symlink")
        try expect(try Data(contentsOf: parkedOriginal.appendingPathComponent("identity.marker")) == originalMarker,
                   "Keep the descriptor-pinned original when its published path is replaced")
        let evidenceEntries = try fm.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).filter { url in
            guard url.lastPathComponent.hasPrefix(evidencePrefix),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(evidencePrefix.count))) != nil else { return false }
            return (try? Data(contentsOf: url.appendingPathComponent("identity.marker"))) == replacementMarker
        }
        try expect(evidenceEntries.count == 1,
                   "Quarantine exactly one concurrently substituted directory under a random evidence name")
        let evidence = evidenceEntries[0]
        var evidenceInfo = stat()
        try expect(evidence.withUnsafeFileSystemRepresentation { lstat($0!, &evidenceInfo) } == 0 &&
                   (evidenceInfo.st_mode & S_IFMT) == S_IFDIR,
                   "The quarantined replacement must retain its directory type")
        try expect(!fm.fileExists(atPath: raced.path), "The raced public path must not reference an unverified object")
        let lockEvidence = try fm.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).first { url in
            guard url.lastPathComponent.hasPrefix(evidencePrefix),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(evidencePrefix.count))) != nil else { return false }
            return (try? Data(contentsOf: url.appendingPathComponent("identity.marker"))) == lockRaceMarker
        }
        try expect(lockEvidence != nil,
                   "Preserve the full candidate when its locked lease path is replaced")
        try expect(try inbox.read(published) == bytes, "Published entries are retained regardless of age")
        try release.fileHandleForWriting.write(contentsOf: Data([1]))
        try release.fileHandleForWriting.close()
        child.waitUntilExit()
        try expect(child.terminationStatus == 0, "The cooperating writer exits cleanly")
        try expect(inbox.cleanupStaleEntries(now: now) == 1, "After the writer exits, its expired staging folder can be removed")
        try expect(!fm.fileExists(atPath: active.path), "Clean a released abandoned lease")
        try expect(fm.fileExists(atPath: evidence.path), "Later cleanup ignores retained race evidence")
        try expect(lockEvidence.map { fm.fileExists(atPath: $0.path) } == true,
                   "Later cleanup also ignores writer-lock race evidence")
        try expect(try inbox.entries().map(\.id) == [published.id], "Housekeeping never consumes the automatic import queue")

        let reboundInbox = try SharedPlistInbox(container: root, namespace: "queue-rebind")
        let reboundCandidate = reboundInbox.directory.appendingPathComponent("." + UUID().uuidString + ".pending")
        try fm.createDirectory(at: reboundCandidate, withIntermediateDirectories: true)
        try bytes.write(to: reboundCandidate.appendingPathComponent("document.plist"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: reboundCandidate.path)
        let parkedQueue = root.appendingPathComponent("queue-rebind-parked")
        let replacementQueue = root.appendingPathComponent("queue-rebind-replacement")
        let queueMarker = Data("replacement-queue".utf8)
        var queueRaceError: Error?
        var queueRaceInjected = false
        let reboundRemoved = reboundInbox.cleanupStaleEntries(now: now) { name in
            guard name == reboundCandidate.lastPathComponent, !queueRaceInjected else { return }
            do {
                try fm.moveItem(at: reboundInbox.directory, to: parkedQueue)
                try fm.createDirectory(at: reboundInbox.directory, withIntermediateDirectories: true)
                try queueMarker.write(to: reboundInbox.directory.appendingPathComponent("identity.marker"))
                queueRaceInjected = true
            } catch { queueRaceError = error }
        }
        try expect(reboundRemoved == 0 && queueRaceInjected && queueRaceError == nil,
                   "Cleanup stops when the listed queue directory is rebound before isolation")
        try expect(fm.fileExists(atPath: parkedQueue.appendingPathComponent(reboundCandidate.lastPathComponent).path),
                   "Cleanup preserves the stale candidate in the descriptor-pinned original queue")
        try expect(try Data(contentsOf: reboundInbox.directory.appendingPathComponent("identity.marker")) == queueMarker,
                   "Cleanup leaves the concurrently substituted queue unchanged")
        try fm.moveItem(at: reboundInbox.directory, to: replacementQueue)
        try fm.moveItem(at: parkedQueue, to: reboundInbox.directory)
        try expect(reboundInbox.cleanupStaleEntries(now: now) == 1,
                   "Cleanup can remove the stale candidate after the original queue path is restored")
        try expect(!fm.fileExists(atPath: reboundCandidate.path),
                   "Restored-queue cleanup removes only the originally listed stale directory")

        let inaccessible = try SharedPlistInbox(container: root.appendingPathComponent("not-a-directory"), namespace: "test")
        try Data([0]).write(to: root.appendingPathComponent("not-a-directory"))
        try expect(inaccessible.cleanupStaleEntries(now: now) == 0, "Failed housekeeping is best effort")
        let another = try inbox.enqueue(bytes, name: "after-cleanup.plist")
        try expect(try inbox.read(another) == bytes, "Normal handoff still succeeds after malformed cleanup fixtures")
        print("PASS: aged cleanup, nonblocking leases, symlink isolation and concurrent replacement evidence retention.")
    }
}
