//
//  MPLS.swift
//  BDMVIOContext
//
//  Created by kintan on 1/18/25.
//

import Foundation
import KSPlayer

extension UnsafeMutablePointer<UInt8> {
    func read(_ index: Int) -> UInt8 {
        self[index]
    }

    func read(_ index: inout Int) -> UInt8 {
        let result = self[index]
        index += 1
        return result
    }

    func read2(_ index: Int) -> UInt16 {
        UInt16(self[index]) << 8 + UInt16(self[index + 1])
    }

    func read2(_ index: inout Int) -> UInt16 {
        let result = UInt16(self[index]) << 8 + UInt16(self[index + 1])
        index += 2
        return result
    }

    func read4(_ index: Int) -> UInt32 {
        UInt32(self[index]) << 24 + UInt32(self[index + 1]) << 16 + UInt32(self[index + 2]) << 8 + UInt32(self[index + 3])
    }

    func read4(_ index: inout Int) -> UInt32 {
        let result = UInt32(self[index]) << 24 + UInt32(self[index + 1]) << 16 + UInt32(self[index + 2]) << 8 + UInt32(self[index + 3])
        index += 4
        return result
    }

    func read(_ index: inout Int, count: Int) -> UnsafeMutablePointer<UInt8> {
        let result = advanced(by: count)
        index += count
        return result
    }

    func readString(_ index: inout Int, count: Int) -> String {
        let decoding = (0 ..< count).map { i in
            self[index + i]
        }
        let result = String(decoding: decoding, as: UTF8.self)
        index += count
        return result
    }
}

struct MPLSPlayItem {
    let isMultiAngle: Bool
    let connectionCondition: UInt8
    let inTime: UInt32
    let outTime: UInt32
    let clip: [MPLSClip]
    let stn: MPLSStn
}

struct MPLSClip {
    let clipID: String
    let codecID: String
    let stcID: UInt8
}

struct MPLSStn {
    let audio: [MPLSStream]
    let pg: [MPLSStream]
    let ig: [MPLSStream]
}

struct MPLSStream {
    let pid: UInt16
    let lang: String
}

struct MPLSPlayMark {
    let type: UInt8
    let playItemRef: UInt16
    let time: UInt32
    let entryESPid: UInt16
    let duration: UInt32
}

struct MPLS {
    let name: String
    let files: [String]
    let playFiles: [PlayFileProtocol]
    let playItems: [MPLSPlayItem]
    let playMarks: [MPLSPlayMark]
    let size: Int64
    let duration: TimeInterval
    init(name: String, playItems: [MPLSPlayItem], playMarks: [MPLSPlayMark], fileMap: [String: DownloadProtocol & CustomStringConvertible]) throws {
        self.name = name
        self.playItems = playItems
        self.playMarks = playMarks
        var files = [String]()
        var playFiles = [PlayFile]()
        for item in playItems {
            for clip in item.clip {
                let file = clip.clipID + "." + clip.codecID.lowercased()
                // 会出现都是同一个文件的情况，如果相加的话，就会变得很大。所以要进行过滤下。
                if !files.contains(file) {
                    files.append(file)
                    if let udfFile = fileMap[file] {
                        let startTime: TimeInterval
                        let end: Int64
                        if let last = playFiles.last {
                            startTime = last.startTime + last.duration
                            end = last.end
                        } else {
                            startTime = 0
                            end = 0
                        }
                        let fileSize = udfFile.fileSize()
                        let (nextEnd, overflow) = end.addingReportingOverflow(fileSize)
                        guard fileSize >= 0, !overflow, item.outTime >= item.inTime else {
                            throw MPLSParseError.invalidData
                        }
                        let playFile = PlayFile(
                            file: udfFile,
                            startTime: startTime,
                            duration: TimeInterval(item.outTime - item.inTime) / 45000.0,
                            end: nextEnd
                        )
                        playFiles.append(playFile)
                    }
                }
            }
        }
        if let last = playFiles.last {
            duration = last.startTime + last.duration
            size = last.end
        } else {
            duration = 0
            size = 0
        }
        self.playFiles = playFiles
        self.files = files
    }
}

extension MPLS: MovieStream {}

struct PlayFile: PlayFileProtocol {
    let file: DownloadProtocol & CustomStringConvertible
    let startTime: TimeInterval
    let duration: TimeInterval
//    let pos: Int64
    let end: Int64
    var size: Int64 {
        file.fileSize()
    }
}

extension PlayFile: MovieStream {
    var name: String {
        file.description
    }

    var playFiles: [any KSPlayer.PlayFileProtocol] {
        [self]
    }
}

extension [PlayFile]: MovieStream {
    public var duration: TimeInterval {
        if let last {
            return last.startTime + last.duration
        } else {
            return 0
        }
    }

    public var name: String {
        first?.file.description ?? ""
    }

    public var playFiles: [any KSPlayer.PlayFileProtocol] {
        self
    }
}
