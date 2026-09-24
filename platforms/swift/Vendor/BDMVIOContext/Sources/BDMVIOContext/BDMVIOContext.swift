//
//  BDMVIOContext.swift
//
//
//  Created by kintan on 7/20/24.
//

import FFmpegKit
import Foundation
import KSPlayer
import Libavformat
import udfread

public class BDMVIOContext: AbstractAVIOContext, PlayList {
    public private(set) var audioLanguageCodeMap = [Int32: String]()
    public private(set) var subtitleLanguageCodeMap = [Int32: String]()
    private let filesManager: FilesManager
    private var isClosed = false
    private let udfMpls: UDFMpls
    public let currentStream: MovieStream?
    public let playlists: [MovieStream]

    public convenience init(url: URL, formatContextOptions: [String: Any], interrupt: AVIOInterruptCB, streamName: String? = nil) async throws {
        // 支持bluray开头的本地文件
        if url.scheme == "bluray" || url.isFileURL {
            await try self.init(download: LocalFileDownload(url: url), streamName: streamName)
        } else {
            await try self.init(download: URLContextCompleteDownload(url: url, formatContextOptions: formatContextOptions, interrupt: interrupt), streamName: streamName)
        }
    }

    /**
     URLContextCompleteDownload相比于URLContextCompleteDownload，下载速度会更快.
     */
    public convenience init(download: DownloadProtocol, bufferSize: Int32 = 512 * 1024, streamName: String? = nil) async throws {
        let filesManager = UDFFilesManager(download: download)
        guard filesManager.open() else {
            filesManager.close()
            throw KSPlayerError(description: "[BDMVIOContext] Failed to open UDF input")
        }
        try await self.init(filesManager: filesManager, bufferSize: bufferSize, streamName: streamName)
    }

