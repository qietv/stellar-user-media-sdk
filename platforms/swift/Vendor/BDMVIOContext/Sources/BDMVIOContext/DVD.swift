//
//  DVD.swift
//  BDMVIOContext
//
//  Created by kintan on 3/21/25.
//

import Foundation
import KSPlayer

struct DVD {
    let name: String
    let duration: TimeInterval
    let playFiles: [PlayFileProtocol]
}

extension DVD: MovieStream {}

extension UnsafeMutablePointer<UInt8> {
    /// https://dvd.sourceforge.net/dvdinfo/ifo.html
    func parseVTSIFOFile(count: Int, name: String, files: [DownloadProtocol & CustomStringConvertible]) -> [DVD] {
        var index = 0
        let header = readString(&index, count: 12)
        assert(header == "DVDVIDEO-VTS", "invalid IFO Header")
        let vtsPgciSector = read4(0xCC)
        let vtsPgciOffset = Int(vtsPgciSector) * 2048
        assert(vtsPgciOffset > 0 && vtsPgciOffset < count, "Incorrect vtsPgciOffset")
        let numberOfPGCs = read2(vtsPgciOffset)
        assert(numberOfPGCs > 0, "Incorrect numberOfPGCs")
        var dvds: [DVD] = []
        let searchPointerTableOffset = vtsPgciOffset + 8
        for i in 0 ..< Int(numberOfPGCs) {
            let entryOffset = searchPointerTableOffset + (i * 8)
            let pgcOffset = vtsPgciOffset + Int(read4(entryOffset + 4))
            let numberOfCells = read(pgcOffset + 3)
            let duration = parseBCDTime(at: pgcOffset + 4)
            let cellPlaybackOffset = read2(pgcOffset + 0xE8)
            let cellPositionOffset = read2(pgcOffset + 0xEA)
            assert(cellPlaybackOffset > 0, "Incorrect cellPlaybackOffset")
            let cellTableOffset = pgcOffset + Int(cellPlaybackOffset)
            let cellPositionTableOffset = pgcOffset + Int(cellPositionOffset)
            var allCells = [CellInfo]()
            for c in 0 ..< Int(numberOfCells) {
                let cellOffset = cellTableOffset + (c * 0x18)
                guard cellOffset + 24 <= count else { continue }
                let duration = parseBCDTime(at: cellOffset + 4)
                let firstSector = read4(cellOffset + 8)
                let lastSector = read4(cellOffset + 0x14)
                var vobID = 1
                var cellID = c + 1
                if cellPositionOffset > 0 {
                    let cellPositionEntryOffset = cellPositionTableOffset + (c * 4)
                    if cellPositionEntryOffset + 4 <= count {
                        vobID = Int(read2(cellPositionEntryOffset))
                        cellID = Int(read(cellPositionEntryOffset + 3))
                    }
                }
                let cell = CellInfo(
                    cellNumber: c + 1,
                    cellID: cellID,
                    vobID: vobID,
                    duration: duration,
                    firstSector: firstSector,
                    lastSector: lastSector
                )
                allCells.append(cell)
            }
            allCells.sort { $0.firstSector < $1.firstSector }
            let totalDuration = allCells.reduce(0) { $0 + $1.duration }
            var playFiles = [PlayFile]()
            var end = Int64(0)
            var startTime = Double(0)
            var currentSector: UInt32 = 0
            for file in files {
                let sectorCount = UInt32(file.fileSize() / Int64(2048))
                let vobStartSector = currentSector
                let vobEndSector = currentSector + sectorCount - 1
                var fileDuration = Double(0)
                for cell in allCells {
                    if cell.lastSector >= vobStartSector, cell.firstSector <= vobEndSector {
                        let cellStart = max(cell.firstSector, vobStartSector)
                        let cellEnd = min(cell.lastSector, vobEndSector)
                        let cellTotalSectors = cell.lastSector - cell.firstSector + 1
                        let cellInVOBSectors = cellEnd - cellStart + 1
                        let ratio = Double(cellInVOBSectors) / Double(cellTotalSectors)
                        fileDuration += cell.duration * ratio
                    }
                }
                if fileDuration > 0 {
                    end += file.fileSize()
                    playFiles.append(PlayFile(file: file, startTime: startTime, duration: fileDuration, end: end))
                    startTime += fileDuration
                }
                currentSector = vobEndSector + 1
            }
            dvds.append(DVD(name: name + i.description, duration: duration, playFiles: playFiles))
        }
        return dvds
    }

    private func parseBCDTime(at offset: Int) -> Double {
        var index = offset
        let hour = read(&index).bcd()
        let minute = read(&index).bcd()
        let second = read(&index).bcd()
        let framesByte = read(&index)
        let frames = Int(((framesByte & 0x3F) >> 4) * 10 + (framesByte & 0x0F))
        let frameRateCode = (framesByte >> 6) & 0x03
        let frameRate: Double = (frameRateCode == 1) ? 25.0 : 29.97
        return Double(hour * 3600 + minute * 60 + second) + Double(frames) / frameRate
    }
}

extension UInt8 {
    func bcd() -> Int {
        Int((self >> 4) * 10 + (self & 0x0F))
    }
}

struct CellInfo: Hashable {
    let cellNumber: Int
    let cellID: Int
    let vobID: Int
    let duration: Double
    let firstSector: UInt32
    let lastSector: UInt32
}
