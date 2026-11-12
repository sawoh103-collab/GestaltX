import Foundation
import CryptoKit
struct ProofTestError: Error {}
func reject(_ action: () throws -> Void) throws {
    do { try action() } catch is ProofTestError { throw ProofTestError() } catch { return }
    throw ProofTestError()
}
@main struct DeviceBoundPlistTests {
    static func main() throws {
        let root: [String: Any] = ["CacheExtra": ["integer": 1, "boolean": true, "value": "fixture"], "CacheData": Data([1, 2, 3])]
        let plain = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let key = Data(repeating: 19, count: 32), otherDevice = Data(repeating: 23, count: 32)
        let exported = try DeviceBoundPlist.seal(plain, key: key)
        let encrypted = try PropertyListSerialization.propertyList(from: exported, options: [], format: nil) as! [String: Any]
        precondition(encrypted.count == 1 && encrypted["CacheExtra"] == nil)
        precondition((encrypted[DeviceBoundPlist.proofKey] as? [String: Any])?["version"] as? Int == 2)
        try SharedPlistInbox.validate(exported)
        let opened = try DeviceBoundPlist.verify(exported, key: key)
        let before = try GestaltDocument(data: plain), after = try GestaltDocument(data: opened)
        precondition(before.matches(after))
        precondition(!after.root.keys.contains(DeviceBoundPlist.proofKey))
        try reject { _ = try DeviceBoundPlist.verify(exported, key: otherDevice) }
        var outer = encrypted
        var proof = outer[DeviceBoundPlist.proofKey] as! [String: Any]
        var sealed = proof["sealed"] as! Data
        sealed[sealed.startIndex] ^= 1
        proof["sealed"] = sealed
        outer[DeviceBoundPlist.proofKey] = proof
        let tampered = try PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0)
        try reject { _ = try DeviceBoundPlist.verify(tampered, key: key) }

        // Keep importing v1 files emitted by GestaltX 1.0.5 and earlier.
        let tag = Data(HMAC<SHA256>.authenticationCode(for: plain, using: SymmetricKey(data: key)))
        var legacy = root
        legacy[DeviceBoundPlist.proofKey] = ["version": 1, "payload": plain, "tag": tag]
        let legacyExport = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        precondition(try GestaltDocument(data: DeviceBoundPlist.verify(legacyExport, key: key)).matches(before))
        print("PASS: encrypted device backup, legacy proof import, foreign-key rejection, exact typed payload, tampering rejection and proof stripping before restoration.")
    }
}
