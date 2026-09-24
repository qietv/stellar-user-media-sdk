#!/usr/bin/env swift

import CryptoKit
import Foundation

private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
  [
    UInt8((value >> 24) & 0xff),
    UInt8((value >> 16) & 0xff),
    UInt8((value >> 8) & 0xff),
    UInt8(value & 0xff),
  ]
}

private func bigEndianBytes(_ value: UInt16) -> [UInt8] {
  [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func mpls(clipID: String) -> Data {
  precondition(clipID.utf8.count == 5)
  var bytes = [UInt8](repeating: 0, count: 96)
  bytes.replaceSubrange(0..<8, with: Array("MPLS0100".utf8))
  bytes.replaceSubrange(8..<12, with: bigEndianBytes(UInt32(20)))
  bytes.replaceSubrange(12..<16, with: bigEndianBytes(UInt32(84)))
  bytes.replaceSubrange(16..<20, with: bigEndianBytes(UInt32(0)))
  bytes.replaceSubrange(20..<24, with: bigEndianBytes(UInt32(56)))
  bytes.replaceSubrange(26..<28, with: bigEndianBytes(UInt16(1)))
  bytes.replaceSubrange(28..<30, with: bigEndianBytes(UInt16(0)))
  bytes.replaceSubrange(30..<32, with: bigEndianBytes(UInt16(48)))
  bytes.replaceSubrange(32..<37, with: Array(clipID.utf8))
  bytes.replaceSubrange(37..<41, with: Array("M2TS".utf8))
  bytes[42] = 1
  bytes.replaceSubrange(44..<48, with: bigEndianBytes(UInt32(0)))
  bytes.replaceSubrange(48..<52, with: bigEndianBytes(UInt32(450_000)))
  bytes.replaceSubrange(64..<66, with: bigEndianBytes(UInt16(14)))
  bytes.replaceSubrange(84..<88, with: bigEndianBytes(UInt32(2)))
  bytes.replaceSubrange(88..<90, with: bigEndianBytes(UInt16(0)))
  return Data(bytes)
}

private func run(_ executable: String, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw NSError(
      domain: "StellarDiscFixtureGenerator",
      code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: "\(executable) failed"]
    )
  }
}

let scriptURL = URL(fileURLWithPath: #filePath)
let outputBaseURL = scriptURL.deletingLastPathComponent().appendingPathComponent("minimal-bdmv")
let outputURL = outputBaseURL.appendingPathExtension("iso")
let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
  "stellar-minimal-bdmv-\(UUID().uuidString)",
  isDirectory: true
)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }

let playlist = temporaryRoot.appendingPathComponent("BDMV/PLAYLIST", isDirectory: true)
let stream = temporaryRoot.appendingPathComponent("BDMV/STREAM", isDirectory: true)
try FileManager.default.createDirectory(at: playlist, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: stream, withIntermediateDirectories: true)
try Data([0]).write(to: temporaryRoot.appendingPathComponent("BDMV/index.bdmv"))
try mpls(clipID: "00001").write(to: playlist.appendingPathComponent("00000.mpls"))
try mpls(clipID: "00002").write(to: playlist.appendingPathComponent("00001.mpls"))
try mpls(clipID: "00001").write(to: playlist.appendingPathComponent("00002.mpls"))
// Regression for the Xcode crash: PLAYLIST can also contain unrelated text and AppleDouble files.
let text = Data((0..<17_024).map { UInt8(49 + ($0 % 9)) })
try text.write(to: playlist.appendingPathComponent("1234567912.txt"))
try text.write(to: playlist.appendingPathComponent("._00000.mpls"))
try Data(repeating: 0x11, count: 2_048).write(to: stream.appendingPathComponent("00001.m2ts"))
try Data(repeating: 0x22, count: 4_096).write(to: stream.appendingPathComponent("00002.m2ts"))

try? FileManager.default.removeItem(at: outputURL)
try run(
  "/usr/bin/hdiutil",
  [
    "makehybrid", "-quiet", "-udf", "-default-volume-name", "STELLAR_TEST_DISC",
    "-o", outputBaseURL.path, temporaryRoot.path,
  ]
)

let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
let checksumURL = outputURL.appendingPathExtension("sha256")
try Data("\(digest)  \(outputURL.lastPathComponent)\n".utf8).write(to: checksumURL)
print("\(outputURL.path)\nsize=\(data.count)\nsha256=\(digest)")