    public init(filesManager: FilesManager, bufferSize: Int32 = 512 * 1024, streamName: String? = nil) async throws {
        self.filesManager = filesManager
        var initialized = false
        defer { if !initialized { filesManager.close() } }
        let bdmvContents = try await filesManager.contentsOfDirectory(atPath: "/BDMV")
        if !bdmvContents.isEmpty {
            // BDMV/PLAYLIST
            guard let playlist = bdmvContents.first(where: { $0.name == "PLAYLIST" }) else {
                throw KSPlayerError(description: "[BDMVIOContext] can not find /BDMV/PLAYLIST")
            }
            // BDMV/STREAM
            guard let stream = bdmvContents.first(where: { $0.name == "STREAM" }) else {
                throw KSPlayerError(description: "[BDMVIOContext] can not find /BDMV/STREAM")
            }
            let fileMap = try await filesManager.downloads(atPath: stream.path).toDictionary { $0.description }
            // 就算streamName有值，也需要解析所有的mpls，不然就无法选择mpls了
            let files = try await filesManager.downloads(atPath: playlist.path)
            var playlists = [MPLS]()
            for file in files {
                guard !file.description.hasPrefix("."),
                      (file.description as NSString).pathExtension.lowercased() == "mpls"
                else {
                    file.close()
                    continue
                }
                try Task.checkCancellation()
                playlists.append(try file.parseMPLSFile(fileMap: fileMap))
            }
            // 排除有相同文件的playlist。
            playlists = playlists.removeDuplicate { left, right in
                left.files == right.files
            }
            var mpls: MPLS?
            if let streamName {
                mpls = playlists.first {
                    $0.name == streamName
                }
            }
            if mpls == nil {
                // 音乐碟最大的不一定是最长的。但是还是选择最大的，因为里面的音轨会更多。
                mpls = playlists.max { left, right in
                    left.size < right.size
                }
                // 现在连续剧可以直接选在最大的mpls了。不用这个逻辑了。有需要的话，后面做成一个开关
//                if let playlist = mpls, playlist.files.count > 1 {
//                    // 判断iso是不是连续剧, 先简单的根据文件大小来进行判断。如果是连续剧的话，那就不选中最大的mpls(因为连续剧的mpls的时间戳判断会有问题，seek会有问题)，而是选中第一集。
//                    var episodes = playlist.files.compactMap { file in
//                        playlists.first {
//                            $0.files == [file]
//                        }
//                    }
//                    let sum = Float(episodes.map(\.size).reduce(0, +))
//                    let mean = sum / Float(episodes.count)
//                    episodes = episodes.filter {
//                        abs(Float($0.size) - mean) / mean < 0.04
//                    }
//                    let fileSize = files.map(\.size).reduce(0, +)
//                    // 要求每一集跟平均值的误差不超过0.04，并且分集的合计大小跟iso总大小的误差不超过0.01
//                    if episodes.count == playlist.files.count, Float(fileSize) / sum < 1.01 {
//                        mpls = episodes.first
//                    }
//                }
            }
            guard let mpls else {
                throw KSPlayerError(description: "[BDMVIOContext] There are no files in the folder /BDMV/STREAM ")
            }
            currentStream = mpls
            udfMpls = UDFMpls(files: mpls.playFiles as! [PlayFile])
            self.playlists = playlists
            super.init(bufferSize: bufferSize)
            for palsylist in playlists {
                if let stn = palsylist.playItems.first?.stn {
                    for item in stn.audio {
                        audioLanguageCodeMap[Int32(item.pid)] = item.lang
                    }
                    for item in stn.pg {
                        subtitleLanguageCodeMap[Int32(item.pid)] = item.lang
                    }
                }
            }
            // 最后需要用当前的palsylist在更新下语言。这样才能保证语言是对的
            if let stn = mpls.playItems.first?.stn {
                for item in stn.audio {
                    audioLanguageCodeMap[Int32(item.pid)] = item.lang
                }
                for item in stn.pg {
                    subtitleLanguageCodeMap[Int32(item.pid)] = item.lang
                }
            }
        } else {
            var files = try await filesManager.downloads(atPath: "/VIDEO_TS")
            if files.isEmpty {
                files = try await filesManager.downloads(atPath: "/AUDIO_TS")
            }
            // 支持dvd格式
            if files.isEmpty {
                throw KSPlayerError(description: "[BDMVIOContext] can not find /VIDEO_TS or /AUDIO_TS")
            }
            var dvds = [DVD]()
            for index in 1 ..< 100 {
                let ifoName = String(format: "VTS_%02d_0.IFO", index)
                if let file = files.first(where: { $0.description == ifoName }) {
                    let count = Int(file.fileSize())
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
                    file.read(buffer: buffer, size: Int32(count))
                    let name = String(format: "VTS_%02d_", index)
                    let vobs = files.filter { $0.description.hasSuffix(".VOB")
                        && $0.description.hasPrefix(name)
                        && !$0.description.hasSuffix("_0.VOB")
                        && !$0.description.hasSuffix("_TS.VOB")
                    }
                    dvds.append(contentsOf: buffer.parseVTSIFOFile(count: count, name: name, files: files))
                } else {
                    break
                }
            }
            playlists = dvds
            var dvd: DVD?
            if let streamName {
                dvd = dvds.first {
                    $0.name == streamName
                }
            }
            if dvd == nil {
                dvd = dvds.first
            }
            currentStream = dvd
            guard let dvd else {
                throw KSPlayerError(description: "[BDMVIOContext] dvd can not find Stream \(streamName)")
            }
            udfMpls = UDFMpls(files: dvd.playFiles as! [PlayFile])
            super.init(bufferSize: bufferSize)
        }
        initialized = true
    }

    override public func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        let result = udfMpls.read(buffer: buffer, size: size)
        if result == 0 {
            return swift_AVERROR_EOF
        } else if result < 0 {
            return -1
        } else {
            return Int32(result)
        }
    }

    override open func fileSize() -> Int64 {
        udfMpls.fileSize()
    }

    override public func seek(offset: Int64, whence: Int32) -> Int64 {
        udfMpls.seek(offset: offset, whence: whence)
    }

    override public func close() {
        guard !isClosed else { return }
        isClosed = true
        udfMpls.close()
        // udfread_close就会调用context?.close()了
        filesManager.close()
    }
}

extension DownloadProtocol where Self: CustomStringConvertible {
    func parseMPLSFile(fileMap: [String: DownloadProtocol & CustomStringConvertible]) throws -> MPLS {
        defer { close() }
        let count = fileSize()
        // Reject invalid or unreasonable sizes before allocating or narrowing to Int32.
        guard (20...16 * 1024 * 1024).contains(count), seek(offset: 0, whence: SEEK_SET) == 0 else {
            throw MPLSParseError.invalidData
        }
        var bytes = [UInt8](repeating: 0, count: Int(count))
        try bytes.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let remaining = buffer.count - offset
                let result = read(buffer: buffer.baseAddress!.advanced(by: offset), size: Int32(remaining))
                guard result > 0, Int(result) <= remaining else { throw MPLSParseError.incompleteRead }
                offset += Int(result)
            }
        }
        return try MPLS.parse(bytes: bytes, name: description, fileMap: fileMap)
    }
}

