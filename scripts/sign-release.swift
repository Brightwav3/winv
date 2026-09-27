// Signs a release DMG for WinV's updater (Ed25519, detached, base64).
//
//   swift scripts/sign-release.swift keygen        # once: writes ~/.winv-signing-key, prints the public key
//   swift scripts/sign-release.swift build/WinV.dmg  # writes build/WinV.dmg.sig
//
// Paste the public key into `Updater.publicKey`, then upload WinV.dmg.sig next to WinV.dmg on every release.
// Keep ~/.winv-signing-key private and backed up; never commit it.
import CryptoKit
import Foundation

let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".winv-signing-key")
let args = CommandLine.arguments.dropFirst()

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

if args.first == "keygen" {
    guard !FileManager.default.fileExists(atPath: keyFile.path) else { fail("\(keyFile.path) already exists.") }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print("Private key: \(keyFile.path)")
    print("Public key (Updater.publicKey): \(key.publicKey.rawRepresentation.base64EncodedString())")
} else if let path = args.first {
    guard let raw = try? String(contentsOf: keyFile, encoding: .utf8),
          let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("No key; run keygen first.") }
    let dmg = try Data(contentsOf: URL(fileURLWithPath: path))
    let sig = try key.signature(for: dmg).base64EncodedString()
    try sig.write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("Wrote \(path).sig")
} else {
    fail("usage: swift scripts/sign-release.swift keygen | <path/to/WinV.dmg>")
}
