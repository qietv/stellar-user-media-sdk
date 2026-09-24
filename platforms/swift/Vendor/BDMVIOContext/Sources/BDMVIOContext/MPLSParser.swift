import Foundation
import KSPlayer

enum MPLSParseError: Error {
  case invalidData
  case incompleteRead
}

/// Every nested reader is bounded by both its enclosing section and the bytes actually read.
/// File offsets and counts are untrusted, including when the filename ends in .mpls.
private struct MPLSReader {
  let bytes: [UInt8]
  var position: Int
  let end: Int

  init(_ bytes: [UInt8]) {
    self.bytes = bytes
    position = 0
    end = bytes.count
  }

  private init(bytes: [UInt8], position: Int, end: Int) {
    self.bytes = bytes
    self.position = position
    self.end = end
  }

  mutating func take(_ count: Int) throws -> MPLSReader {
    guard count >= 0, position <= end, count <= end - position else {
      throw MPLSParseError.invalidData
    }
    let result = MPLSReader(bytes: bytes, position: position, end: position + count)
    position += count
    return result
  }

  mutating func skip(_ count: Int) throws { _ = try take(count) }

  mutating func byte() throws -> UInt8 {
    let slice = try take(1)
    return bytes[slice.position]
  }

  mutating func uint16() throws -> UInt16 {
    let high = try byte()
    return try (UInt16(high) << 8) | UInt16(byte())
  }

  mutating func uint32() throws -> UInt32 {
    let high = try uint16()
    return try (UInt32(high) << 16) | UInt32(uint16())
  }

  mutating func string(_ count: Int) throws -> String {
    let slice = try take(count)
    return String(decoding: bytes[slice.position..<slice.end], as: UTF8.self)
  }

  func section(at offset: UInt32) throws -> MPLSReader {
    guard offset >= 20, Int(offset) <= end else { throw MPLSParseError.invalidData }
    var reader = MPLSReader(bytes: bytes, position: Int(offset), end: end)
    let length = try reader.uint32()
    return try reader.take(Int(length))
  }
}

extension MPLS {
  static func parse(
    bytes: [UInt8], name: String,
    fileMap: [String: DownloadProtocol & CustomStringConvertible]
  ) throws -> MPLS {
    var header = MPLSReader(bytes)
    guard try header.string(4) == "MPLS",
      try ["0100", "0200", "0300"].contains(header.string(4))
    else { throw MPLSParseError.invalidData }
    let listPosition = try header.uint32()
    let markPosition = try header.uint32()
    let extensionPosition = try header.uint32()
    var list = try header.section(at: listPosition)
    try list.skip(2)
    let itemCount = try list.uint16()
    _ = try list.uint16()  // Subpaths are not projected by this dependency.
    var items = [MPLSPlayItem]()
    for _ in 0..<Int(itemCount) {
      let length = try list.uint16()
      var item = try list.take(Int(length))
      items.append(try parseItem(&item))
    }
    var marks = [MPLSPlayMark]()
    if markPosition != 0 {
      var reader = try header.section(at: markPosition)
      let count = try reader.uint16()
      for _ in 0..<Int(count) {
        try reader.skip(1)
        let type = try reader.byte()
        let reference = try reader.uint16()
        guard reference < itemCount else { throw MPLSParseError.invalidData }
        marks.append(
          try MPLSPlayMark(
            type: type, playItemRef: reference, time: reader.uint32(),
            entryESPid: reader.uint16(), duration: reader.uint32()
          ))
      }
    }
    if extensionPosition != 0 { _ = try header.section(at: extensionPosition) }
    return try MPLS(name: name, playItems: items, playMarks: marks, fileMap: fileMap)
  }

  private static func parseClip(_ reader: inout MPLSReader) throws -> MPLSClip {
    let id = try reader.string(5)
    let codec = try reader.string(4)
    guard id.utf8.allSatisfy({ (48...57).contains($0) }),
      codec == "M2TS" || codec == "FMTS"
    else { throw MPLSParseError.invalidData }
    return try MPLSClip(clipID: id, codecID: codec, stcID: reader.byte())
  }

  private static func parseItem(_ reader: inout MPLSReader) throws -> MPLSPlayItem {
    let id = try reader.string(5)
    let codec = try reader.string(4)
    guard id.utf8.allSatisfy({ (48...57).contains($0) }),
      codec == "M2TS" || codec == "FMTS"
    else { throw MPLSParseError.invalidData }
    try reader.skip(1)
    let flags = try reader.byte()
    let multiAngle = flags & 0x10 != 0
    let connection = flags & 0x0f
    guard [1, 5, 6].contains(connection) else { throw MPLSParseError.invalidData }
    let stcID = try reader.byte()
    let inTime = try reader.uint32()
    let outTime = try reader.uint32()
    guard outTime >= inTime else { throw MPLSParseError.invalidData }
    try reader.skip(12)  // UO mask, random access flag, still mode and still time.
    var clips = [MPLSClip(clipID: id, codecID: codec, stcID: stcID)]
    if multiAngle {
      let count = try reader.byte()
      guard count > 0 else { throw MPLSParseError.invalidData }
      try reader.skip(1)
      for _ in 1..<Int(count) { clips.append(try parseClip(&reader)) }
    }
    let stnLength = try reader.uint16()
    var stn = try reader.take(Int(stnLength))
    return try MPLSPlayItem(
      isMultiAngle: multiAngle, connectionCondition: connection,
      inTime: inTime, outTime: outTime, clip: clips, stn: parseSTN(&stn)
    )
  }

  private static func parseSTN(_ reader: inout MPLSReader) throws -> MPLSStn {
    try reader.skip(2)
    let videoCount = try reader.byte()
    let audioCount = try reader.byte()
    let pgCount = try reader.byte()
    let igCount = try reader.byte()
    try reader.skip(2)  // Secondary audio/video counts.
    let pipCount = try reader.byte()
    try reader.skip(5)  // Dolby Vision count and reserved bytes.
    for _ in 0..<Int(videoCount) { _ = try parseStream(&reader) }
    var audio = [MPLSStream]()
    for _ in 0..<Int(audioCount) { audio.append(try parseStream(&reader)) }
    var pg = [MPLSStream]()
    for _ in 0..<(Int(pgCount) + Int(pipCount)) { pg.append(try parseStream(&reader)) }
    var ig = [MPLSStream]()
    for _ in 0..<Int(igCount) { ig.append(try parseStream(&reader)) }
    return MPLSStn(audio: audio, pg: pg, ig: ig)
  }

  private static func parseStream(_ reader: inout MPLSReader) throws -> MPLSStream {
    let entryLength = try reader.byte()
    var entry = try reader.take(Int(entryLength))
    let type = try entry.byte()
    let pid: UInt16
    switch type {
    case 1: pid = try entry.uint16()
    case 2:
      try entry.skip(2)
      pid = try entry.uint16()
    case 3, 4:
      try entry.skip(1)
      pid = try entry.uint16()
    default: pid = 0
    }
    let attributesLength = try reader.byte()
    var attributes = try reader.take(Int(attributesLength))
    let coding = try attributes.byte()
    let language: String
    switch coding {
    case 0x03, 0x04, 0x80...0x86, 0xa1, 0xa2, 0x92:
      try attributes.skip(1)
      language = try attributes.string(3)
    case 0x90, 0x91: language = try attributes.string(3)
    default: language = ""
    }
    return MPLSStream(pid: pid, lang: language)
  }
}
