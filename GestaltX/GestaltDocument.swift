// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
import Foundation
import CoreFoundation
import CryptoKit
import Darwin

struct GestaltFailure: LocalizedError, Sendable {
    let key: String
    var errorDescription: String? { NSLocalizedString(key, comment: "") }
    init(_ key: String) { self.key = key }
}

enum PlistValueKind: String, CaseIterable, Identifiable, Sendable {
    case string = "String", integer = "Integer", real = "Real", boolean = "Boolean"
    case data = "Data", array = "Array", dictionary = "Dictionary", date = "Date"
    var id: String { rawValue }

    static func detect(_ value: Any) -> Self {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean }
            return CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self)) ? .real : .integer
        }
        if value is Date { return .date }
        if value is Data { return .data }
        if value is [String: Any] { return .dictionary }
        if value is [Any] { return .array }
        return .string
    }

    func parse(_ text: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .string: return text
        case .integer:
            if let value = Int64(trimmed) { return NSNumber(value: value) }
            // Binary plists can also contain unsigned 64-bit identifiers.
            guard let value = UInt64(trimmed) else { throw GestaltFailure("Enter a valid whole number.") }
            return NSNumber(value: value)
        case .real:
            guard let value = Double(trimmed), value.isFinite else { throw GestaltFailure("Enter a finite decimal number.") }
            return NSNumber(value: value)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1": return NSNumber(value: true)
            case "false", "0": return NSNumber(value: false)
            default: throw GestaltFailure("Use true or false for a Boolean value.")
            }
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: trimmed) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: trimmed) else { throw GestaltFailure("Enter an ISO 8601 date, such as 2026-11-09T12:00:00Z.") }
            return value
        case .data:
            guard let value = Data(base64Encoded: trimmed.filter { !$0.isWhitespace }) else { throw GestaltFailure("Enter valid Base64 data.") }
            return value
        case .array, .dictionary:
            // An XML plist fragment preserves nested Data, Boolean and integer types.
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">\(text)</plist>"
            guard let value = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil),
                  (self == .array && value is [Any]) || (self == .dictionary && value is [String: Any]) else {
                throw GestaltFailure("Enter an XML plist array or dictionary fragment.")
            }
            return value
        }
    }

    func text(for value: Any) -> String {
        switch self {
        case .boolean: return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (value as? Date).map { formatter.string(from: $0) } ?? ""
        case .data: return (value as? Data)?.base64EncodedString() ?? ""
        case .array, .dictionary:
            guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
                  let xml = String(data: data, encoding: .utf8),
                  let start = xml.range(of: "<plist version=\"1.0\">"),
                  let end = xml.range(of: "</plist>", options: .backwards) else { return "" }
            return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        default: return String(describing: value)
        }
    }
}

enum GestaltKeys {
    static let group = "group.com.huami.gestultx" // Keep the existing provisioned App Group.
    static let devicePath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
    static let artwork = "oPeik/9e8lQWMszEjbPzng"
    static let regionCode = "h63QSdBCiT/z0WU6rdQv6Q"
    static let regionInfo = "zHeENZu+wbg7PUprwNwBWg"
    static let legacyRegionInfo = "yK+xavymRGZ3xWc1tb8XDg"
    static let productType = "h9jDsbgj7xIVeIQ8S3/X3Q"
    static let modelNumber = "97JDvERpVwO+GHtthIh7hA"
}

struct GestaltDocument: @unchecked Sendable {
    private(set) var root: [String: Any]
    var extra: [String: Any] { root["CacheExtra"] as? [String: Any] ?? [:] }
    var artwork: [String: Any] { extra[GestaltKeys.artwork] as? [String: Any] ?? [:] }
    var canEditArtwork: Bool { extra[GestaltKeys.artwork] == nil || extra[GestaltKeys.artwork] is [String: Any] }

    init(data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              root["CacheExtra"] is [String: Any] else { throw GestaltFailure("Choose a MobileGestalt plist with a CacheExtra dictionary.") }
        self.root = root
    }

    mutating func set(_ value: Any?, for key: String) {
        var updated = extra
        updated[key] = value
        root["CacheExtra"] = updated
    }

    mutating func setCacheOptions(_ flags: CachedOptionFlags, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws {
        let layout = try resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: self)
        var data = try DeviceCacheOptions.validatedData(in: self, using: layout)
        data[layout.greenTeaOffset] = flags.greenTea ? 1 : 0
        data[layout.notGreenTeaOffset] = flags.notGreenTea ? 1 : 0
        root["CacheData"] = data
    }

    mutating func setWAPI(_ enabled: Bool, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws {
        let layout = try resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: self)
        _ = try DeviceCacheOptions.wapi(in: self, using: layout)
        guard let offset = layout.wapiOffset, var data = root["CacheData"] as? Data else { return }
        data[offset] = enabled ? 1 : 0
        root["CacheData"] = data
    }

    mutating func preservePendingCacheData(_ pending: Self, comparedTo original: Self) {
        // Restoring an unrelated CacheExtra preset must retain staged cache edits.
        // The complete edit is validated again by GestaltFileStore before writing.
        if pending.root["CacheData"] as? Data != original.root["CacheData"] as? Data {
            root["CacheData"] = pending.root["CacheData"]
        }
    }

    mutating func applyRegion(code: String, salesSuffix: String? = nil) {
        set(code, for: GestaltKeys.regionCode)
        // A code-only edit must leave both sales-region suffix fields untouched.
        guard let salesSuffix else { return }
        let present = [GestaltKeys.regionInfo, GestaltKeys.legacyRegionInfo].filter { extra[$0] != nil }
        for key in present.isEmpty ? [GestaltKeys.regionInfo] : present { set(salesSuffix, for: key) }
    }

    mutating func applyModel(_ model: ModelPreset?) {
        guard let model, model.id != "keep" else { return }
        set(model.value, for: GestaltKeys.modelNumber)
    }

