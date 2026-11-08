import Foundation
import CryptoKit
let args = CommandLine.arguments
func write(_ data: Data, _ path: String, privateFile: Bool = false) throws {
    let url = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    if privateFile { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
}
if args.count == 4 && args[1] == "keygen" {
    let privateURL = URL(fileURLWithPath: args[2]), publicURL = URL(fileURLWithPath: args[3])
    if FileManager.default.fileExists(atPath: privateURL.path) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: privateURL))
        guard (try? String(contentsOf: publicURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == key.publicKey.rawRepresentation.base64EncodedString() else { fatalError("Existing update key mismatch; do not silently rotate") }
    } else {
        guard !FileManager.default.fileExists(atPath: publicURL.path) else { fatalError("Private signing key missing. Supply original key or explicitly rotate for your fork") }
        let key = Curve25519.Signing.PrivateKey(); try write(key.rawRepresentation, args[2], privateFile: true)
        try write(Data((key.publicKey.rawRepresentation.base64EncodedString()+"\n").utf8), args[3])
    }
} else if args.count == 5 && args[1] == "sign" {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let envelope = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString()]
    try write(JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .prettyPrinted]), args[4])
} else { fputs("Usage: sign_update.swift keygen private-key public-key | sign private-key payload.json release.json\n", stderr); exit(2) }
