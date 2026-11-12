import Foundation
import Darwin

struct InboxTestFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw InboxTestFailure(message: message) }
}
func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is InboxTestFailure { throw InboxTestFailure(message: message) } catch { return }
    throw InboxTestFailure(message: message)
}

@main struct SharedPlistInboxTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-share-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let group = root.appendingPathComponent("resigned-group")
        let inbox = try SharedPlistInbox(container: group, namespace: "com.example.resigned")
        let other = try SharedPlistInbox(container: group, namespace: "com.example.other")
        let document: [String: Any] = ["CacheExtra": ["string": "hello", "boolean": true, "integer": 1], "CacheData": Data([1, 2, 3])]
        let binary = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        let xml = try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
        let evidencePrefix = ".GestaltX-cleanup-evidence-"

        func rebindQueue(_ inbox: SharedPlistInbox, label: String, marker: Data) throws -> (parked: URL, replacement: URL) {
            let parked = root.appendingPathComponent(label + "-parked-queue")
            let replacement = root.appendingPathComponent(label + "-replacement-queue")
            try fm.moveItem(at: inbox.directory, to: parked)
            try fm.createDirectory(at: inbox.directory, withIntermediateDirectories: true)
            try marker.write(to: inbox.directory.appendingPathComponent("identity.marker"))
            return (parked, replacement)
        }

        func restoreQueue(_ inbox: SharedPlistInbox, _ binding: (parked: URL, replacement: URL)) throws {
            try fm.moveItem(at: inbox.directory, to: binding.replacement)
            try fm.moveItem(at: binding.parked, to: inbox.directory)
        }

        func replaceEntry(_ entry: SharedPlistEntry, in inbox: SharedPlistInbox,
                          label: String, marker: Data) throws -> (publicURL: URL, parked: URL, replacement: URL) {
            let publicURL = inbox.directory.appendingPathComponent(entry.id.uuidString)
            let parked = root.appendingPathComponent(label + "-parked-entry")
            let replacement = root.appendingPathComponent(label + "-replacement-entry")
            try fm.moveItem(at: publicURL, to: parked)
            try fm.createDirectory(at: publicURL, withIntermediateDirectories: false)
            try marker.write(to: publicURL.appendingPathComponent("identity.marker"))
            return (publicURL, parked, replacement)
        }

        func evidence(in inbox: SharedPlistInbox, marker: Data) throws -> [URL] {
            return try fm.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).filter { url in
                guard url.lastPathComponent.hasPrefix(evidencePrefix),
                      UUID(uuidString: String(url.lastPathComponent.dropFirst(evidencePrefix.count))) != nil else {
                    return false
                }
                return (try? Data(contentsOf: url.appendingPathComponent("identity.marker"))) == marker
            }
        }
        let source = root.appendingPathComponent("original.plist")
        try binary.write(to: source)
        let read = try SharedPlistInbox.readDocument(at: source)
        let encrypted = try DeviceBoundPlist.seal(binary, key: Data(repeating: 7, count: 32))
        try SharedPlistInbox.validate(encrypted)
        let first = try inbox.enqueue(read, name: "../../original\n.plist")
        try check(first.name == "original.plist", "Filenames are display metadata and cannot escape the inbox")
        try check(try inbox.read(first) == binary, "Publish and read exact binary plist bytes")
        try check(try Data(contentsOf: source) == binary, "Sharing never changes the user's original file")
        try check(try other.entries().isEmpty, "Different app instances do not consume each other's files")
        // Simulate a cold start after the extension process has already exited.
        let restarted = try SharedPlistInbox(container: group, namespace: "com.example.resigned")
        try check(try restarted.entries().map(\.id) == [first.id], "Completed handoff survives process restart")
        let second = try restarted.enqueue(xml, name: "same-name.plist")
        let third = try restarted.enqueue(binary, name: "same-name.plist")
        try check(second.id != third.id && (try restarted.entries().count) == 3, "Duplicate filenames never overwrite queued files")
        try check(try restarted.read(second) == xml, "XML plist is accepted without converting its values")
        try restarted.acknowledge(first)
        try check(try restarted.entries().map(\.id) == [second.id, third.id], "Acknowledge removes only the imported entry")
        let staged = restarted.directory.appendingPathComponent(".interrupted.pending")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try binary.write(to: staged.appendingPathComponent("document.plist"))
        try check(try restarted.entries().count == 2, "Partial publications are never imported")
        try rejects("Reject a path-traversal namespace") { _ = try SharedPlistInbox(container: group, namespace: "../escape") }
        try rejects("Reject a non-file URL") { _ = try SharedPlistInbox.readDocument(at: URL(string: "https://example.com/test.plist")!) }
        try rejects("Reject a non-plist") { _ = try inbox.enqueue(Data("hello".utf8), name: "wrong.plist") }
        let invalid = try PropertyListSerialization.data(fromPropertyList: ["NotMobileGestalt": true], format: .binary, options: 0)
        try rejects("Reject plist without CacheExtra") { _ = try inbox.enqueue(invalid, name: "wrong.plist") }
        let fakeEnvelope = try PropertyListSerialization.data(fromPropertyList: ["GestaltXDeviceProof": ["version": 2, "algorithm": "AES.GCM.256", "sealed": Data(repeating: 0, count: 27)]], format: .binary, options: 0)
        try rejects("Reject malformed encrypted envelopes") { _ = try inbox.enqueue(fakeEnvelope, name: "wrong.plist") }
        let oversized = root.appendingPathComponent("oversized.plist")
        try Data(repeating: 0, count: SharedPlistInbox.maximumByteCount + 1).write(to: oversized)
        try rejects("Bound the file read before parsing") { _ = try SharedPlistInbox.readDocument(at: oversized) }
        // A damaged published file is rejected, retained, and removed from the
        // automatic queue so it cannot repeatedly replace a current document.
        let secondPayload = restarted.directory.appendingPathComponent(second.id.uuidString).appendingPathComponent("document.plist")
        try Data("corrupt".utf8).write(to: secondPayload)
        try rejects("Revalidate a modified queue payload") { _ = try restarted.read(second) }
        restarted.reject(second)
        try check(try restarted.entries().map(\.id) == [third.id], "Quarantine a broken entry without blocking the queue")
        let thirdPayload = restarted.directory.appendingPathComponent(third.id.uuidString).appendingPathComponent("document.plist")
        try fm.removeItem(at: thirdPayload)
        try fm.createSymbolicLink(at: thirdPayload, withDestinationURL: source)
        try rejects("Reject symlinked queue documents") { _ = try restarted.read(third) }
        try check(try Data(contentsOf: source) == binary, "Rejected queue links cannot change the source")
        let special = try SharedPlistInbox(container: group, namespace: "special-files")
        let metadataEntry = try special.enqueue(binary, name: "metadata.plist")
        let metadata = special.directory.appendingPathComponent(metadataEntry.id.uuidString).appendingPathComponent("entry.json")
        let savedMetadata = root.appendingPathComponent("saved-entry.json")
        try fm.moveItem(at: metadata, to: savedMetadata)
        try fm.createSymbolicLink(at: metadata, withDestinationURL: savedMetadata)
        try check(try special.entries().isEmpty, "Ignore symlinked metadata instead of following it")
        try fm.removeItem(at: metadata)
        let madeFIFO = metadata.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
        try check(madeFIFO == 0, "Create a named-pipe metadata fixture")
        try check(try special.entries().isEmpty, "A metadata FIFO with no writer must not block the inbox scan")
        try rejects("Reject a document FIFO without waiting for a writer") { _ = try SharedPlistInbox.readDocument(at: metadata) }
        try rejects("Reject directories as documents") { _ = try SharedPlistInbox.readDocument(at: root) }
        try fm.removeItem(at: metadata)
        try fm.moveItem(at: savedMetadata, to: metadata)
        try check(try special.read(metadataEntry) == binary, "Normal documents remain readable after malformed queue entries")

        // Listing and enqueue must not return a capability for a queue that was
        // rebound to another directory before the operation completed.
        let listingInbox = try SharedPlistInbox(container: group, namespace: "listing-race")
        let listingEntry = try listingInbox.enqueue(binary, name: "listing.plist")
        let listingMarker = Data("listing-replacement".utf8)
        var listingBinding: (parked: URL, replacement: URL)?
        var listingHookError: Error?
        var listingRejected = false
        do {
            _ = try listingInbox.entries {
                do { listingBinding = try rebindQueue(listingInbox, label: "listing", marker: listingMarker) }
                catch { listingHookError = error }
            }
        } catch { listingRejected = true }
        try check(listingRejected && listingHookError == nil && listingBinding != nil,
                  "Enumeration rejects a queue directory rebound before returning entries")
        if let listingBinding {
            try check(try Data(contentsOf: listingBinding.parked.appendingPathComponent(listingEntry.id.uuidString)
                .appendingPathComponent("document.plist")) == binary,
                      "Enumeration leaves the descriptor-pinned original queue unchanged")
            try check(try Data(contentsOf: listingInbox.directory.appendingPathComponent("identity.marker")) == listingMarker,
                      "Enumeration leaves the replacement queue unchanged")
            try restoreQueue(listingInbox, listingBinding)
        }
        try check(try listingInbox.entries().map(\.id) == [listingEntry.id],
                  "The original queue remains usable after its public path is restored")

        let publishingInbox = try SharedPlistInbox(container: group, namespace: "publishing-race")
        let publishingMarker = Data("publishing-replacement".utf8)
        var publishingBinding: (parked: URL, replacement: URL)?
        var publishingHookError: Error?
        var publishingRejected = false
        do {
            _ = try publishingInbox.enqueue(binary, name: "raced-publish.plist") { _ in
                do { publishingBinding = try rebindQueue(publishingInbox, label: "publishing", marker: publishingMarker) }
                catch { publishingHookError = error }
            }
        } catch { publishingRejected = true }
        try check(publishingRejected && publishingHookError == nil && publishingBinding != nil,
                  "Enqueue rejects a queue directory rebound before publication")
        if let publishingBinding {
            try check(try fm.contentsOfDirectory(atPath: publishingBinding.parked.path).isEmpty,
                      "Failed enqueue removes only its own descriptor-pinned staging tree")
            try check(try Data(contentsOf: publishingInbox.directory.appendingPathComponent("identity.marker")) == publishingMarker,
                      "Failed enqueue never modifies the replacement queue")
            try restoreQueue(publishingInbox, publishingBinding)
        }
        let publishedAfterRace = try publishingInbox.enqueue(binary, name: "after-race.plist")
        try check(try publishingInbox.read(publishedAfterRace) == binary,
                  "Enqueue works after the original queue path is restored")

        // Capabilities returned by entries() are bound to both the queue inode
        // and the selected entry inode. A stable or mid-operation queue rebind
        // must stop read, acknowledgement, and rejection.
        let queueRace = try SharedPlistInbox(container: group, namespace: "queue-race")
        let queuedRead = try queueRace.enqueue(binary, name: "read.plist")
        let queuedAck = try queueRace.enqueue(binary, name: "ack.plist")
        let queuedReject = try queueRace.enqueue(binary, name: "reject.plist")
        let pinnedQueueEntries = try queueRace.entries()
        guard let pinnedRead = pinnedQueueEntries.first(where: { $0.id == queuedRead.id }),
              let pinnedAck = pinnedQueueEntries.first(where: { $0.id == queuedAck.id }),
              let pinnedReject = pinnedQueueEntries.first(where: { $0.id == queuedReject.id }) else {
            throw InboxTestFailure(message: "Capture all queue-bound entries")
        }
        let stableQueueMarker = Data("stable-queue-replacement".utf8)
        let stableQueueBinding = try rebindQueue(queueRace, label: "stable-queue", marker: stableQueueMarker)
        try rejects("Read rejects a queue replaced after listing") { _ = try queueRace.read(pinnedRead) }
        try rejects("Acknowledge rejects a queue replaced after listing") { try queueRace.acknowledge(pinnedAck) }
        queueRace.reject(pinnedReject)
        for entry in [pinnedRead, pinnedAck, pinnedReject] {
            try check(fm.fileExists(atPath: stableQueueBinding.parked.appendingPathComponent(entry.id.uuidString).path),
                      "A replaced queue cannot consume any descriptor-pinned entry")
        }
        try check(try Data(contentsOf: queueRace.directory.appendingPathComponent("identity.marker")) == stableQueueMarker,
                  "Read, acknowledge, and reject leave a replacement queue untouched")
        try restoreQueue(queueRace, stableQueueBinding)

        func exerciseQueueRebind(_ label: String, marker: Data,
                                 operation: (@escaping () -> Void) throws -> Void) throws {
            var binding: (parked: URL, replacement: URL)?
            var hookError: Error?
            var operationRejected = false
            do {
                try operation {
                    do { binding = try rebindQueue(queueRace, label: label, marker: marker) }
                    catch { hookError = error }
                }
            } catch { operationRejected = true }
            try check(operationRejected && hookError == nil && binding != nil,
                      "Reject a queue rebound after the operation opens its descriptors")
            if let binding {
                try check(try Data(contentsOf: queueRace.directory.appendingPathComponent("identity.marker")) == marker,
                          "A mid-operation queue replacement remains byte-for-byte intact")
                try restoreQueue(queueRace, binding)
            }
        }

        try exerciseQueueRebind("read-queue", marker: Data("read-queue-replacement".utf8)) { hook in
            _ = try queueRace.read(pinnedRead, beforeUse: hook)
        }
        try exerciseQueueRebind("ack-queue", marker: Data("ack-queue-replacement".utf8)) { hook in
            try queueRace.acknowledge(pinnedAck, beforeIsolation: hook)
        }
        var rejectQueueBinding: (parked: URL, replacement: URL)?
        var rejectQueueHookError: Error?
        let rejectQueueMarker = Data("reject-queue-replacement".utf8)
        queueRace.reject(pinnedReject) {
            do { rejectQueueBinding = try rebindQueue(queueRace, label: "reject-queue", marker: rejectQueueMarker) }
            catch { rejectQueueHookError = error }
        }
        try check(rejectQueueHookError == nil && rejectQueueBinding != nil,
                  "Inject a queue rebind before rejection isolation")
        if let rejectQueueBinding {
            try check(fm.fileExists(atPath: rejectQueueBinding.parked.appendingPathComponent(pinnedReject.id.uuidString).path),
                      "Rejection preserves the original entry when its queue is rebound")
            try check(try Data(contentsOf: queueRace.directory.appendingPathComponent("identity.marker")) == rejectQueueMarker,
                      "Rejection leaves the rebound queue unchanged")
            try restoreQueue(queueRace, rejectQueueBinding)
        }
        try queueRace.acknowledge(pinnedRead)
        try queueRace.acknowledge(pinnedAck)
        queueRace.reject(pinnedReject)
        try check(try queueRace.entries().isEmpty,
                  "Normal acknowledgement and rejection still drain restored queue entries")

        // Replacing one public entry between verification and rename must move
        // the unknown replacement to evidence, never delete it or the original.
        let entryRace = try SharedPlistInbox(container: group, namespace: "entry-race")
        let readRaceRaw = try entryRace.enqueue(binary, name: "read-entry.plist")
        let ackRaceRaw = try entryRace.enqueue(binary, name: "ack-entry.plist")
        let rejectRaceRaw = try entryRace.enqueue(binary, name: "reject-entry.plist")
        let pinnedEntryRaces = try entryRace.entries()
        guard let readRace = pinnedEntryRaces.first(where: { $0.id == readRaceRaw.id }),
              let ackRace = pinnedEntryRaces.first(where: { $0.id == ackRaceRaw.id }),
              let rejectRace = pinnedEntryRaces.first(where: { $0.id == rejectRaceRaw.id }) else {
            throw InboxTestFailure(message: "Capture all entry-bound identities")
        }

        let readEntryMarker = Data("read-entry-replacement".utf8)
        var readEntryBinding: (publicURL: URL, parked: URL, replacement: URL)?
        var readEntryHookError: Error?
        var readEntryRejected = false
        do {
            _ = try entryRace.read(readRace) {
                do { readEntryBinding = try replaceEntry(readRace, in: entryRace, label: "read-entry", marker: readEntryMarker) }
                catch { readEntryHookError = error }
            }
        } catch { readEntryRejected = true }
        try check(readEntryRejected && readEntryHookError == nil && readEntryBinding != nil,
                  "Read rejects an entry path replaced after opening the original directory")
        if let readEntryBinding {
            try check(try Data(contentsOf: readEntryBinding.parked.appendingPathComponent("document.plist")) == binary,
                      "Read preserves the descriptor-pinned original entry")
            try check(try Data(contentsOf: readEntryBinding.publicURL.appendingPathComponent("identity.marker")) == readEntryMarker,
                      "Read preserves the concurrently substituted entry")
            try fm.moveItem(at: readEntryBinding.publicURL, to: readEntryBinding.replacement)
            try fm.moveItem(at: readEntryBinding.parked, to: readEntryBinding.publicURL)
        }

        let ackEntryMarker = Data("ack-entry-replacement".utf8)
        var ackEntryBinding: (publicURL: URL, parked: URL, replacement: URL)?
        var ackEntryHookError: Error?
        var ackEntryRejected = false
        do {
            try entryRace.acknowledge(ackRace) {
                do { ackEntryBinding = try replaceEntry(ackRace, in: entryRace, label: "ack-entry", marker: ackEntryMarker) }
                catch { ackEntryHookError = error }
            }
        } catch { ackEntryRejected = true }
        try check(ackEntryRejected && ackEntryHookError == nil && ackEntryBinding != nil,
                  "Acknowledge rejects an entry replaced before atomic isolation")
        if let ackEntryBinding {
            try check(try Data(contentsOf: ackEntryBinding.parked.appendingPathComponent("document.plist")) == binary,
                      "Acknowledge preserves the original entry after a path race")
            try check(try evidence(in: entryRace, marker: ackEntryMarker).count == 1,
                      "Acknowledge retains exactly one unknown replacement as random evidence")
            try check(!fm.fileExists(atPath: ackEntryBinding.publicURL.path),
                      "Acknowledge leaves no unverified object on the public entry path")
            try fm.moveItem(at: ackEntryBinding.parked, to: ackEntryBinding.publicURL)
        }
        try entryRace.acknowledge(ackRace)

        let rejectEntryMarker = Data("reject-entry-replacement".utf8)
        var rejectEntryBinding: (publicURL: URL, parked: URL, replacement: URL)?
        var rejectEntryHookError: Error?
        entryRace.reject(rejectRace) {
            do { rejectEntryBinding = try replaceEntry(rejectRace, in: entryRace, label: "reject-entry", marker: rejectEntryMarker) }
            catch { rejectEntryHookError = error }
        }
        try check(rejectEntryHookError == nil && rejectEntryBinding != nil,
                  "Inject an entry replacement before rejection isolation")
        if let rejectEntryBinding {
            try check(try Data(contentsOf: rejectEntryBinding.parked.appendingPathComponent("document.plist")) == binary,
                      "Rejection preserves the original entry after a path race")
            try check(try evidence(in: entryRace, marker: rejectEntryMarker).count == 1,
                      "Rejection retains exactly one unknown replacement as random evidence")
            try check(!fm.fileExists(atPath: rejectEntryBinding.publicURL.path),
                      "Rejection leaves no unverified object on the public entry path")
            try fm.moveItem(at: rejectEntryBinding.parked, to: rejectEntryBinding.publicURL)
        }
        entryRace.reject(rejectRace)
        try check(fm.fileExists(atPath: entryRace.directory
            .appendingPathComponent("." + rejectRace.id.uuidString + ".rejected").path),
                  "A non-raced rejection still publishes the expected hidden quarantine name")
        try entryRace.acknowledge(readRace)
        try check(try entryRace.entries().isEmpty,
                  "Race evidence and rejected entries never reappear in the automatic queue")

        print("PASS: validation, atomic handoff, queue/entry identity pinning, rebind rejection, isolated acknowledgement and replacement evidence retention.")
    }
}