    mutating func applyRegion(salesRegion: RegionPreset?, regionCode: RegionPreset?) {
        let sales = salesRegion.flatMap { $0.id == "keep" ? nil : $0 }
        let standaloneCode = regionCode.flatMap { $0.id == "keep" ? nil : $0 }
        guard let code = standaloneCode?.code ?? sales?.code else { return }
        applyRegion(code: code, salesSuffix: sales?.info)
    }

    @discardableResult
    mutating func setArtwork(_ value: Any, for key: String) -> Bool {
        // Never replace an existing malformed artwork value and silently lose its data.
        guard canEditArtwork else { return false }
        var updated = artwork
        updated[key] = value
        set(updated, for: GestaltKeys.artwork)
        return true
    }

    func encoded() throws -> Data {
        guard PropertyListSerialization.propertyList(root, isValidFor: .binary) else { throw GestaltFailure("The edited document is not a valid property list.") }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    static func valuesEqual(_ a: Any, _ b: Any) -> Bool {
        let kind = PlistValueKind.detect(a)
        guard kind == PlistValueKind.detect(b) else { return false }
        switch kind {
        case .dictionary:
            guard let left = a as? [String: Any], let right = b as? [String: Any], Set(left.keys) == Set(right.keys) else { return false }
            return left.allSatisfy { key, value in right[key].map { valuesEqual(value, $0) } ?? false }
        case .array:
            guard let left = a as? [Any], let right = b as? [Any], left.count == right.count else { return false }
            return zip(left, right).allSatisfy { valuesEqual($0.0, $0.1) }
        case .integer:
            // int64Value wraps unsigned values above Int64.max (for example,
            // UInt64.max becomes -1), hiding edits and readback corruption.
            return (a as? NSNumber)?.stringValue == (b as? NSNumber)?.stringValue
        case .real:
            guard let left = (a as? NSNumber)?.doubleValue,
                  let right = (b as? NSNumber)?.doubleValue else { return false }
            // NaN is a valid plist real. IEEE arithmetic equality is not
            // reflexive for it, but an unchanged stored value must compare equal.
            return left == right || (left.isNaN && right.isNaN)
        case .boolean: return (a as? NSNumber)?.boolValue == (b as? NSNumber)?.boolValue
        case .data: return (a as? Data) == (b as? Data)
        case .date: return (a as? Date) == (b as? Date)
        case .string: return (a as? String) == (b as? String)
        }
    }
    func matches(_ other: Self) -> Bool { Self.valuesEqual(root, other.root) }

    func matchesIdentity(_ other: Self) -> Bool {
        let identityKeys = ["re6Zb+zwFKJNlkQTUeT+/w", "VasUgeSzVyHdB27g2XpN0g"]
        for key in identityKeys {
            if let a = extra[key] as? String, let b = other.extra[key] as? String, a != b { return false }
        }
        return true
    }

    func preservesDeviceIdentity(of original: Self) -> Bool {
        // Keep each actual field and its plist type unchanged. Normalizing an
        // identifier here would also permit edits that invalidate saved history.
        let keys = ["UniqueDeviceID", "re6Zb+zwFKJNlkQTUeT+/w",
                    "SerialNumber", "VasUgeSzVyHdB27g2XpN0g",
                    "UniqueChipID", "TF31PAB6aO8KAbPyNKSxKA"]
        for key in keys {
            switch (original.extra[key], extra[key]) {
            case (nil, nil): continue
            case (let before?, let after?) where Self.valuesEqual(before, after): continue
            default: return false
            }
        }
        return true
    }
}

enum DocumentSource: String, Codable, Sendable { case device, local }
struct OriginalField: @unchecked Sendable {
    // A stored nil means the field was absent. It must not fall back to the
    // now-modified document's value when resolving a restore.
    let value: Any?
    var plist: [String: Any] {
        var entry: [String: Any] = ["exists": value != nil]
        if let value { entry["value"] = value }
        return entry
    }
}
struct DocumentSnapshot: @unchecked Sendable {
    let data: Data
    let document: GestaltDocument
    let source: DocumentSource
    let name: String
    var originals: [String: OriginalField] = [:]
    var cachedOptionsOriginal: CachedOptionsOriginal?
    var wapiOriginal: WAPIOriginal?
    var ownershipVerified = false

    func originalWAPI() throws -> Bool {
        if let wapiOriginal { return try wapiOriginal.value(in: document) }
        return try DeviceCacheOptions.wapi(in: document)
    }

    func originalCachedOptionFlags() throws -> CachedOptionFlags {
        if let cachedOptionsOriginal { return try cachedOptionsOriginal.flags(in: document) }
        // No history means the loaded values are the baseline, not a guessed restriction.
        return try DeviceCacheOptions.flags(in: document)
    }

    func recordingOriginals(to edited: GestaltDocument) -> OriginalValues {
        var audio = cachedOptionsOriginal
        if audio == nil, let before = try? CachedOptionsOriginal(document: document),
           let after = try? DeviceCacheOptions.flags(in: edited), before.flags != after {
            audio = before
        }
        var wapi = wapiOriginal
        if wapi == nil, let before = try? WAPIOriginal(document: document),
           let after = try? DeviceCacheOptions.wapi(in: edited), before.enabled != after { wapi = before }
        return OriginalValues(fields: recordingChanges(to: edited), cachedOptions: audio, wapi: wapi)
    }

    func originalValue(for key: String) -> Any? {
        if let original = originals[key] { return original.value }
        return document.extra[key]
    }

    func recordingChanges(to edited: GestaltDocument) -> [String: OriginalField] {
        var recorded = originals
        let before = document.extra, after = edited.extra
        for key in Set(before.keys).union(after.keys) where recorded[key] == nil {
            switch (before[key], after[key]) {
            case (nil, nil): continue
            case (let a?, let b?) where GestaltDocument.valuesEqual(a, b): continue
            default: recorded[key] = OriginalField(value: before[key])
            }
        }
        return recorded
    }