public final class UDFFilesManager: FilesManager, @unchecked Sendable {
    private var context: UDFContext
    private let udfread: OpaquePointer
    private var isClosed = false
    public init(download: DownloadProtocol) {
        context = UDFContext(download: download)
        udfread = udfread_init()
    }

    func open() -> Bool {
        udfread_open_input(udfread, &context.input) == 0
    }

    public func contentsOfDirectory(atPath path: String) async throws -> [FileObject] {
        guard !isClosed, let directory = udfread_opendir(udfread, path) else { return [] }
        defer { udfread_closedir(directory) }
        return directory.ls().map { (name: String, isDirectory: Bool) in
            var allValues = [URLResourceKey: Sendable & Codable]()
            let newPath = isDirectory ? path + "/" + name : path
            allValues[.nameKey] = name
            allValues[.pathKey] = newPath
            allValues[.fileResourceTypeKey] = isDirectory ? URLFileResourceType.directory : .regular
            return FileObject(url: URL(fileURLWithPath: "iso://" + newPath), allValues: allValues)
        }
    }

    public func downloads(atPath path: String) async throws -> [DownloadProtocol & CustomStringConvertible] {
        guard !isClosed, let directory = udfread_opendir(udfread, path) else { return [] }
        defer { udfread_closedir(directory) }
        return directory.downloads()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        udfread_close(udfread)
    }
}

class UDFMpls: DownloadProtocol {
    private var files: [PlayFile]
    private let end: Int64
    // 当前的位置
    private var urlPos = Int64(0)
    init(files: [PlayFile]) {
        self.files = files
        end = files.last?.end ?? 0
    }

    func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        if urlPos == end {
            return swift_AVERROR_EOF
        }
        guard let file = files.first(where: { $0.end > urlPos }) else {
            return swift_AVERROR_EOF
        }
        let start = file.end - file.size
        let pos = urlPos - start
        file.file.seek(offset: pos, whence: SEEK_SET)
        let size = min(Int64(size), file.size - pos)
        let result = file.file.read(buffer: buffer, size: Int32(size))
        urlPos += Int64(result)
        return Int32(result)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        var whence = whence
        var offset = offset
        if whence == AVSEEK_SIZE {
            return end
        } else if whence == SEEK_CUR {
            whence = SEEK_SET
            offset += urlPos
        } else if whence == SEEK_END {
            whence = SEEK_SET
            offset += end
        }
        guard whence == SEEK_SET else {
            return -1
        }
        urlPos = offset
        return offset
    }

    func fileSize() -> Int64 {
        end
    }

    func close() {
        for item in files {
            item.file.close()
        }
        files.removeAll()
    }
}

class UDFFile: DownloadProtocol, CustomStringConvertible {
    let fp: OpaquePointer
    let description: String
    let size: Int64
    init(fp: OpaquePointer, name: String, size: Int64) {
        self.fp = fp
        description = name
        self.size = size
    }

    func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        Int32(udfread_file_read(fp, buffer, Int(size)))
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == SEEK_SET, offset == udfread_file_tell(fp) {
            return offset
        } else {
            return udfread_file_seek(fp, offset, whence)
        }
    }

    func fileSize() -> Int64 {
        size
    }

    func close() {}

    /// 专门在deinit才释放，因为这个file可能会在多个地方使用，也可以没有被使用过，所以不能在close释放。
    deinit {
        udfread_file_close(fp)
    }
}

private extension OpaquePointer {
    func ls() -> [(name: String, isDirectory: Bool)] {
        var dirent = udfread_dirent()
        var files = [(name: String, isDirectory: Bool)]()
        while udfread_readdir(self, &dirent) != nil {
            let name = String(cString: dirent.d_name)
            files.append((name, dirent.d_type == UDF_DT_DIR))
        }
        return files
    }

    func downloads() -> [DownloadProtocol & CustomStringConvertible] {
        var dirent = udfread_dirent()
        var files = [UDFFile]()
        var names = [String]()
        while udfread_readdir(self, &dirent) != nil {
            let name = String(cString: dirent.d_name)
            names.append(name)
            if dirent.d_type == UDF_DT_REG, let fp = udfread_file_openat(self, dirent.d_name) {
                let size = udfread_file_size(fp)
                files.append(UDFFile(fp: fp, name: name, size: size))
            }
        }
        return files
    }

    func find(path: String) -> OpaquePointer? {
        var dirent = udfread_dirent()
        while udfread_readdir(self, &dirent) != nil {
            let name = String(cString: dirent.d_name)
            if dirent.d_type == UDF_DT_DIR, name == path, let child = udfread_opendir_at(self, dirent.d_name) {
                return child
            }
        }
        return nil
    }
}
