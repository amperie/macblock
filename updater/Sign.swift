import Foundation
import CryptoKit
import Darwin

// Private keys travel over stdin, never argv or build logs.
umask(0o077)
do {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "--generate-key" {
        let key = Curve25519.Signing.PrivateKey()
        let path = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: path.path) else { throw NSError(domain: "Key already exists", code: 1) }
        try key.rawRepresentation.base64EncodedData().write(to: path, options: .withoutOverwriting)
        print(key.publicKey.rawRepresentation.base64EncodedString())
    } else if args.count == 5 && args[1] == "--sign" {
        let input = FileHandle.standardInput.readData(ofLength: 1024)
        guard let string = String(data: input, encoding: .utf8),
              let bytes = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NSError(domain: "Invalid key", code: 1) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        guard key.publicKey.rawRepresentation.base64EncodedString() == args[4] else { throw NSError(domain: "Signing key does not match pinned public key", code: 1) }
        let manifest = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard manifest.count <= 16384 else { throw NSError(domain: "Manifest too large", code: 1) }
        try key.signature(for: manifest).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    } else { throw NSError(domain: "Use --generate-key PRIVATE_PATH or --sign MANIFEST SIGNATURE PUBLIC_KEY", code: 1) }
} catch { fputs("Signing failed: \(error)\n", stderr); exit(1) }