    func rebasingPendingEdits(_ pending: GestaltDocument, onto updated: GestaltDocument,
                              excluding keys: Set<String>, preservingCacheData: Bool = true) -> GestaltDocument {
        var result = updated
        if preservingCacheData { result.preservePendingCacheData(pending, comparedTo: document) }
        let before = document.extra, staged = pending.extra
        for key in Set(before.keys).union(staged.keys) where !keys.contains(key) {
            switch (before[key], staged[key]) {
            case (nil, nil): continue
            case (let a?, let b?) where GestaltDocument.valuesEqual(a, b): continue
            default: result.set(staged[key], for: key)
            }
        }
        return result
    }
}
struct OriginalValues {
    var fields: [String: OriginalField] = [:]
    var cachedOptions: CachedOptionsOriginal?
    var wapi: WAPIOriginal?
    // A failed legacy migration must not later use backups created after the
    // failure as evidence of the original values for this layout.
    var unavailableCacheOriginals: [String: Set<String>] = [:]
}

struct BackupRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let reason: String
    let source: DocumentSource
    let deviceID: String
    let byteCount: Int
    let sha256: String?
    let integrityVersion: Int?
    var filename: String { id.uuidString + ".plist" }
    var hasTrustedIntegrity: Bool {
        guard integrityVersion == 1, let sha256, sha256.utf8.count == 64 else { return false }
        return sha256.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    init(id: UUID, date: Date, reason: String, source: DocumentSource, deviceID: String,
         byteCount: Int, sha256: String? = nil, integrityVersion: Int? = nil) {
        self.id = id; self.date = date; self.reason = reason; self.source = source
        self.deviceID = deviceID; self.byteCount = byteCount; self.sha256 = sha256
        self.integrityVersion = integrityVersion
    }
}

private enum PendingWriteState {
    case original
    case intended
    case partialIntended
    case unexpected
}

private enum FailedWriteRecovery {
    case unchanged
    case restored
    case intendedPresent
}

struct PendingSystemWrite: Codable {
    let version: Int
    let deviceID: String
    let deviceNumber: UInt64
    let inodeNumber: UInt64
    let original: Data
    let intended: Data
    let originalSHA256: String
    let intendedSHA256: String
}

actor GestaltFileStore {
    private let deviceURL: URL
    private let backupDirectory: URL
    private let deviceID: String
    private let acquire: @Sendable () throws -> Int64
    private let release: @Sendable (Int64) -> Void
    private let writeData: (@Sendable (Data, URL) throws -> Void)?
    private let removeBackupItem: @Sendable (URL) throws -> Void
    private let eventSink: @Sendable (String) -> Void
    private var pendingSystemWriteURL: URL { backupDirectory.appendingPathComponent("PendingSystemWrite.plist") }

    init(deviceURL: URL, backupDirectory: URL, deviceID: String,
         acquire: @escaping @Sendable () throws -> Int64,
         release: @escaping @Sendable (Int64) -> Void,
         writeData: (@Sendable (Data, URL) throws -> Void)? = nil,
         removeBackupItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         eventSink: @escaping @Sendable (String) -> Void = { _ in }) {
        self.deviceURL = deviceURL; self.backupDirectory = backupDirectory; self.deviceID = deviceID
        self.acquire = acquire; self.release = release; self.writeData = writeData; self.eventSink = eventSink
        self.removeBackupItem = removeBackupItem
    }

    private func hardenBackupDirectory() throws {
        let files = FileManager.default
        try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
        #if os(iOS)
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: backupDirectory.path)
        var directory = backupDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #endif
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func fullSynchronize(_ descriptor: Int32) throws {
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func durableProtectedWrite(_ data: Data, to url: URL) throws {
        try hardenBackupDirectory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GestaltFailure("A protected local file changed while it was being synchronized.")
        }
        try fullSynchronize(descriptor)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func fileIdentity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private func openPinnedSystemFile(flags: Int32,
                                      identity: (device: UInt64, inode: UInt64)) throws -> Int32 {
        let descriptor = deviceURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, flags | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            throw failure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode else {
            Darwin.close(descriptor)
            throw GestaltFailure("The MobileGestalt file was replaced while writing.")
        }
        return descriptor
    }

    private func verifyPinnedDescriptor(_ descriptor: Int32,
                                        identity: (device: UInt64, inode: UInt64),
                                        action: String) throws {
        var info = stat()
        let pathIdentity = try fileIdentity(deviceURL)
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode,
              pathIdentity.device == identity.device, pathIdentity.inode == identity.inode else {
            throw GestaltFailure("The MobileGestalt file was replaced while \(action).")
        }
    }

    private func readDescriptorData(_ descriptor: Int32) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeDescriptorData(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno))
                }
                offset += count
            }
        }
    }

    private func acquireFileLock(_ descriptor: Int32, mode: Int32) throws {
        while flock(descriptor, mode | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw GestaltFailure("The MobileGestalt file is busy. Refresh before applying your edits.")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private func readPinnedSystemData(identity: (device: UInt64, inode: UInt64)) throws -> Data {
        let descriptor = try openPinnedSystemFile(flags: O_RDONLY, identity: identity)
        defer { Darwin.close(descriptor) }
        try acquireFileLock(descriptor, mode: LOCK_SH)
        defer { _ = flock(descriptor, LOCK_UN) }
        let data = try readDescriptorData(descriptor)
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "reading")
        return data
    }

    private func withLockedPinnedSystemFile<T>(identity: (device: UInt64, inode: UInt64),
                                               _ operation: (Int32) throws -> T) throws -> T {
        let descriptor = try openPinnedSystemFile(flags: O_RDWR, identity: identity)
        defer { Darwin.close(descriptor) }
        try acquireFileLock(descriptor, mode: LOCK_EX)
        defer { _ = flock(descriptor, LOCK_UN) }
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "writing")
        return try operation(descriptor)
    }

    private func replaceLockedSystemData(_ data: Data, expected: Data, descriptor: Int32,
                                         identity: (device: UInt64, inode: UInt64)) throws {
        guard try readDescriptorData(descriptor) == expected else {
            throw GestaltFailure("MobileGestalt changed since it was loaded. Refresh before applying your edits.")
        }
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "writing")
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0,
              ftruncate(descriptor, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try writeDescriptorData(data, descriptor: descriptor)
        try fullSynchronize(descriptor)
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "writing")
    }

    private func synchronizeLockedSystemData(_ expected: Data, descriptor: Int32,
                                             identity: (device: UInt64, inode: UInt64)) throws {
        guard try readDescriptorData(descriptor) == expected else {
            throw GestaltFailure("MobileGestalt changed before recovery could synchronize it.")
        }
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "synchronizing")
        try fullSynchronize(descriptor)
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "synchronizing")
    }

    private func beginPendingSystemWrite(original: Data, intended: Data,
                                         identity: (device: UInt64, inode: UInt64)) throws {
        guard !FileManager.default.fileExists(atPath: pendingSystemWriteURL.path) else {
            throw GestaltFailure("An unfinished MobileGestalt recovery record already exists. Reload before writing.")
        }
        let journal = PendingSystemWrite(version: 1, deviceID: deviceID,
                                         deviceNumber: identity.device, inodeNumber: identity.inode,
                                         original: original, intended: intended,
                                         originalSHA256: backupDigest(original), intendedSHA256: backupDigest(intended))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(journal)
        try durableProtectedWrite(data, to: pendingSystemWriteURL)
        guard try Data(contentsOf: pendingSystemWriteURL) == data else {
            throw GestaltFailure("The write-ahead recovery record could not be verified. No system write was started.")
        }
        eventSink("Recovery journal: original and intended bytes saved and synchronized")
    }

    private func clearPendingSystemWrite() throws {
        guard FileManager.default.fileExists(atPath: pendingSystemWriteURL.path) else { return }
        try FileManager.default.removeItem(at: pendingSystemWriteURL)
        try synchronizeDirectory(backupDirectory)
    }

    private func pendingWriteState(current: Data, original: Data, intended: Data) -> PendingWriteState {
        if current == original { return .original }
        if current == intended { return .intended }
        if current.count < intended.count,
           Data(intended.prefix(current.count)) == current {
            return .partialIntended
        }
        return .unexpected
    }

    private func recoverPendingSystemWrite() throws {
        guard FileManager.default.fileExists(atPath: pendingSystemWriteURL.path) else { return }
        eventSink("Recovery journal: unfinished system write found")
        let identity = try fileIdentity(deviceURL)
        try withLockedPinnedSystemFile(identity: identity) { descriptor in
            guard FileManager.default.fileExists(atPath: pendingSystemWriteURL.path) else { return }
            let encoded = try Data(contentsOf: pendingSystemWriteURL)
            guard let journal = try? PropertyListDecoder().decode(PendingSystemWrite.self, from: encoded),
                  journal.version == 1, journal.deviceID == deviceID,
                  journal.originalSHA256 == backupDigest(journal.original),
                  journal.intendedSHA256 == backupDigest(journal.intended),
                  (try? GestaltDocument(data: journal.original)) != nil,
                  (try? GestaltDocument(data: journal.intended)) != nil else {
                throw GestaltFailure("The write-ahead recovery record is damaged. Keep local backups and do not write the system file.")
            }
            guard identity.device == journal.deviceNumber, identity.inode == journal.inodeNumber else {
                throw GestaltFailure("The MobileGestalt file was replaced after an interrupted write. Recovery stopped without overwriting it.")
            }
            let current = try readDescriptorData(descriptor)
            try verifyPinnedDescriptor(descriptor, identity: identity, action: "recovering")
            switch pendingWriteState(current: current, original: journal.original, intended: journal.intended) {
            case .original:
                try clearPendingSystemWrite()
                eventSink("Recovery journal: original bytes already present; journal cleared")
            case .intended:
                try synchronizeLockedSystemData(journal.intended, descriptor: descriptor, identity: identity)
                try clearPendingSystemWrite()
                eventSink("Recovery journal: intended bytes synchronized; journal cleared")
            case .partialIntended:
                eventSink("Recovery journal: strict intended prefix found; restoring original")
                try replaceLockedSystemData(journal.original, expected: current,
                                            descriptor: descriptor, identity: identity)
                guard try readDescriptorData(descriptor) == journal.original,
                      (try? GestaltDocument(data: journal.original)) != nil else {
                    throw GestaltFailure("Interrupted-write recovery failed. Keep the recovery record and restore the device before trying again.")
                }
                try clearPendingSystemWrite()
                eventSink("Recovery journal: original bytes restored and verified")
            case .unexpected:
                eventSink("Recovery journal: unexpected same-inode bytes found; recovery stopped")
                throw GestaltFailure("The MobileGestalt file contains an unrecognized same-inode update. Recovery stopped without overwriting it; keep the recovery record.")
            }
        }
    }

    private func recoverFailedSystemWrite(original: Data, intended: Data,
                                          identity: (device: UInt64, inode: UInt64),
                                          descriptor: Int32) throws -> FailedWriteRecovery {
        let current = try readDescriptorData(descriptor)
        try verifyPinnedDescriptor(descriptor, identity: identity, action: "recovering")
        switch pendingWriteState(current: current, original: original, intended: intended) {
        case .original:
            try clearPendingSystemWrite()
            eventSink("Recovery: original bytes remained unchanged; journal cleared")
            return .unchanged
        case .intended:
            eventSink("Recovery: intended bytes are present; journal retained for the next verified access")
            return .intendedPresent
        case .partialIntended:
            eventSink("Recovery: strict intended prefix found; restoring previous bytes")
            try replaceLockedSystemData(original, expected: current,
                                        descriptor: descriptor, identity: identity)
            guard try readDescriptorData(descriptor) == original,
                  (try? GestaltDocument(data: original)) != nil else {
                throw GestaltFailure("The original file could not be restored.")
            }
            try clearPendingSystemWrite()
            eventSink("Recovery: previous bytes restored and verified")
            return .restored
        case .unexpected:
            eventSink("Recovery: unexpected same-inode bytes found; journal retained")
            throw GestaltFailure("An unrecognized update appeared during the write. It was not overwritten; keep the recovery journal.")
        }
    }

    private func withAccess<T>(_ operation: () throws -> T) throws -> T {
        eventSink("Access: requesting sandbox extension")
        let handle = try acquire()
        guard handle >= 0 else { throw GestaltFailure("MobileGestalt access was denied. Check the OS version and App Group signing.") }
        defer { release(handle); eventSink("Access: extension scope ended") }
        do {
            try recoverPendingSystemWrite()
            return try operation()
        }
        catch { eventSink("Access operation failed: " + error.localizedDescription); throw error }
    }

    func loadDevice() throws -> DocumentSnapshot {
        try withAccess {
            let identity = try fileIdentity(deviceURL)
            let data = try readPinnedSystemData(identity: identity)
            eventSink("Read: \(data.count) bytes; validating plist")
            let document = try GestaltDocument(data: data)
            let originals = try loadOriginals(for: document)
            let hasVerifiedDeviceBackup = try backups().contains { record in
                guard record.hasTrustedIntegrity, record.source == .device,
                      record.deviceID == deviceID,
                      let verified = try? verifiedBackup(record) else { return false }
                return verified.metadata.hasTrustedIntegrity && verified.metadata.source == .device &&
                    verified.metadata.deviceID == deviceID
            }
            if !hasVerifiedDeviceBackup {
                var baseline = document
                for (key, original) in originals.fields { baseline.set(original.value, for: key) }
                if let audio = originals.cachedOptions, let flags = try? audio.flags(in: baseline) {
                    try baseline.setCacheOptions(flags)
                }
                if let wapi = originals.wapi, let value = try? wapi.value(in: baseline) { try baseline.setWAPI(value) }
                let hasOriginals = !originals.fields.isEmpty || originals.cachedOptions != nil || originals.wapi != nil
                let initialData = hasOriginals ? try baseline.encoded() : data
                try saveBackup(initialData, source: .device, reason: hasOriginals ? "Original values snapshot" : "Initial backup")
            }
            return DocumentSnapshot(data: data, document: document, source: .device, name: "MobileGestalt",
                                    originals: originals.fields, cachedOptionsOriginal: originals.cachedOptions, wapiOriginal: originals.wapi)
        }
    }

    func loadLocal(data: Data, name: String) throws -> DocumentSnapshot {
        DocumentSnapshot(data: data, document: try GestaltDocument(data: data), source: .local, name: name)
    }

    func backups() throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> BackupRecord? in
                guard let record = try? JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: url)),
                      url.lastPathComponent == record.id.uuidString + ".json",
                      FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent(record.filename).path) else { return nil }
                return record
            }.sorted { $0.date > $1.date }
    }

    private var originalsURL: URL { backupDirectory.appendingPathComponent("OriginalValues.plist") }

    private func identity(of document: GestaltDocument) -> [String: String] {
        var identity: [String: String] = [:]
        for key in ["re6Zb+zwFKJNlkQTUeT+/w", "VasUgeSzVyHdB27g2XpN0g"] {
            if let value = document.extra[key] as? String { identity[key] = value }
        }
        return identity
    }

    private func loadOriginals(for document: GestaltDocument) throws -> OriginalValues {
        guard FileManager.default.fileExists(atPath: originalsURL.path) else {
            let recovered = try recoverOriginals(from: document)
            if !recovered.fields.isEmpty || recovered.cachedOptions != nil || recovered.wapi != nil {
                try saveOriginals(recovered, for: document)
            }
            return recovered
        }
        guard let data = try? Data(contentsOf: originalsURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              plist["version"] as? Int == 1,
              let savedID = plist["deviceID"] as? String,
              let savedIdentity = plist["identity"] as? [String: String],
              let values = plist["values"] as? [String: [String: Any]] else {
            throw GestaltFailure("Original values could not be read. No system changes were made.")
        }
        guard savedID == deviceID, savedIdentity.allSatisfy({ document.extra[$0.key] as? String == $0.value }) else {
            throw GestaltFailure("The original-value record belongs to a different device.")
        }
        var originals: [String: OriginalField] = [:]
        for (key, entry) in values {
            guard let exists = entry["exists"] as? Bool, exists == (entry["value"] != nil) else {
                throw GestaltFailure("Original values could not be read. No system changes were made.")
            }
            originals[key] = OriginalField(value: entry["value"])
        }
        var audio: CachedOptionsOriginal?
        if let entry = plist["faceTimeAudio"] {
            guard let bytes = entry as? Data,
                  let decoded = try? PropertyListDecoder().decode(CachedOptionsOriginal.self, from: bytes) else {
                throw GestaltFailure("Original values could not be read. No system changes were made.")
            }
            audio = decoded
        }
        var wapi: WAPIOriginal?
        if let entry = plist["wapi"] {
            guard let bytes = entry as? Data,
                  let decoded = try? PropertyListDecoder().decode(WAPIOriginal.self, from: bytes) else {
                throw GestaltFailure("Original values could not be read. No system changes were made.")
            }
            wapi = decoded
        }
        // Recover absent entries once for legacy journals, then migrate any
        // saved cache values that belong to a different system generation.
        let needsMigration = plist["cacheHistoryRecovered"] as? Bool != true
        if needsMigration && (audio == nil || wapi == nil) {
            let recovered = try recoverOriginals(from: document)
            audio = audio ?? recovered.cachedOptions
            wapi = wapi ?? recovered.wapi
        }
        var unavailable: [String: Set<String>] = [:]
        if let stored = plist["unavailableCacheOriginals"] as? [String: Any] {
            for (key, value) in stored {
                // Read the earlier single-UUID representation as a one-item set.
                if let uuid = value as? String { unavailable[key] = [uuid] }
                else if let uuids = value as? [String] { unavailable[key] = Set(uuids) }
                else { throw GestaltFailure("Original values could not be read. No system changes were made.") }
            }
        }
        let currentUUID = document.root["CacheUUID"] as? String ?? ""
        let migrateAudio = audio.map { $0.layoutUUID != currentUUID } == true && !(unavailable["faceTimeAudio"]?.contains(currentUUID) ?? false)
        let migrateWAPI = wapi.map { $0.layoutUUID != currentUUID } == true && !(unavailable["wapi"]?.contains(currentUUID) ?? false)
        if migrateAudio || migrateWAPI {
            let baseline = try recoverCacheBaseline(from: document)
            if migrateAudio {
                if let recovered = baseline.cachedOptions { audio = recovered }
                else { unavailable["faceTimeAudio", default: []].insert(currentUUID) }
            }
            if migrateWAPI {
                if let recovered = baseline.wapi { wapi = recovered }
                else { unavailable["wapi", default: []].insert(currentUUID) }
            }
            // Preserve the complete legacy record before updating either its
            // cache values or the fact that their original state is unavailable.
            try archiveOriginals(data)
        }
        let state = OriginalValues(fields: originals, cachedOptions: audio, wapi: wapi, unavailableCacheOriginals: unavailable)
        if needsMigration || migrateAudio || migrateWAPI { try saveOriginals(state, for: document) }
        return state
    }

    private func matchesCacheGeneration(_ document: GestaltDocument, _ current: GestaltDocument) -> Bool {
        for key in ["CacheUUID", "CacheVersion"] {
            switch (document.root[key], current.root[key]) {
            case (nil, nil): continue
            case (let old?, let live?) where GestaltDocument.valuesEqual(old, live): continue
            default: return false
            }
        }
        switch (document.root["CacheData"], current.root["CacheData"]) {
        case (nil, nil): return true
        case (let old as Data, let live as Data): return old.count == live.count
        default: return false
        }
    }

    private func recoverCacheBaseline(from current: GestaltDocument) throws -> OriginalValues {
        let records = try backups().filter {
            $0.hasTrustedIntegrity && $0.source == .device && $0.deviceID == deviceID &&
                ["Before applying", "Before restoring"].contains($0.reason)
        }.sorted { $0.date < $1.date }
        for record in records {
            // If an earlier payload cannot be verified, its layout and baseline
            // are unknown. Do not guess from a later, potentially modified file.
            guard let data = try? backupData(record), let document = try? GestaltDocument(data: data) else { return OriginalValues() }
            guard document.matchesIdentity(current), matchesCacheGeneration(document, current) else { continue }
            return OriginalValues(cachedOptions: try? CachedOptionsOriginal(document: document),
                                  wapi: try? WAPIOriginal(document: document))
        }
        return OriginalValues()
    }

    private func archiveOriginals(_ data: Data) throws {
        let url = backupDirectory.appendingPathComponent("OriginalValues-" + backupDigest(data) + ".plist")
        do {
            if !FileManager.default.fileExists(atPath: url.path) { try durableProtectedWrite(data, to: url) }
            guard try Data(contentsOf: url) == data else { throw GestaltFailure("Original values could not be saved and verified. No system write was started.") }
        } catch { throw GestaltFailure("Original values could not be saved and verified. No system write was started.") }
    }

    private func recoverOriginals(from current: GestaltDocument) throws -> OriginalValues {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: backupDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return OriginalValues() }
        let records = try backups().filter {
            $0.hasTrustedIntegrity && $0.source == .device && $0.deviceID == deviceID &&
                ["Before applying", "Before restoring"].contains($0.reason)
        }.sorted { $0.date < $1.date }
        var previous: GestaltDocument?
        var originals = OriginalValues()
        for record in records {
            eventSink("Original values: reading backup " + record.id.uuidString)
            let document = try GestaltDocument(data: backupData(record))
            guard document.matchesIdentity(current), matchesCacheGeneration(document, current) else { continue }
            if let previous {
                originals = DocumentSnapshot(data: Data(), document: previous, source: .device, name: "",
                                             originals: originals.fields, cachedOptionsOriginal: originals.cachedOptions, wapiOriginal: originals.wapi)
                    .recordingOriginals(to: document)
            }
            previous = document
        }
        if let previous {
            originals = DocumentSnapshot(data: Data(), document: previous, source: .device, name: "",
                                         originals: originals.fields, cachedOptionsOriginal: originals.cachedOptions, wapiOriginal: originals.wapi)
                .recordingOriginals(to: current)
        }
        if !originals.fields.isEmpty || originals.cachedOptions != nil || originals.wapi != nil {
            eventSink("Original values: recovered from device backups")
        }
        return originals
    }

    private func saveOriginals(_ originals: OriginalValues, for document: GestaltDocument) throws {
        var plist: [String: Any] = ["version": 1, "cacheHistoryRecovered": true,
                                   "deviceID": deviceID, "identity": identity(of: document),
                                   "values": originals.fields.mapValues(\.plist)]
        do {
            if !originals.unavailableCacheOriginals.isEmpty {
                plist["unavailableCacheOriginals"] = originals.unavailableCacheOriginals.mapValues { $0.sorted() }
            }
            if let audio = originals.cachedOptions { plist["faceTimeAudio"] = try PropertyListEncoder().encode(audio) }
            if let wapi = originals.wapi { plist["wapi"] = try PropertyListEncoder().encode(wapi) }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try durableProtectedWrite(data, to: originalsURL)
            guard try Data(contentsOf: originalsURL) == data else {
                throw GestaltFailure("Original values could not be saved and verified. No system write was started.")
            }
            eventSink("Original values: fields and cache flags saved and verified")
        } catch {
            throw GestaltFailure("Original values could not be saved and verified. No system write was started.")
        }
    }

    @discardableResult
    private func saveBackup(_ data: Data, source: DocumentSource, reason: String) throws -> BackupRecord {
        _ = try GestaltDocument(data: data)
        try hardenBackupDirectory()
        let record = BackupRecord(id: UUID(), date: Date(), reason: reason, source: source, deviceID: deviceID,
                                  byteCount: data.count, sha256: backupDigest(data), integrityVersion: 1)
        let url = backupDirectory.appendingPathComponent(record.filename)
        try durableProtectedWrite(data, to: url)
        // A failed backup must stop a write. Verify the backup before creating its metadata.
        guard try Data(contentsOf: url) == data else { throw GestaltFailure("The backup could not be verified. No system write was started.") }
        try durableProtectedWrite(JSONEncoder().encode(record),
                                  to: backupDirectory.appendingPathComponent(record.id.uuidString + ".json"))
        eventSink("Backup: \(data.count) bytes saved and verified")
        return record
    }

    func backup(_ snapshot: DocumentSnapshot) throws {
        if snapshot.source == .device {
            _ = try withAccess {
                let identity = try fileIdentity(deviceURL)
                let data = try readPinnedSystemData(identity: identity)
                return try saveBackup(data, source: .device, reason: "Manual backup")
            }
        } else { try saveBackup(snapshot.data, source: .local, reason: "Manual backup") }
    }

    private func verifiedBackup(_ record: BackupRecord) throws -> (data: Data, metadata: BackupRecord) {
        let metadataURL = backupDirectory.appendingPathComponent(record.id.uuidString + ".json")
        let stored: BackupRecord
        do {
            stored = try JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw GestaltFailure("The backup metadata could not be verified. No system write was started.")
        }
        guard stored.id == record.id, stored.byteCount == record.byteCount,
              record.sha256 == nil || stored.sha256 == nil || record.sha256 == stored.sha256,
              record.integrityVersion == nil || stored.integrityVersion == nil ||
                record.integrityVersion == stored.integrityVersion else {
            throw GestaltFailure("The backup metadata could not be verified. No system write was started.")
        }
        let data = try Data(contentsOf: backupDirectory.appendingPathComponent(record.filename))
        let digest = backupDigest(data)
        let expectedDigest = stored.sha256 ?? record.sha256
        // Older metadata has no creation-time trust provenance. Pin the bytes
        // observed on first read, but do not turn that observation into proof
        // that the payload was intact when the legacy backup was created.
        guard data.count == record.byteCount,
              expectedDigest.map({ $0 == digest }) ?? true else {
            throw GestaltFailure("The backup could not be verified. No system write was started.")
        }
        _ = try GestaltDocument(data: data)
        if stored.integrityVersion == nil {
            let migrated = BackupRecord(id: stored.id, date: stored.date, reason: stored.reason,
                                        source: stored.source, deviceID: stored.deviceID,
                                        byteCount: stored.byteCount, sha256: expectedDigest ?? digest,
                                        integrityVersion: 0)
            try durableProtectedWrite(JSONEncoder().encode(migrated),
                                      to: metadataURL)
            eventSink("Backup: legacy metadata pinned with SHA-256 but kept untrusted")
            return (data, migrated)
        }
        return (data, stored)
    }

    func backupData(_ record: BackupRecord) throws -> Data {
        try verifiedBackup(record).data
    }

    func backupExportData(_ record: BackupRecord, sealingWith seal: @Sendable (Data) throws -> Data) throws -> Data {
        let verified = try verifiedBackup(record)
        // Local, foreign and migrated legacy backups have no ownership proof
        // merely because they are present in this library. Only trusted backups
        // created by this installation receive live-device export proof.
        guard verified.metadata.hasTrustedIntegrity,
              verified.metadata.source == .device, verified.metadata.deviceID == deviceID,
              record.source == verified.metadata.source, record.deviceID == verified.metadata.deviceID else {
            return verified.data
        }
        return try seal(verified.data)
    }

    private func backupDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func deleteBackup(_ record: BackupRecord) throws {
        // Keep the listing metadata until the payload is gone. If removal is
        // denied, the complete backup must remain visible and recoverable.
        do { try removeBackupItem(backupDirectory.appendingPathComponent(record.filename)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A previous attempt may have removed the payload but failed to
            // remove metadata. Only this exact absence permits cleanup to resume.
        }
        try removeBackupItem(backupDirectory.appendingPathComponent(record.id.uuidString + ".json"))
    }

    private func validateRestoreLayout(_ document: GestaltDocument, against current: GestaltDocument) throws {
        let failure = GestaltFailure("This plist uses a different system cache layout and cannot be restored.")
        guard let uuid = document.root["CacheUUID"] as? String, !uuid.isEmpty,
              current.root["CacheUUID"] as? String == uuid,
              let data = document.root["CacheData"] as? Data,
              let currentData = current.root["CacheData"] as? Data, data.count == currentData.count else {
            throw failure
        }
        switch (document.root["CacheVersion"], current.root["CacheVersion"]) {
        case (nil, nil): break
        case (let saved?, let live?) where GestaltDocument.valuesEqual(saved, live): break
        default: throw failure
        }
    }

    func restoreVerifiedImport(_ imported: DocumentSnapshot, expected: DocumentSnapshot) throws -> DocumentSnapshot {
        guard imported.source == .local, imported.ownershipVerified, expected.source == .device else {
            throw GestaltFailure("This plist's device proof could not be verified on this device.")
        }
        try validateRestoreLayout(imported.document, against: expected.document)
        if imported.document.matches(expected.document) {
            return try withAccess {
                _ = try currentData(matching: expected)
                eventSink("Restore: the device already matches this plist")
                return expected
            }
        }
        let record = try saveBackup(imported.data, source: .device, reason: "Verified import")
        return try commit(imported.document, expected: expected, restoring: record)
    }

    private func currentData(matching expected: DocumentSnapshot) throws
        -> (data: Data, identity: (device: UInt64, inode: UInt64)) {
        let identity = try fileIdentity(deviceURL)
        let current = try readPinnedSystemData(identity: identity)
        guard current == expected.data else { throw GestaltFailure("MobileGestalt changed since it was loaded. Refresh before applying your edits.") }
        return (current, identity)
    }

    func commit(_ edited: GestaltDocument, expected: DocumentSnapshot, restoring record: BackupRecord? = nil,
                originallyAbsentKeys: Set<String> = []) throws -> DocumentSnapshot {
        guard expected.source != .device || edited.preservesDeviceIdentity(of: expected.document) else {
            throw GestaltFailure("Device identity fields cannot be changed in the system plist. Open a local file to edit these fields.")
        }
        if record == nil { try DeviceCacheOptions.validateEdit(from: expected.document, to: edited) }
        guard originallyAbsentKeys.allSatisfy({ edited.extra[$0] == nil }) else {
            throw GestaltFailure("The selected added fields must be removed before applying.")
        }
        let output = try edited.encoded()
        guard expected.source == .device else {
            try saveBackup(expected.data, source: .local, reason: "Before editing")
            var originals = expected.recordingOriginals(to: edited)
            for key in originallyAbsentKeys { originals.fields[key] = OriginalField(value: nil) }
            // A backup replaces the imported payload. Its ownership has not been
            // verified merely because the previously open document was verified.
            let ownershipVerified = record == nil && expected.ownershipVerified
            return DocumentSnapshot(data: output, document: edited, source: .local, name: expected.name,
                                    originals: originals.fields, cachedOptionsOriginal: originals.cachedOptions, wapiOriginal: originals.wapi, ownershipVerified: ownershipVerified)
        }
        if let record {
            let verifiedRecord = try verifiedBackup(record).metadata
            guard verifiedRecord.hasTrustedIntegrity else {
                throw GestaltFailure("This legacy backup has no trustworthy creation-time integrity proof and cannot be restored.")
            }
            guard verifiedRecord.source == .device, verifiedRecord.deviceID == deviceID,
                  record.source == verifiedRecord.source, record.deviceID == verifiedRecord.deviceID,
                  edited.matchesIdentity(expected.document) else {
                throw GestaltFailure("This backup does not belong to this device. Open it as a local file instead.")
            }
            // Device ownership alone does not make an older OS cache compatible.
            // Apply the same layout checks to saved backups and verified imports.
            try validateRestoreLayout(edited, against: expected.document)
        }
        return try withAccess {
            let observed = try currentData(matching: expected)
            let current = observed.data
            // A restore can be semantically identical even when the source uses
            // a different plist encoding. Validate freshness before skipping it.
            if record != nil, originallyAbsentKeys.isEmpty, edited.matches(expected.document) {
                eventSink("Restore: the device already matches this plist")
                return expected
            }
            var baseline = expected
            let saved = try loadOriginals(for: expected.document)
            // Resolve old history before creating today's pre-write backup, so
            // this current (possibly already modified) state cannot migrate it.
            try saveBackup(current, source: .device, reason: record == nil ? "Before applying" : "Before restoring")
            baseline.originals.merge(saved.fields) { _, saved in saved }
            if let audio = saved.cachedOptions { baseline.cachedOptionsOriginal = audio }
            if let wapi = saved.wapi { baseline.wapiOriginal = wapi }
            var originals = baseline.recordingOriginals(to: edited)
            originals.unavailableCacheOriginals = saved.unavailableCacheOriginals
            // Explicitly removing a user-confirmed added field also corrects
            // old zero/one residues whose earlier origin was not recorded.
            for key in originallyAbsentKeys { originals.fields[key] = OriginalField(value: nil) }
            // Persist absence as well as typed values before the system write.
            // This record is separate from deletable full-file backups.
            try saveOriginals(originals, for: expected.document)
            let identity = observed.identity
            return try withLockedPinnedSystemFile(identity: identity) { descriptor in
                guard try readDescriptorData(descriptor) == current else {
                    throw GestaltFailure("MobileGestalt changed since it was loaded. Refresh before applying your edits.")
                }
                try verifyPinnedDescriptor(descriptor, identity: identity, action: "preparing to write")
                var journalStarted = false
                var systemWriteAttempted = false
                do {
                    // The extension cannot atomically replace this system file.
                    // Hold the same inode lock while publishing the full-sync'd
                    // journal, changing bytes, verifying readback and deleting
                    // the journal so cooperating writers cannot interleave.
                    try beginPendingSystemWrite(original: current, intended: output, identity: identity)
                    journalStarted = true
                    eventSink("Write: \(output.count) bytes")
                    systemWriteAttempted = true
                    if let writeData { try writeData(output, deviceURL) }
                    else {
                        try replaceLockedSystemData(output, expected: current,
                                                    descriptor: descriptor, identity: identity)
                    }
                    eventSink("Readback: comparing full plist and value types")
                    let readback = try readDescriptorData(descriptor)
                    try verifyPinnedDescriptor(descriptor, identity: identity, action: "verifying readback")
                    guard readback == output,
                          try edited.matches(GestaltDocument(data: readback)) else {
                        throw GestaltFailure("The write did not match the readback.")
                    }
                    try synchronizeLockedSystemData(output, descriptor: descriptor, identity: identity)
                    try clearPendingSystemWrite()
                    journalStarted = false
                    eventSink("Readback: verified")
                    return DocumentSnapshot(data: readback, document: edited, source: .device,
                                            name: expected.name, originals: originals.fields,
                                            cachedOptionsOriginal: originals.cachedOptions,
                                            wapiOriginal: originals.wapi)
                } catch {
                    eventSink("Write/readback failed: " + error.localizedDescription)
                    if !systemWriteAttempted {
                        if journalStarted { try? clearPendingSystemWrite() }
                        throw error
                    }
                    let recovery: FailedWriteRecovery
                    do {
                        recovery = try recoverFailedSystemWrite(original: current, intended: output,
                                                                identity: identity, descriptor: descriptor)
                    } catch {
                        throw GestaltFailure("Write verification and recovery stopped without overwriting unknown bytes. Keep the backup and recovery journal before trying again.")
                    }
                    switch recovery {
                    case .unchanged:
                        throw GestaltFailure("The write failed before changing the system file. The recovery journal was cleared.")
                    case .restored:
                        throw GestaltFailure("The write failed. The previous file was restored and verified.")
                    case .intendedPresent:
                        throw GestaltFailure("The intended bytes are present, but write durability was not verified. Keep the recovery journal and reload before continuing.")
                    }
                }
            }
        }
    }
}
